"""Exercise the real publisher against independent loopback FFmpeg receivers."""
import argparse
from dataclasses import dataclass
from contextlib import ExitStack
import json
import os
from pathlib import Path
import re
import signal
import socket
import ssl
import subprocess
import threading
import time

from inspect_media import require, verify_recording


@dataclass(frozen=True)
class FormatCase:
    size: str
    rate: str
    codec: str
    mbps: int
    color: str = "rec709-video"

    def arguments(self):
        return [self.size, self.rate, self.codec, str(self.mbps), self.color]

    def expected(self):
        width, height = {"hd720": (1280, 720), "hd1080": (1920, 1080),
                         "uhd4K": (3840, 2160), "dci4K": (4096, 2160)}[self.size]
        fps = {"fps23976": 24000 / 1001, "fps24": 24, "fps25": 25, "fps30": 30, "fps2997": 30000 / 1001,
               "fps47952": 48000 / 1001, "fps48": 48, "fps50": 50, "fps100": 100, "fps11988": 120000 / 1001,
               "fps5994": 60000 / 1001, "fps60": 60, "fps120": 120}[self.rate]
        codec, profile, pixels = {
            "h264": ("h264", "Main", "yuv420p"), "hevc": ("hevc", "Main", "yuv420p"),
            "hevcMain10": ("hevc", "Main 10", "yuv420p10le"),
            "hevcMain10_422": ("hevc", "Rext", "yuv422p10le"), "av1": ("av1", "Main", "yuv420p"),
        }[self.codec]
        color = None
        if self.color != "rec709-video":
            transfer = {"rec2020-pq-video": "smpte2084", "rec2020-hlg-video": "arib-std-b67"}[self.color]
            color = dict(color_range="tv", color_primaries="bt2020", color_transfer=transfer, color_space="bt2020nc")
        return dict(expected_width=width, expected_height=height, expected_codec=codec, expected_profile=profile,
                    expected_pix_fmt=pixels, expected_fps=fps, expected_color=color, target_mbps=self.mbps)


# The low/high pair uses identical moving content to measure the effect of the target in the received payload.
FORMATS = {
    "h264-camera-4k60": FormatCase("uhd4K", "fps60", "h264", 28),
    "h264-camera-dci47952": FormatCase("dci4K", "fps47952", "h264", 28),
    "hevc-camera-4k60": FormatCase("uhd4K", "fps60", "hevc", 18),
    "h264-4k60": FormatCase("uhd4K", "fps60", "h264", 28),
    "h264-4k60-50mbps": FormatCase("uhd4K", "fps60", "h264", 50),
    "hevc-4k5994": FormatCase("uhd4K", "fps5994", "hevc", 18),
    "hevc10-pq": FormatCase("hd1080", "fps50", "hevcMain10", 12, "rec2020-pq-video"),
    "hevc422-hlg": FormatCase("dci4K", "fps24", "hevcMain10_422", 25, "rec2020-hlg-video"),
    "av1-720p2997": FormatCase("hd720", "fps2997", "av1", 4),
    "av1-4k60": FormatCase("uhd4K", "fps60", "av1", 20),
    "bitrate-low": FormatCase("hd720", "fps30", "h264", 2),
    "bitrate-high": FormatCase("hd720", "fps30", "h264", 10),
}

# These profiles deliberately offer more high-entropy video than some encoders can
# process. Report the measured cadence and sync separately from decode correctness.
THROUGHPUT_CASES = {"h264-4k60-50mbps", "av1-4k60"}
SCENARIOS = ("audio-late", "video-late", "video-only", "reconnect", "startup-epoch", "congestion", "worker-gaps",
             "compressed-pressure", "audio-continuity", "media-loss", "invalid-port", "reject-tls")
RECONNECT_COUNT = 2
RECONNECT_SEGMENT_SECONDS = 4
RECONNECT_RECOVERY_SECONDS = 12  # Eight-second stall watchdog, two-second backoff, and time for local publish.


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def stop_process(process):
    if process.poll() is None:
        process.kill()
    process.wait()


def wait_for_publisher(process, started, timeout):
    # Reap this process directly so FFmpeg and ps do not enter its CPU totals.
    deadline = started + timeout
    while True:
        pid, status, usage = os.wait4(process.pid, os.WNOHANG)
        if pid:
            process.returncode = os.waitstatus_to_exitcode(status)
            elapsed = time.monotonic() - started
            cpu = usage.ru_utime + usage.ru_stime
            return {"wall_seconds": round(elapsed, 3), "cpu_user_seconds": round(usage.ru_utime, 3),
                    "cpu_system_seconds": round(usage.ru_stime, 3), "cpu_percent_of_one_core": round(100 * cpu / elapsed, 1),
                    "peak_rss_mib": round(usage.ru_maxrss / (1024 * 1024), 1)}
        require(time.monotonic() < deadline, "Publisher did not exit before the fixture deadline")
        time.sleep(.05)


def receive(stack, directory, port, number, seconds=None):
    recording = directory / f"received-{number}.flv"
    log = stack.enter_context((directory / f"receiver-{number}.log").open("wb"))
    command = ["ffmpeg", "-nostdin", "-v", "warning", "-listen", "1", "-probesize", "12M",
               "-analyzeduration", "1000000", "-i", f"rtmp://127.0.0.1:{port}/live/qualification",
               "-map", "0:v", "-map", "0:a?", "-c", "copy"]
    if seconds:
        command += ["-t", str(seconds)]
    proc = subprocess.Popen(command + [str(recording)], stdout=log, stderr=log)
    stack.callback(stop_process, proc)
    return recording, proc


class ResidentMemory:
    """Sample only the fixture process, including the period with a blocked receiver."""

    def __init__(self, pid):
        self.pid = pid
        self.finished = threading.Event()
        self.samples = []
        self.worker = threading.Thread(target=self.sample, daemon=True)
        self.worker.start()

    def sample(self):
        started = time.monotonic()
        while not self.finished.is_set():
            result = subprocess.run(["ps", "-o", "rss=", "-p", str(self.pid)], capture_output=True, text=True)
            if result.returncode or not result.stdout.strip():
                return
            self.samples.append((round(time.monotonic() - started, 2), int(result.stdout.strip())))
            self.finished.wait(.5)

    def close(self):
        self.finished.set()
        self.worker.join(timeout=2)


def until_recording(path, receiver):
    deadline = time.monotonic() + 12
    while not path.exists() or path.stat().st_size < 256 * 1024:
        require(receiver.poll() is None, "Receiver exited before media arrived")
        require(time.monotonic() < deadline, "Receiver never obtained sufficient media")
        time.sleep(.1)


def verify_transport(binary, directory, mode, certificate=None, private_key=None, certificate_host="127.0.0.1"):
    directory.mkdir()
    port = free_port()
    profile = FORMATS.get(mode)
    reconnect = mode in ("reconnect", "startup-epoch")
    reconnect_run_seconds = RECONNECT_COUNT * (RECONNECT_SEGMENT_SECONDS + RECONNECT_RECOVERY_SECONDS) + 5
    seconds = reconnect_run_seconds if reconnect else {
        "congestion": 25, "worker-gaps": 18, "compressed-pressure": 11, "audio-continuity": 12,
    }.get(mode, 6 if profile else 7)
    with ExitStack() as stack:
        recording, receiver = receive(stack, directory, port, 1, seconds=RECONNECT_SEGMENT_SECONDS if reconnect else None)
        hostname, published_port = "127.0.0.1", port
        use_tls = mode == "trusted-tls" or (profile is not None and certificate is not None)
        if use_tls:
            tls = TLSProxy(certificate, private_key, upstream=port)
            stack.callback(tls.close)
            hostname, published_port = certificate_host, tls.port
        logpath = directory / "publisher.log"
        log = stack.enter_context(logpath.open("w", buffering=1))
        time.sleep(.25)
        arguments = [binary, f"rtmps://{hostname}:{published_port}/live", mode, str(seconds)]
        if profile:
            arguments.extend(profile.arguments())
        host_load_before = os.getloadavg()
        started = time.monotonic()
        app = subprocess.Popen(arguments, env={**os.environ, "ULTRACAM_SMOKE_TRUSTED_TLS": str(int(use_tls))},
                               stdout=log, stderr=log)
        stack.callback(stop_process, app)
        memory = ResidentMemory(app.pid)
        stack.callback(memory.close)
        recordings = [recording]
        receiver_closes = []
        if mode == "congestion":
            until_recording(recording, receiver)
            # First capture identifiable media, then leave the TCP connection open without reads.
            time.sleep(4)
            os.kill(receiver.pid, signal.SIGSTOP)
            try:
                deadline = time.monotonic() + 12
                while "phase reconnecting" not in logpath.read_text():
                    require(time.monotonic() < deadline, "Publisher did not detect a stalled TCP upload")
                    time.sleep(.1)
            finally:
                os.kill(receiver.pid, signal.SIGCONT)
            # Close the paused listener before opening its replacement.
            receiver.terminate()
            receiver.wait(timeout=5)
            receiver_closes.append(round(time.monotonic() - started, 3))
            recording, receiver = receive(stack, directory, port, len(recordings) + 1)
            recordings.append(recording)
        if reconnect:
            for cut in range(RECONNECT_COUNT):
                require(receiver.wait(timeout=RECONNECT_SEGMENT_SECONDS + RECONNECT_RECOVERY_SECONDS) == 0,
                        f"Receiver {cut + 1} failed before disconnect")
                receiver_closes.append(round(time.monotonic() - started, 3))
                recording, receiver = receive(stack, directory, port, len(recordings) + 1,
                                              seconds=RECONNECT_SEGMENT_SECONDS if cut + 1 < RECONNECT_COUNT else None)
                recordings.append(recording)
        resource_use = wait_for_publisher(app, started, seconds + 9)
        resource_use.update(host_load_before=host_load_before, host_load_after=os.getloadavg())
        if receiver_closes:
            resource_use["planned_receiver_close_wall_seconds"] = receiver_closes
        memory.close()
        (directory / "publisher-rss-kib.json").write_text(json.dumps(memory.samples) + "\n")
        if memory.samples:
            resource_use["sampled_peak_rss_mib"] = round(max(rss for _, rss in memory.samples) / 1024, 1)
        (directory / "publisher-resources.json").write_text(json.dumps(resource_use, indent=2) + "\n")
        require(app.returncode == 0, f"Publisher failed. See {logpath}")
        require(receiver.wait(timeout=8) == 0, f"Receiver failed. See {directory / f'receiver-{len(recordings)}.log'}")
        if use_tls:
            require(tls.negotiated.is_set(), "Local receiver never completed TLS handshake")
        publisher_log = logpath.read_text()
        phases = re.findall(r"^phase (\w+)(?: frame \d+)?$", publisher_log, flags=re.M)
        expected_phases = ["connecting", "streaming"] + ["reconnecting", "streaming"] * (len(recordings) - 1)
        require(phases == expected_phases, f"Unexpected publisher phase sequence {phases}. See {logpath}")
        dropped = re.search(r"^finished streaming, dropped video (\d+)$", publisher_log, flags=re.M)
        require(dropped is not None, f"Publisher did not finish live. See {logpath}")
        if mode == "congestion":
            require("interruption The upload queue exceeded its live buffer." in publisher_log,
                    f"Publisher did not identify upload congestion. See {logpath}")
        decoded = [verify_recording(file, with_audio=mode != "video-only", check_tone_channels=mode != "audio-continuity",
                                 audio_continuity=mode == "audio-continuity", measure_throughput=mode in THROUGHPUT_CASES,
                                 worker_gaps=mode == "worker-gaps", pressure=mode == "compressed-pressure",
                                 moving_bars="-camera-" in mode, media_loss=mode == "media-loss",
                                 startup_epoch=mode == "startup-epoch",
                                 **(profile.expected() if profile else {}))
                for file in recordings]
        decoded[0].update(publisher_dropped_video=int(dropped[1]), publisher=resource_use)
        if profile:
            deadlines = re.search(r"^fixture late by a frame on (\d+) of (\d+) input deadlines$", publisher_log, flags=re.M)
            require(deadlines is not None, f"Missing fixture deadline counts. See {logpath}")
            decoded[0].update(source_deadlines=int(deadlines[2]), late_source_deadlines=int(deadlines[1]))
        return decoded


class TLSProxy:
    """The publisher always uses macOS system trust. This fixture changes no trust settings."""

    def __init__(self, certificate, private_key, upstream=None):
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(certificate, private_key)
        self.upstream = upstream
        self.closed = threading.Event()
        self.attempted = threading.Event()
        self.negotiated = threading.Event()
        self.handshake_error = None
        self.server = socket.socket()
        self.server.bind(("127.0.0.1", 0))
        self.port = self.server.getsockname()[1]
        self.server.listen(1)
        self.server.settimeout(.25)
        self.worker = threading.Thread(target=self.handle, daemon=True)
        self.worker.start()

    def close(self):
        self.closed.set()
        self.server.close()
        self.worker.join(timeout=3)

    @staticmethod
    def copy(source, target):
        try:
            while data := source.recv(64 * 1024):
                target.sendall(data)
        except OSError:
            pass
        finally:
            try:
                target.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    def handle(self):
        try:
            # Closing a listening socket on macOS does not wake a blocked accept.
            deadline = time.monotonic() + 15
            while True:
                if self.closed.is_set() or time.monotonic() >= deadline:
                    return
                try:
                    conn, _ = self.server.accept()
                    break
                except socket.timeout:
                    continue
            with conn:
                if self.closed.is_set():
                    return
                self.attempted.set()
                conn.settimeout(10)
                try:
                    tls = self.context.wrap_socket(conn, server_side=True)
                except ssl.SSLError as error:
                    self.handshake_error = error.reason
                    return
            with tls:
                self.negotiated.set()
                if self.upstream is None:
                    return
                with socket.create_connection(("127.0.0.1", self.upstream), timeout=10) as upstream:
                    backward = threading.Thread(target=self.copy, args=(upstream, tls), daemon=True)
                    backward.start()
                    self.copy(tls, upstream)
                    backward.join(timeout=3)
        except (OSError, ssl.SSLError):
            pass


def reject_untrusted(binary, directory):
    directory.mkdir()
    cert = directory / "test-cert.pem"
    key = directory / "test-key.pem"
    with ExitStack() as stack:
        stack.callback(key.unlink, missing_ok=True)
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=localhost", "-addext", "subjectAltName=IP:127.0.0.1,DNS:localhost",
                        "-keyout", str(key), "-out", str(cert)], check=True, capture_output=True)
        tls = TLSProxy(cert, key)
        stack.callback(tls.close)
        proc = subprocess.run([binary, f"rtmps://127.0.0.1:{tls.port}/live", "reject-tls", "1"],
                              capture_output=True, timeout=30)
        (directory / "publisher.log").write_bytes(proc.stdout + proc.stderr)
        require(proc.returncode == 0 and b"Untrusted TLS rejected" in proc.stdout,
                "Publisher did not reject an untrusted TLS server")
        tls.worker.join(timeout=2)
        require(tls.attempted.is_set() and not tls.negotiated.is_set(), "TLS rejection evidence missing")
        require((tls.handshake_error or "").endswith(("BAD_CERTIFICATE", "CERTIFICATE_UNKNOWN", "UNKNOWN_CA")),
                f"Handshake ended without a certificate rejection alert: {tls.handshake_error}")
        return {"tls_attempted": True, "untrusted_certificate_rejected": True, "tls_alert": tls.handshake_error}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary")
    parser.add_argument("results", type=Path)
    parser.add_argument("--only", action="append", choices=[*SCENARIOS, "trusted-tls", "formats", *FORMATS],
                        help="Run just this scenario. Repeat to select several scenarios.")
    parser.add_argument("--certificate", type=Path, help="Already trusted loopback test certificate (PEM including intermediates)")
    parser.add_argument("--private-key", type=Path, help="Matching key for the test server")
    parser.add_argument("--certificate-host", default="127.0.0.1",
                        help="Certificate hostname resolving exclusively to the local receiver")
    args = parser.parse_args()
    if args.certificate:
        addresses = {item[4][0] for item in socket.getaddrinfo(args.certificate_host, 0)}
        if addresses != {"127.0.0.1"}:
            parser.error("Certificate host must resolve exclusively to 127.0.0.1")
    if bool(args.certificate) != bool(args.private_key) or ("trusted-tls" in (args.only or []) and not args.certificate):
        parser.error("A trusted loopback certificate and its key must be supplied together")
    modes = [*SCENARIOS, *FORMATS]
    if args.certificate:
        modes.append("trusted-tls")
    args.results.mkdir(parents=True, exist_ok=True)
    results = {}
    selected = dict.fromkeys(case for mode in args.only or modes for case in (FORMATS if mode == "formats" else [mode]))
    for mode in selected:
        directory = args.results / mode
        if mode == "invalid-port":
            subprocess.run([args.binary, "rtmps://127.0.0.1/live", mode, "1"], check=True, timeout=6)
            results[mode] = {"invalid_port_rejected": True}
        elif mode == "reject-tls":
            results[mode] = reject_untrusted(args.binary, directory)
        else:
            results[mode] = verify_transport(args.binary, directory, mode, args.certificate, args.private_key, args.certificate_host)
        outcome = "MEASURED" if mode in THROUGHPUT_CASES else "PASS"
        print(f"{outcome} {mode} {json.dumps(results[mode])}", flush=True)
        (args.results / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    if {"bitrate-low", "bitrate-high"} <= results.keys():
        low, high = (results[name][0]["payload_mbps"] for name in ("bitrate-low", "bitrate-high"))
        require(high > 2 * low, f"Changing the target from 2 to 10 Mbps did not change encoded bitrate: {low}, {high}")


if __name__ == "__main__":
    main()
