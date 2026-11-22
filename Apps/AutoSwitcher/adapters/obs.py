"""Route switcher proposals to OBS WebSocket v5 and acknowledge successful scene changes."""
import argparse
import base64
import hashlib
import json
import os
from queue import Queue
from threading import Thread
from websockets.sync.client import connect
from client import Client


def digest(text):
    return base64.b64encode(hashlib.sha256(text.encode()).digest()).decode()


def run(args):
    control = Client(args.port)
    state = control.request("state")
    if state["hotkeys"]:
        raise ValueError("disable hotkeys before selecting OBS as output")
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
        def observe():
            try:
                for raw in ws:
                    message = json.loads(raw)
                    if message["op"] == 7:
                        replies.put(message["d"])
                    elif message["op"] == 5 and message["d"]["eventType"] == "CurrentProgramSceneChanged":
                        route = message["d"]["eventData"]["sceneName"]
                        snapshot = telemetry.request("state")
                        status = snapshot["status"]
                        # The matching request response owns the acknowledgement.
                        if route == status["current_camera_id"] or route == (snapshot.get("pending") or {}).get("target_camera_id"):
                            continue
                        telemetry.event("manualOverride", camera_id=route, time=status["time"])
            except Exception as error:
                replies.put(error)
        Thread(target=observe, daemon=True).start()

        def call(kind, request_id, **data):
            send(6, requestType=kind, requestId=request_id, requestData=data)
            result = replies.get(timeout=4)
            if isinstance(result, Exception):
                raise result
            if result["requestId"] != request_id or not result["requestStatus"]["result"]:
                raise ValueError(str(result["requestStatus"]))
            return result.get("responseData", {})

        # Subscribe before synchronizing, then skip any events predating sync.
        updates = Client(args.port).watch()
        next(updates)
        scene = call("GetCurrentProgramScene", "initial")["currentProgramSceneName"]
        cfg = state["config"]
        if scene not in [cfg["anchor_camera_id"], cfg["emphasis_camera_id"], *cfg["additional_targets"]]:
            raise ValueError("current OBS scene must be a configured route")
        synced = control.event("manualOverride", camera_id=scene, time=control.request("state")["status"]["time"])
        for update in updates:
            if update["seq"] <= synced["seq"]:
                continue
            for output in update["outputs"]:
                if output["type"] != "cut":
                    continue
                cut = output["instruction"]
                decision = cut["decision_id"]
                latest = control.request("state")["status"]
                if latest["pending_decision_id"] != decision or latest["time"] > cut["expires_at"]:
                    continue
                try:
                    call("SetCurrentProgramScene", decision, sceneName=cut["target_camera_id"])
                except ValueError:
                    control.event("reject", decision_id=decision)
                    raise
                now = control.request("state")["status"]["time"]
                result = control.event("acknowledge", decision_id=decision, applied_at=max(now, cut["cut_time"]))
                if result["status"]["current_camera_id"] != cut["target_camera_id"]:
                    control.event("manualOverride", camera_id=cut["target_camera_id"], time=now)


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--port", type=int, default=48765)
    cli.add_argument("--url", default="ws://127.0.0.1:4455")
    run(cli.parse_args())
