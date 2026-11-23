"""Read {camera_id,time,path} JSONL frames. Publish motion, face pose or model scores."""
import argparse
import base64
import json
import os
from pathlib import Path
import sys
import time
import urllib.request

import cv2
from client import Client


def frontal_score(detector, frame):
    # YuNet reports eye centers and nose tip. Nose displacement estimates
    # face direction; landmark geometry cannot measure pupil direction.
    _, faces = detector.detect(frame)
    if faces is None:
        return 0.0
    face = max(faces, key=lambda f: f[2] * f[3])
    left, right, nose = face[4:6], face[6:8], face[8:10]
    midpoint = (left + right) / 2
    offset = abs(float(nose[0] - midpoint[0])) / max(abs(float(right[0] - left[0])) / 2, 1)
    return float(face[-1]) * max(0, 1 - offset)


def provider_score(frame, args):
    ok, data = cv2.imencode(".jpg", frame)
    if not ok:
        raise ValueError("JPEG encode failed")
    image = "data:image/jpeg;base64," + base64.b64encode(data).decode()
    content = [{"type": "text", "text": args.prompt + ' Return JSON {"score": 0.0} with a number from 0 to 1.'},
               {"type": "image_url", "image_url": {"url": image}}]
    body = {"model": args.model, "messages": [{"role": "user", "content": content}]}
    headers = {"Content-Type": "application/json"}
    if key := os.getenv("SWITCHER_MODEL_KEY"):
        headers["Authorization"] = "Bearer " + key
    req = urllib.request.Request(args.endpoint, data=json.dumps(body).encode(), headers=headers)
    with urllib.request.urlopen(req, timeout=args.timeout) as reply:
        answer = json.load(reply)["choices"][0]["message"]["content"]
    score = float(json.loads(answer)["score"])
    if not 0 <= score <= 1:
        raise ValueError("invalid provider score")
    return score


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--port", type=int, default=48765)
    cli.add_argument("--mode", choices=["motion", "eyeContact", "provider"], default="eyeContact")
    cli.add_argument("--endpoint", help="OpenAI-compatible chat completions URL")
    cli.add_argument("--model")
    cli.add_argument("--camera", type=int, help="capture live OpenCV camera index instead of reading JSONL")
    cli.add_argument("--route", help="configured route for this camera")
    cli.add_argument("--fps", type=float, default=5.0)
    cli.add_argument("--prompt", default="Score how clearly this camera shows the person working.")
    cli.add_argument("--timeout", type=float, default=3)
    args = cli.parse_args()
    if args.mode == "provider" and not (args.endpoint and args.model):
        cli.error("provider mode requires --endpoint and --model")
    client = Client(args.port)
    config = client.request("state")["config"]
    routes = {config["anchor_camera_id"], config["emphasis_camera_id"], *config["additional_targets"]}
    detector = None
    if args.mode == "eyeContact":
        model = Path(__file__).resolve().parents[1] / "models/yunet.onnx"
        detector = cv2.FaceDetectorYN.create(str(model), "", (320, 320))
    previous = {}
    def samples():
        if args.camera is None:
            for line in sys.stdin:
                sample = json.loads(line)
                yield sample, cv2.imread(sample["path"])
            return
        if args.route not in routes or not 0 < args.fps <= 60:
            cli.error("live capture requires a configured --route and --fps in (0,60]")
        camera = cv2.VideoCapture(args.camera)
        try:
            if not camera.isOpened():
                raise ValueError("camera unavailable")
            while True:
                started = time.monotonic()
                ok, frame = camera.read()
                if not ok:
                    raise ValueError("camera disconnected")
                snapshot = client.request("state")
                yield dict(camera_id=args.route, time=snapshot["status"]["time"],
                           session_generation=snapshot.get("session_generation", 0)), frame
                time.sleep(max(0, 1 / args.fps - (time.monotonic() - started)))
        finally:
            camera.release()

    for sample, frame in samples():
        route = sample["camera_id"]
        if route not in routes:
            raise ValueError(f"unknown route {route}")
        if frame is None:
            raise ValueError("unreadable image")
        frame = cv2.resize(frame, (320, 320), interpolation=cv2.INTER_AREA)
        generation = sample.get("session_generation", 0)
        observation = dict(camera_id=route, time=sample["time"], session_generation=generation)
        if detector is not None:
            observation["eye_contact"] = frontal_score(detector, frame)
        elif args.mode == "provider":
            observation["provider_score"] = provider_score(frame, args)
        else:
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            prior_generation, prior = previous.get(route, (generation, gray))
            if prior_generation != generation:
                prior = gray
            observation["motion"] = cv2.countNonZero(cv2.inRange(cv2.absdiff(gray, prior), 21, 255)) / gray.size
            previous[route] = (generation, gray)
        client.event("video", observation=observation)


if __name__ == "__main__":
    main()
