#!/usr/bin/env python3
"""Disposable loopback-only fixture for Relay's direct MCP client."""
import base64
import json
import threading
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "2026-07-28"
LEGACY = "2025-11-25"
RESOURCE = "fixture://reports/selected"
TOKEN = "relay-fixture-token"


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.counts = Counter()
        self.lock = threading.Lock()

    def record(self, event):
        with self.lock:
            self.counts[event] += 1


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def respond(self, status, document=None, *, stream=False, location=None):
        body = b""
        if document is not None:
            body = json.dumps(document, ensure_ascii=False).encode()
            if stream:
                notice = b'data: {"jsonrpc":"2.0","method":"notifications/progress"}\n\n'
                body = notice + b"event: message\ndata: " + body + b"\n\n"
        self.send_response(status)
        self.send_header("Content-Type", "text/event-stream" if stream else "application/json")
        self.send_header("Content-Length", str(len(body)))
        if location:
            self.send_header("Location", location)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path != "/state":
            self.respond(404)
            return
        with self.server.lock:
            state = dict(self.server.counts)
        self.respond(200, state)

    def do_POST(self):
        if self.path == "/sink":
            self.server.record("redirect_sink")
            if self.headers.get("Authorization"):
                self.server.record("forwarded_bearer")
            self.respond(400)
            return
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            self.server.record("bad_bearer")
            self.respond(401)
            return
        if self.path == "/redirect":
            self.server.record("redirect")
            self.respond(307, location=f"http://localhost:{self.server.server_port}/sink")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            assert 0 < length <= 8192
            message = json.loads(self.rfile.read(length))
            assert message["jsonrpc"] == "2.0"
            method = message["method"]
            params = message.get("params", {})
            identifier = message.get("id")
            if self.path == "/legacy":
                self.legacy(method, params, identifier)
                return
            assert self.path == "/mcp"
            assert self.headers["MCP-Protocol-Version"] == VERSION
            assert self.headers["Mcp-Method"] == method
            assert self.headers.get("Mcp-Session-Id") is None
            assert params["_meta"]["io.modelcontextprotocol/protocolVersion"] == VERSION
            assert params["_meta"]["io.modelcontextprotocol/clientCapabilities"] == {}
            self.modern(method, params, identifier)
        except (AssertionError, KeyError, ValueError, TypeError):
            self.server.record("bad_protocol")
            self.respond(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32020, "message": "Fixture mismatch"}})

    def result(self, identifier, fields, *, modern=True, stream=False):
        if modern:
            fields["resultType"] = "complete"
        self.respond(200, {"jsonrpc": "2.0", "id": identifier, "result": fields}, stream=stream)

    def modern(self, method, params, identifier):
        self.server.record("modern:" + method)
        if method == "server/discover":
            self.result(identifier, {"supportedVersions": [VERSION], "capabilities": {"resources": {}, "tools": {}},
                "_meta": {"io.modelcontextprotocol/serverInfo": {"name": "Synthetic direct MCP"}}})
        elif method == "resources/list":
            self.list_resources(params, identifier)
        elif method == "tools/list":
            self.result(identifier, {"tools": [
                {"name": "read_fixture", "annotations": {"readOnlyHint": True, "destructiveHint": False},
                 "inputSchema": {"type": "object", "required": ["region"], "additionalProperties": False,
                                 "properties": {"region": {"type": "string", "x-mcp-header": "Region"}}}},
                {"name": "write_fixture", "annotations": {"readOnlyHint": False}, "inputSchema": {"type": "object"}}
            ]})
        elif method == "resources/read":
            assert self.headers["Mcp-Name"] == params["uri"] == RESOURCE
            self.read_resource(identifier)
        elif method == "tools/call":
            assert self.headers["Mcp-Name"] == params["name"] == "read_fixture"
            assert params["arguments"] == {"region": "Café"}
            encoded = base64.b64encode("Café".encode()).decode()
            assert self.headers["Mcp-Param-Region"] == f"=?base64?{encoded}?="
            self.result(identifier, {"content": [{"type": "text", "text": "Synthetic SSE result · Café"}]}, stream=True)
        else:
            raise AssertionError(method)

    def legacy(self, method, params, identifier):
        self.server.record("legacy:" + method)
        if method == "server/discover":
            self.respond(400, {"jsonrpc": "2.0", "id": identifier, "error": {
                "code": -32022, "message": "Unsupported version", "data": {"supported": [LEGACY]}}})
            return
        if method == "initialize":
            assert self.headers.get("Mcp-Session-Id") is None and params["protocolVersion"] == LEGACY
            body = json.dumps({"jsonrpc": "2.0", "id": identifier, "result": {
                "protocolVersion": LEGACY, "serverInfo": {"name": "Synthetic legacy MCP"},
                "capabilities": {"resources": {}}}}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Mcp-Session-Id", "relay-fixture-session")
            self.end_headers()
            self.wfile.write(body)
            return
        assert self.headers["Mcp-Session-Id"] == "relay-fixture-session"
        assert self.headers["MCP-Protocol-Version"] == LEGACY
        if method == "notifications/initialized":
            assert identifier is None
            self.respond(202)
        elif method == "resources/list":
            self.list_resources(params, identifier, modern=False)
        elif method == "resources/read":
            assert params["uri"] == RESOURCE
            self.read_resource(identifier, modern=False)
        else:
            raise AssertionError(method)

    def list_resources(self, params, identifier, modern=True):
        if "cursor" not in params:
            self.result(identifier, {"resources": [{"uri": RESOURCE, "name": "Selected report"}], "nextCursor": "page-two"}, modern=modern)
        else:
            assert params["cursor"] == "page-two"
            self.result(identifier, {"resources": [{"uri": "fixture://reports/other", "name": "Other report"}]}, modern=modern)

    def read_resource(self, identifier, modern=True):
        self.result(identifier, {"contents": [{"uri": RESOURCE, "text": "Synthetic selected report"},
            {"uri": "fixture://reports/other", "text": "UNREVIEWED_RESOURCE_SENTINEL"}]}, modern=modern)


if __name__ == "__main__":
    with Server() as server:
        print(f"http://127.0.0.1:{server.server_port}", flush=True)
        server.serve_forever()
