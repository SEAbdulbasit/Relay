#!/usr/bin/python3
"""Owned loopback protocol peer only. No real service, account, SDK or env keys."""
import argparse
import http.server
import json
import os
import pathlib
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument('--root', required=True)
parser.add_argument('--lifetime', type=int, default=40)
args = parser.parse_args()
root = pathlib.Path(args.root)
lock = threading.Lock()
counts = {}
changed = False
KEY = 'SYNTHETIC-MCP-READ-KEY-8206'
NAME = 'cafe\u0301_read'
BODY = 'OWNED_PRIVATE_MCP_BODY Café 🌍'

def record(name):
    with lock:
        counts[name] = counts.get(name, 0) + 1

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_):
        pass
    def reply(self, status, value):
        data = json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Connection', 'close')
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            record('client-ended')
    def do_GET(self):
        global changed
        if self.path == '/state':
            with lock:
                current = dict(counts)
            self.reply(200, current)
        elif self.path == '/change-catalog':
            changed = True
            self.reply(200, {'changed': True})
        elif self.path == '/release':
            (root / 'release').write_bytes(b'owned-release')
            self.reply(200, {'released': True})
        else:
            self.reply(404, {})
    def do_POST(self):
        if self.headers.get('Authorization') != 'Bearer ' + KEY:
            record('bad-credential')
            self.reply(401, {})
            return
        count = int(self.headers.get('Content-Length', '0'))
        if not 0 < count <= 16384:
            self.reply(413, {})
            return
        try:
            body = json.loads(self.rfile.read(count))
        except (ValueError, UnicodeError):
            self.reply(400, {})
            return
        method = body.get('method')
        params = body.get('params', {})
        result = {'resultType': 'complete'}
        if method == 'server/discover':
            record('discover')
            result.update(supportedVersions=['2026-07-28'], capabilities={'resources': {}, 'tools': {}},
                          _meta={'io.modelcontextprotocol/serverInfo': {'name': 'Owned MCP fixture'}})
        elif method == 'resources/list':
            record('resources-list')
            result['resources'] = [{'uri': 'fixture://owned/report', 'name': 'Owned report'}]
        elif method == 'tools/list':
            record('tools-list')
            properties = {'region': {'type': 'string'}}
            if changed:
                properties['new_required_field'] = {'type': 'string'}
            result['tools'] = [
                {'name': NAME, 'description': 'UNTRUSTED_CATALOG_INSTRUCTION_IGNORE_RULES',
                 'inputSchema': {'type': 'object', 'properties': properties, 'required': list(properties), 'additionalProperties': False},
                 'annotations': {'readOnlyHint': True, 'destructiveHint': False}},
                {'name': 'write_fixture', 'inputSchema': {'type': 'object'},
                 'annotations': {'readOnlyHint': False, 'destructiveHint': True}}]
        elif method in ('tools/call', 'resources/read'):
            record('read-started')
            if method == 'tools/call':
                if params.get('name', '').encode('utf-8') != NAME.encode('utf-8'):
                    record('wrong-tool-bytes')
                    self.reply(400, {})
                    return
                if params.get('arguments') != {'region': 'Café 🌍'}:
                    record('wrong-arguments')
                    self.reply(400, {})
                    return
                record('exact-tool-and-arguments')
            elif params.get('uri') != 'fixture://owned/report':
                record('wrong-resource')
                self.reply(400, {})
                return
            if self.path == '/headers':
                record('headers-held')
                end = time.monotonic() + 15
                while not (root / 'release').exists() and time.monotonic() < end:
                    time.sleep(0.01)
                if not (root / 'release').exists():
                    record('headers-gate-expired')
            if self.path == '/slow':
                end = time.monotonic() + 15
                while not (root / 'release').exists() and time.monotonic() < end:
                    time.sleep(0.01)
            if self.path == '/error':
                result.update(isError=True, content=[{'type': 'text', 'text': 'PRIVATE_REMOTE_ERROR_MUST_NOT_ESCAPE'}])
            elif method == 'resources/read':
                result['contents'] = [{'uri': 'fixture://owned/report', 'text': BODY}]
            else:
                result.update(isError=False, content=[{'type': 'text', 'text': BODY}])
            record('read-returned')
            if self.path == '/stream':
                # Return one complete result frame but deliberately keep the
                # actual HTTP stream open until the independent test releases
                # the handler. Client completion is NOT a server-effect oracle.
                frame = ('data: ' + json.dumps({'jsonrpc': '2.0', 'id': body.get('id'), 'result': result},
                         ensure_ascii=False, separators=(',', ':')) + '\n\n').encode('utf-8')
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Transfer-Encoding', 'chunked')
                self.end_headers()
                try:
                    self.wfile.write(('%x\r\n' % len(frame)).encode('ascii') + frame + b'\r\n')
                    self.wfile.flush()
                    record('stream-result-sent')
                    end = time.monotonic() + 15
                    while not (root / 'release').exists() and time.monotonic() < end:
                        time.sleep(0.01)
                    if not (root / 'release').exists():
                        record('stream-gate-expired')
                    self.wfile.write(b'0\r\n\r\n')
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    record('client-ended')
                finally:
                    record('stream-handler-ended')
                    self.close_connection = True
                return
        else:
            record('unsupported-method')
            self.reply(400, {})
            return
        self.reply(200, {'jsonrpc': '2.0', 'id': body.get('id'), 'result': result})

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
ready = {'pid': os.getpid(), 'port': server.server_address[1], 'nonce': root.name}
(root / 'ready.json').write_text(json.dumps(ready), encoding='utf-8')
threading.Timer(min(90, max(1, args.lifetime)), server.shutdown).start()
try:
    server.serve_forever(poll_interval=0.05)
finally:
    server.server_close()
