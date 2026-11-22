"""Pipe live mono 24 kHz signed PCM16LE into Transcriberrr's native WebSocket."""
import argparse
import asyncio
import base64
import json
import os
import sys
from websockets.asyncio.client import connect
from client import Client


async def run(args):
    client = Client(args.port)
    headers = {}
    if key := os.getenv("TRANSCRIBERRR_API_KEY"):
        headers["Authorization"] = "Bearer " + key
    async with connect(args.url, subprotocols=["realtime"], additional_headers=headers) as ws:
        async def send(kind, **fields):
            await ws.send(json.dumps({"type": "transcriberrr." + kind, **fields}))

        async def receive():
            async for line in ws:
                msg = json.loads(line)
                kind = msg["type"]
                if kind == "error":
                    raise RuntimeError(msg["error"])
                if kind == "transcriberrr.session.ended":
                    return
                if kind != "transcriberrr.transcript.final":
                    continue
                text = msg["text"].strip()
                if not text:
                    continue
                cue = dict(text=text, speaker=msg.get("speaker"), segment_id=msg["item_id"], revision=msg.get("revision", 1),
                           start=args.origin + msg["start_frame"] / 24000,
                           end=args.origin + msg["end_frame"] / 24000,
                           kind="question" if text.endswith("?") else
                           "sentenceEnd" if text.endswith((".", "!")) else "phraseEnd",
                           confidence=args.confidence, is_final=True)
                await asyncio.to_thread(client.event, "transcript", cue=cue)

        while True:
            async with asyncio.timeout(10):
                msg = json.loads(await ws.recv())
            if msg["type"] == "error":
                raise RuntimeError(msg["error"])
            if msg["type"] == "transcriberrr.session.created":
                break
        await send("track.register", track_id="program", role="mixed_audio", start_frame=0)
        frame = 0
        async with asyncio.TaskGroup() as tasks:
            receiver = tasks.create_task(receive())
            while packet := await asyncio.to_thread(sys.stdin.buffer.read, 4800):
                if len(packet) % 2:
                    raise ValueError("partial PCM sample")
                await send("track.append", track_id="program", start_frame=frame,
                           audio=base64.b64encode(packet).decode())
                frame += len(packet) // 2
            await send("session.end")
            async with asyncio.timeout(60):
                await receiver


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--port", type=int, default=48765)
    cli.add_argument("--url", default="ws://127.0.0.1:8080/v1/realtime?intent=transcription&transcriberrr=1")
    cli.add_argument("--origin", type=float, default=0, help="host media seconds at the first audio sample")
    cli.add_argument("--confidence", type=float, default=0.8, help="editorial boundary weight for final text")
    asyncio.run(run(cli.parse_args()))
