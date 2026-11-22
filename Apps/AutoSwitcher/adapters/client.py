"""Local Auto Switcher v1 client. Run as a CLI or import Client."""
import argparse
import json
import socket
import sys


class Client:
    def __init__(self, port=48765):
        self.socket = socket.create_connection(("127.0.0.1", port), timeout=3)
        self.socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.reader = self.socket.makefile("rb")

    def read(self):
        line = self.reader.readline(524288)
        if not line.endswith(b"\n"):
            raise ConnectionError("incomplete switcher response")
        value = json.loads(line)
        if value.get("type") == "error":
            raise ValueError(value["message"])
        return value

    def request(self, op, **fields):
        self.socket.sendall(json.dumps(dict(v=1, op=op, **fields)).encode() + b"\n")
        return self.read()

    def event(self, kind, **fields):
        return self.request("event", event=dict(type=kind, **fields))

    def watch(self):
        yield self.request("watch")
        self.socket.settimeout(None)
        while True:
            yield self.read()


if __name__ == "__main__":
    cli = argparse.ArgumentParser()
    cli.add_argument("--port", type=int, default=48765)
    cli.add_argument("command", choices=["state", "watch", "publish", "take"])
    cli.add_argument("route", nargs="?")
    args = cli.parse_args()
    client = Client(args.port)
    if args.command == "publish":
        for line in sys.stdin:
            print(json.dumps(client.request("event", event=json.loads(line))), flush=True)
    elif args.command == "watch":
        for update in client.watch():
            print(json.dumps(update), flush=True)
    elif args.command == "take":
        if not args.route:
            cli.error("take requires a route ID")
        print(json.dumps(client.request("take", route=args.route)))
    else:
        print(json.dumps(client.request("state")))
