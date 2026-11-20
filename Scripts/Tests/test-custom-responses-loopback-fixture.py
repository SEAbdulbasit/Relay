#!/usr/bin/env python3
"""Owned opt-in synthetic Responses HTTP peer; no model, real key, provider or body log."""
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

        def log_message(self, *_):
            pass

        def reply(self, status, value):
            body = json.dumps(value).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def authorized(self):
            good = self.headers.get('Authorization') == 'Bearer SYNTHETIC-RESPONSES-KEY-4926'
            good = good and not any(self.headers.get(h) for h in ['Proxy-Authorization', 'Cookie', 'X-API-Key'])
            event('exact-own-key' if good else 'wrong-credential')
            return good

        def do_GET(self):
            if self.path == '/keyless/v1/models':
                if any(self.headers.get(h) is not None for h in ['Authorization', 'Proxy-Authorization', 'Cookie', 'X-API-Key']):
                    event('keyless-ambient-credential')
                    return self.reply(401, {})
                event('keyless-models')
                return self.reply(200, {'data': [{'id': 'owned/unicode'}]})
            if not self.authorized():
                return self.reply(401, {'error': 'synthetic unauthorized'})
            if self.path == '/v1/models':
                return self.reply(200, {'data': [{'id': 'owned/' + x} for x in ['tool', 'unicode', 'cancel', 'redirect']]})
            event('unexpected-path')
            self.reply(404, {})

        def do_POST(self):
            if self.path == '/forbidden':
                event('redirect-followed')
                return self.reply(500, {})
            keyless = self.path == '/keyless/v1/responses'
            if keyless:
                if any(self.headers.get(h) is not None for h in ['Authorization', 'Proxy-Authorization', 'Cookie', 'X-API-Key']):
                    event('keyless-ambient-credential')
                    return self.reply(401, {})
                event('keyless-responses')
            elif not self.authorized():
                return self.reply(401, {'error': 'synthetic unauthorized'})
            if self.path not in ['/v1/responses', '/keyless/v1/responses']:
                return self.reply(404, {})
            try:
                size = int(self.headers.get('Content-Length', '-1'))
                if not 0 < size <= 1024 * 1024:
                    raise ValueError()
                body = json.loads(self.rfile.read(size))
                model, items = body['model'], body['input']
                if model not in ['owned/tool', 'owned/unicode', 'owned/cancel', 'owned/redirect']:
                    raise ValueError()
            except (ValueError, KeyError, TypeError):
                return self.reply(400, {})
            if model == 'owned/redirect':
                self.send_response(307)
                self.send_header('Location', 'http://127.0.0.1:%d/forbidden' % self.server.server_port)
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Transfer-Encoding', 'chunked')
            self.end_headers()

            def chunk(data):
                self.wfile.write(('%x\r\n' % len(data)).encode() + data + b'\r\n')
                self.wfile.flush()

            def sse(obj):
                return ('data: ' + json.dumps(obj, ensure_ascii=False) + '\n\n').encode()

            try:
                if model == 'owned/cancel':
                    chunk(sse({'type': 'response.created', 'response': {'id': 'resp_cancel', 'status': 'in_progress'}}))
                    chunk(sse({'type': 'response.output_text.delta', 'delta': 'partial synthetic only'}))
                    event('cancel-started')
                    for _ in range(100):
                        time.sleep(.05)
                        chunk(b': keepalive\n\n')
                elif model == 'owned/tool':
                    outputs = [m for m in items if m.get('type') == 'function_call_output']
                    if outputs:
                        if outputs[0].get('call_id') != 'owned-call-🌍' or '42' not in outputs[0].get('output', ''):
                            raise ValueError()
                        event('exact-tool-pair')
                        data = (
                            sse({'type': 'response.created', 'response': {'id': 'resp_2', 'status': 'in_progress'}})
                            + sse({'type': 'response.output_text.delta', 'delta': '42'})
                            + sse({'type': 'response.completed', 'response': {'id': 'resp_2', 'status': 'completed', 'output': [{'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': '42'}]}]}})
                            + b'data: [DONE]\n\n'
                        )
                    else:
                        data = (
                            sse({'type': 'response.created', 'response': {'id': 'resp_1', 'status': 'in_progress'}})
                            + sse({'type': 'response.output_item.added', 'output_index': 0, 'item': {'id': 'fc_1', 'type': 'function_call', 'call_id': 'owned-call-🌍', 'name': 'mcp__calc__calculate', 'arguments': ''}})
                            + sse({'type': 'response.function_call_arguments.delta', 'item_id': 'fc_1', 'output_index': 0, 'delta': '{"expression":"'})
                            + sse({'type': 'response.function_call_arguments.delta', 'item_id': 'fc_1', 'output_index': 0, 'delta': '6*7"}'})
                            + sse({'type': 'response.output_item.done', 'output_index': 0, 'item': {'id': 'fc_1', 'type': 'function_call', 'call_id': 'owned-call-🌍', 'name': 'mcp__calc__calculate', 'arguments': '{"expression":"6*7"}'}})
                            + sse({'type': 'response.completed', 'response': {'id': 'resp_1', 'status': 'completed', 'output': [{'id': 'fc_1', 'type': 'function_call', 'call_id': 'owned-call-🌍', 'name': 'mcp__calc__calculate', 'arguments': '{"expression":"6*7"}'}]}})
                            + b'data: [DONE]\n\n'
                        )
                    for byte in data:
                        chunk(bytes([byte]))
                else:
                    data = (
                        sse({'type': 'response.created', 'response': {'id': 'resp_u', 'status': 'in_progress'}})
                        + sse({'type': 'response.output_text.delta', 'delta': 'Café 🌍 العربية'})
                        + sse({'type': 'response.completed', 'response': {'id': 'resp_u', 'status': 'completed', 'output': [{'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'Café 🌍 العربية'}]}]}})
                        + b'data: [DONE]\n\n'
                    )
                    for byte in data:
                        chunk(bytes([byte]))
                self.wfile.write(b'0\r\n\r\n')
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                event('peer-disconnected')
            except ValueError:
                event('changed-tool-pair')
            finally:
                self.close_connection = True

    class Server(http.server.ThreadingHTTPServer):
        daemon_threads = True
        allow_reuse_address = False

    server = Server(('127.0.0.1', 0), Handler)
    server.timeout = .2
    rfd = os.open(ready, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.write(rfd, json.dumps({'pid': os.getpid(), 'port': server.server_port}).encode())
    os.close(rfd)
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    deadline = time.monotonic() + a.lifetime
    try:
        while not stop.is_set() and time.monotonic() < deadline:
            server.handle_request()
    finally:
        server.server_close()
        os.close(fd)


if __name__ == '__main__':
    main()
