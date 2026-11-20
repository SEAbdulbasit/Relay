#!/usr/bin/env python3
"""Owned opt-in synthetic HTTP peer; no model, real key, provider or body log."""
import argparse
import http.server
import json
import os
from pathlib import Path
import signal
import threading
import time


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--ready-file', required=True)
    p.add_argument('--events-file', required=True)
    p.add_argument('--lifetime', type=float, default=30)
    a = p.parse_args()
    if not 1 <= a.lifetime <= 60:
        raise SystemExit('invalid lifetime')
    ready, events = Path(a.ready_file), Path(a.events_file)
    fd = os.open(events, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    lock, count = threading.Lock(), 0
    def event(name):
        nonlocal count
        with lock:
            if count < 64:
                os.write(fd, (json.dumps({'event': name}) + '\n').encode())
                count += 1
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, *_): pass
        def reply(self, status, value):
            body = json.dumps(value).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def authorized(self):
            good = self.headers.get('Authorization') == 'Bearer SYNTHETIC-OPENROUTER-KEY-4926'
            good = good and not any(self.headers.get(h) for h in ['Proxy-Authorization', 'Cookie', 'X-API-Key'])
            event('exact-own-key' if good else 'wrong-credential')
            return good
        def do_GET(self):
            if not self.authorized(): return self.reply(401, {'error': 'synthetic unauthorized'})
            if self.path == '/v1/models': return self.reply(200, {'data': [{'id': 'owned/' + x} for x in ['tool', 'unicode', 'cancel', 'redirect']]})
            event('unexpected-path'); self.reply(404, {})
        def do_POST(self):
            if self.path == '/forbidden':
                event('redirect-followed'); return self.reply(500, {})
            if not self.authorized(): return self.reply(401, {'error': 'synthetic unauthorized'})
            if self.path != '/v1/chat/completions': return self.reply(404, {})
            try:
                size = int(self.headers.get('Content-Length', '-1'))
                if not 0 < size <= 1024 * 1024: raise ValueError()
                body = json.loads(self.rfile.read(size))
                model, messages = body['model'], body['messages']
                if model not in ['owned/tool', 'owned/unicode', 'owned/cancel', 'owned/redirect']: raise ValueError()
                if body.get('provider') != {'require_parameters': True, 'allow_fallbacks': False}: raise ValueError()
            except (ValueError, KeyError, TypeError): return self.reply(400, {})
            if model == 'owned/redirect':
                self.send_response(307); self.send_header('Location', 'http://127.0.0.1:%d/forbidden' % self.server.server_port)
                self.send_header('Content-Length', '0'); self.end_headers(); return
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Transfer-Encoding', 'chunked'); self.end_headers()
            def chunk(data):
                self.wfile.write(('%x\r\n' % len(data)).encode() + data + b'\r\n'); self.wfile.flush()
            def frame(delta, finish=None, usage=False):
                value = {'id': 'owned-response', 'choices': [{'index': 0, 'delta': delta, 'finish_reason': finish}]}
                if usage: value['usage'] = {'total_tokens': 2}
                return ('data: ' + json.dumps(value, ensure_ascii=False) + '\n\n').encode()
            try:
                if model == 'owned/cancel':
                    chunk(frame({'content': 'partial synthetic only'})); event('cancel-started')
                    for _ in range(100): time.sleep(.05); chunk(b': keepalive\n\n')
                else:
                    finish = 'stop'
                    if model == 'owned/tool':
                        results = [m for m in messages if m.get('role') == 'tool']
                        if results:
                            if results[0].get('tool_call_id') != 'owned-call-🌍' or '42' not in results[0].get('content', ''): raise ValueError()
                            event('exact-tool-pair'); data = frame({'content': '42'}, finish)
                        else:
                            finish = 'tool_calls'
                            data = frame({'tool_calls': [{'index': 0, 'id': 'owned-call-🌍', 'type': 'function', 'function': {'name': 'calculate', 'arguments': '{"expression":"'}}]})
                            data += frame({'tool_calls': [{'index': 0, 'function': {'arguments': '6*7"}'}}]}, finish)
                    else: data = frame({'content': 'Café 🌍 العربية'}, finish)
                    data += frame({'role': 'assistant', 'content': ''}, finish, usage=True) + b'data: [DONE]\n\n'
                    for byte in data: chunk(bytes([byte]))
                self.wfile.write(b'0\r\n\r\n'); self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError): event('peer-disconnected')
            except ValueError: event('changed-tool-pair')
            finally: self.close_connection = True
    class Server(http.server.ThreadingHTTPServer):
        daemon_threads = True
        allow_reuse_address = False
    server = Server(('127.0.0.1', 0), Handler); server.timeout = .2
    rfd = os.open(ready, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.write(rfd, json.dumps({'pid': os.getpid(), 'port': server.server_port}).encode()); os.close(rfd)
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set()); signal.signal(signal.SIGINT, lambda *_: stop.set())
    deadline = time.monotonic() + a.lifetime
    try:
        while not stop.is_set() and time.monotonic() < deadline: server.handle_request()
    finally:
        server.server_close(); os.close(fd)


if __name__ == '__main__': main()
