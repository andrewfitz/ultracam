"""Route switcher proposals to OBS WebSocket v5 and acknowledge successful scene changes."""
import argparse
import base64
import hashlib
import json
import os
from queue import Full, Queue
from threading import Lock, Thread
from websockets.sync.client import connect
from client import Client


def digest(text):
    return base64.b64encode(hashlib.sha256(text.encode()).digest()).decode()


def run(args):
    control = Client(args.port)
    state = control.request("state")
    if state["hotkeys"]:
        raise ValueError("disable hotkeys before selecting OBS as output")
    cfg = state["config"]
    routes = {cfg["anchor_camera_id"], cfg["emphasis_camera_id"], *cfg["additional_targets"]}
    with connect(args.url, open_timeout=5) as ws:
        def send(op, **fields):
            ws.send(json.dumps({"op": op, "d": fields}))

        def receive(op):
            message = json.loads(ws.recv(timeout=3))
            if message["op"] != op:
                raise ValueError("unexpected OBS reply")
            return message["d"]

        hello = receive(0)
        identity = dict(rpcVersion=1, eventSubscriptions=4)
        if auth := hello.get("authentication"):
            password = os.environ["OBS_WEBSOCKET_PASSWORD"]
            identity["authentication"] = digest(digest(password + auth["salt"]) + auth["challenge"])
        send(1, **identity)
        receive(2)
        replies = Queue(maxsize=1)
        telemetry = Client(args.port)
        scene_lock = Lock()
        changing_to = None
        observation_failure = None

        # Subscribe before synchronizing, then skip any events predating sync.
        watcher = Client(args.port)
        updates = watcher.watch()
        next(updates)

        def observe():
            nonlocal observation_failure
            try:
                for raw in ws:
                    message = json.loads(raw)
                    if message["op"] == 7:
                        replies.put(message["d"])
                    elif message["op"] == 5 and message["d"]["eventType"] == "CurrentProgramSceneChanged":
                        route = message["d"]["eventData"]["sceneName"]
                        with scene_lock:
                            expected = changing_to
                        # A proposal alone does not change OBS. Suppress only the
                        # event expected from a scene change we actually sent.
                        if route not in routes or route == expected:
                            continue
                        status = telemetry.request("state")["status"]
                        if route == status["current_camera_id"] and expected is None:
                            continue
                        telemetry.event("manualOverride", camera_id=route, time=status["time"])
                raise ConnectionError("OBS disconnected")
            except Exception as error:
                observation_failure = error
                try:
                    replies.put_nowait(error)
                except Full:
                    pass
                watcher.shutdown()
        Thread(target=observe, daemon=True).start()

        def call(kind, request_id, **data):
            send(6, requestType=kind, requestId=request_id, requestData=data)
            result = replies.get(timeout=4)
            if isinstance(result, Exception):
                raise result
            if result["requestId"] != request_id or not result["requestStatus"]["result"]:
                raise ValueError(str(result["requestStatus"]))
            return result.get("responseData", {})

        def live_updates():
            try:
                yield from updates
            except ConnectionError:
                if observation_failure is not None:
                    raise observation_failure from None
                raise

        scene = call("GetCurrentProgramScene", "initial")["currentProgramSceneName"]
        if scene not in routes:
            raise ValueError("current OBS scene must be a configured route")
        synced = control.event("manualOverride", camera_id=scene, time=control.request("state")["status"]["time"])
        for update in live_updates():
            if update["seq"] <= synced["seq"]:
                continue
            # A boundary may be proposed ahead of the clock. Each update includes
            # the pending cut until it lands, expires, or is replaced.
            cut = update.get("pending")
            if not cut or update["status"]["time"] < cut["cut_time"]:
                continue
            decision = cut["decision_id"]
            latest = control.request("state")["status"]
            if latest["pending_decision_id"] != decision or not cut["cut_time"] <= latest["time"] <= cut["expires_at"]:
                continue
            target = cut["target_camera_id"]
            with scene_lock:
                changing_to = target
            try:
                try:
                    call("SetCurrentProgramScene", decision, sceneName=target)
                except ValueError:
                    control.event("reject", decision_id=decision)
                    raise
                now = control.request("state")["status"]["time"]
                result = control.event("acknowledge", decision_id=decision, applied_at=now)
                if result["status"]["current_camera_id"] != target:
                    scene = call("GetCurrentProgramScene", "resync")["currentProgramSceneName"]
                    if scene in routes and scene != result["status"]["current_camera_id"]:
                        current_time = control.request("state")["status"]["time"]
                        control.event("manualOverride", camera_id=scene, time=current_time)
            finally:
                with scene_lock:
                    changing_to = None


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--port", type=int, default=48765)
    cli.add_argument("--url", default="ws://127.0.0.1:4455")
    run(cli.parse_args())
