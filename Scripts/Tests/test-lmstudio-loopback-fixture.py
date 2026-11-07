#!/usr/bin/env python3
"""Opt-in synthetic HTTP peer. Never a model, proxy, credential or app reader.

This file is prepared only; launching it requires the coordinated protocol-test
slot. The server binds its own ephemeral IPv4 loopback port and exits after a
bounded lifetime. It never records request bodies.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import secrets
import signal
import threading
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--events-file", required=True)
    parser.add_argument("--lifetime", type=float, default=30.0)
    args = parser.parse_args()
    if not 1 <= args.lifetime <= 120:
        raise SystemExit("fixture lifetime out of bounds")
    ready, events = Path(args.ready_file), Path(args.events_file)
    event_fd = os.open(events, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    nonce = secrets.token_hex(12)
    modes = ["unicode", "tool", "incomplete", "cancel", "redirect", "declared-oversize", "actual-oversize"]
    prefix = "synthetic-" + nonce + "-"
    lock = threading.Lock()
    event_count = 0

    def event(name):
        nonlocal event_count
        with lock:
            if event_count < 64:
                os.write(event_fd, (json.dumps({"event": name}, separators=(",", ":")) + "\n").encode())
                event_count += 1

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def json_reply(self, status, value):
            data = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            self.wfile.flush()

        def do_GET(self):
            if self.path == "/v1/models":
                self.json_reply(200, {"data": [{"id": prefix + mode} for mode in modes]})
            elif self.path == "/forbidden":
                event("forbidden-redirect-followed")
                self.json_reply(500, {"error": "redirect should not be followed"})
            else:
                self.json_reply(404, {"error": "synthetic route only"})

        def do_POST(self):
            if self.path == "/forbidden":
                event("forbidden-redirect-followed")
                self.json_reply(500, {"error": "redirect should not be followed"})
                return
            if self.path != "/v1/chat/completions":
                self.json_reply(404, {"error": "synthetic route only"})
                return
            if any(self.headers.get(key) for key in ["Authorization", "Proxy-Authorization", "Cookie", "X-API-Key"]):
                event("unexpected-credential-header")
                self.json_reply(400, {"error": "keyless fixture only"})
                return
            try:
                size = int(self.headers.get("Content-Length", "-1"))
                if not 0 < size <= 1024 * 1024:
                    raise ValueError()
                payload = json.loads(self.rfile.read(size))
                model = payload["model"]
                if not isinstance(model, str) or not model.startswith(prefix):
                    raise ValueError()
                mode = model[len(prefix):]
                if mode not in modes or not isinstance(payload.get("messages"), list):
                    raise ValueError()
            except (ValueError, KeyError, TypeError, json.JSONDecodeError):
                self.json_reply(400, {"error": "owned synthetic request required"})
                return
            event("request-" + mode)
            if mode == "redirect":
                self.send_response(307)
                self.send_header("Location", "http://127.0.0.1:%d/forbidden" % self.server.server_port)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if mode == "declared-oversize":
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(2 * 1024 * 1024 + 1))
                self.end_headers()
                self.wfile.flush()
                time.sleep(0.3)
                self.close_connection = True
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()

            def write_chunk(data):
                self.wfile.write(("%x\r\n" % len(data)).encode() + data + b"\r\n")
                self.wfile.flush()

            def chunk(delta, finish=None):
                return ("data: " + json.dumps({"id": "synthetic-response", "choices": [{"index": 0, "delta": delta,
                    "finish_reason": finish}]}, ensure_ascii=False, separators=(",", ":")) + "\n\n").encode()

            try:
                if mode == "actual-oversize":
                    remaining = 2 * 1024 * 1024 + 1
                    while remaining:
                        count = min(8192, remaining)
                        write_chunk(b":" + b" " * (count - 1))
                        remaining -= count
                elif mode == "cancel":
                    write_chunk(chunk({"role": "assistant", "content": "SYNTHETIC partial only"}))
                    event("cancel-stream-started")
                    for _ in range(100):
                        time.sleep(0.05)
                        write_chunk(b": synthetic keepalive\n\n")
                elif mode == "unicode":
                    data = chunk({"role": "assistant", "content": "Café 👩‍💻 العربية"}) + chunk({}, "stop") + b"data: [DONE]\n\n"
                    for byte in data:
                        write_chunk(bytes([byte]))
                else:
                    exact_id = "original-synthetic-call-" + nonce
                    results = [item for item in payload["messages"] if item.get("role") == "tool"]
                    if results:
                        if len(results) != 1 or results[0].get("tool_call_id") != exact_id or results[0].get("content") != "42":
                            raise ValueError("exact synthetic tool pair was changed")
                        event("exact-tool-result-received")
                        write_chunk(chunk({"role": "assistant", "content": "42"}, "stop"))
                    else:
                        write_chunk(chunk({"role": "assistant", "tool_calls": [{"index": 0, "id": exact_id, "type": "function",
                            "function": {"name": "calculate", "arguments": '{"expression":"'}}]}))
                        write_chunk(chunk({"tool_calls": [{"index": 0, "function": {"arguments": '6*7"}'}}]}, "tool_calls"))
                    if mode != "incomplete":
                        write_chunk(b"data: [DONE]\n\n")
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                event("peer-disconnected-" + mode)
            except ValueError:
                event("changed-synthetic-tool-pair")
            finally:
                self.close_connection = True

    class Server(http.server.ThreadingHTTPServer):
        daemon_threads = True
        allow_reuse_address = False

    server = Server(("127.0.0.1", 0), Handler)
    server.timeout = 0.2
    ready_fd = os.open(ready, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    ready_stamp = os.fstat(ready_fd)
    os.write(ready_fd, json.dumps({"pid": os.getpid(), "host": "127.0.0.1", "port": server.server_port,
        "models": {mode: prefix + mode for mode in modes}}, separators=(",", ":")).encode())
    os.close(ready_fd)
    deadline = time.monotonic() + args.lifetime
    stopped = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stopped.set())
    signal.signal(signal.SIGINT, lambda *_: stopped.set())
    try:
        while not stopped.is_set() and time.monotonic() < deadline:
            server.handle_request()
    finally:
        server.server_close()
        try:
            current = ready.stat(follow_symlinks=False)
            if (current.st_dev, current.st_ino) == (ready_stamp.st_dev, ready_stamp.st_ino):
                ready.unlink()
        except FileNotFoundError:
            pass
        os.close(event_fd)


if __name__ == "__main__":
    main()
