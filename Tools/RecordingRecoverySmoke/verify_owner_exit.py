"""Interrupt the owner of a live synthetic writer and verify the writer's exit status."""
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time


def wait_for_ready(stream):
    expected = b'READY\n'
    response = b''
    deadline = time.monotonic() + 10
    while response != expected:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([stream], [], [], remaining)[0]:
            raise RuntimeError('Timed out waiting for the synthetic writer')
        chunk = os.read(stream.fileno(), len(expected) - len(response))
        response += chunk
        if not chunk or not expected.startswith(response):
            raise RuntimeError('Synthetic writer sent an invalid readiness signal')


def verify_owner_exit(binary, work):
    with tempfile.TemporaryDirectory(dir=work) as root:
        # Only this owner holds the write end of the fixture's control pipe.
        with subprocess.Popen(['/bin/cat'], stdin=subprocess.PIPE, stdout=subprocess.PIPE) as owner:
            try:
                with subprocess.Popen([binary, '--owned-child', root, 'ProRes', 'source'],
                                      stdin=owner.stdout, stdout=subprocess.PIPE) as writer:
                    try:
                        owner.stdout.close()
                        wait_for_ready(writer.stdout)
                        if writer.poll() is not None:
                            raise RuntimeError('Synthetic writer exited before its owner')
                        owner.kill()
                        if writer.wait(timeout=5) != -signal.SIGKILL:
                            raise RuntimeError('Synthetic writer did not stop on owner exit')
                    finally:
                        if writer.poll() is None:
                            writer.kill()
            finally:
                if owner.poll() is None:
                    owner.kill()
    print('RECOVERY PASS owner exit interrupted its active writer')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit('Usage: verify_owner_exit.py RECOVERY_HELPER WORK_DIRECTORY')
    verify_owner_exit(Path(sys.argv[1]).resolve(), Path(sys.argv[2]))
