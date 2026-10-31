#!/usr/bin/env python3
"""Loopback-only synthetic browser fixture. Never use with personal form data."""
import argparse
from collections import deque
import html
import json
import secrets
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

MARKER = "Relay browser fixture · Café 🌍 · مرحبا"
FORM_VALUE = "Relay synthetic note 123"
EDITABLE_SENTINEL = "FORM_VALUE_MUST_NOT_APPEAR_IN_PAGE_READ"


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, port=0):
        super().__init__(("127.0.0.1", port), FixtureHandler)
        self.token = secrets.token_hex(16)
        self.submissions = 0
        self.post_attempts = 0
        self.rejected_posts = 0
        self.get_requests = 0
        self.recent_requests = deque(maxlen=32)
        self.lock = threading.Lock()

    def state(self):
        with self.lock:
            return {"fixture": "relay-browser-v2", "submissions": self.submissions,
                    "postAttempts": self.post_attempts, "rejectedPosts": self.rejected_posts,
                    "getRequests": self.get_requests, "recentRequests": list(self.recent_requests),
                    "applied": FORM_VALUE if self.submissions else None}

    def record_request(self, method, route, status, rejected=False):
        # Fixed route labels only: no raw URL, token, query, input or headers retained.
        known = {"fixture", "reading", "next", "redirect", "secure-field", "result", "state", "submit"}
        with self.lock:
            if method == "GET":
                self.get_requests += 1
            if rejected:
                self.rejected_posts += 1
            self.recent_requests.append({"method": method, "route": route if route in known else "unknown", "status": status})


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *_args):
        pass  # No browser URLs, submitted bodies or personal context in access logs.

    def valid_host(self):
        return self.headers.get("Host") == f"127.0.0.1:{self.server.server_port}"

    def route(self):
        parsed = urlsplit(self.path)
        parts = parsed.path.split("/")
        if parsed.query or len(parts) != 3 or parts[2] != self.server.token:
            return None
        return parts[1]

    def respond(self, status, body, content_type="text/html; charset=utf-8", location=None):
        payload = body.encode("utf-8")
        self.server.record_request(self.command, self.route(), status, rejected=self.command == "POST" and status >= 400)
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
        if location:
            self.send_header("Location", location)
        self.end_headers()
        self.wfile.write(payload)

    def page(self, title, body):
        return f'''<!doctype html><html lang="en"><meta charset="utf-8"><title>{html.escape(title)}</title>
<style>body{{font:20px system-ui;max-width:760px;margin:60px auto;padding:24px;color:#fff;background:#111318}}input,button{{font:inherit;padding:12px;margin:12px 0}}label{{display:block}}</style>
<h1>{html.escape(title)}</h1>{body}</html>'''

    def do_GET(self):
        if not self.valid_host():
            self.respond(403, "Loopback Host required", "text/plain; charset=utf-8"); return
        route = self.route()
        token = self.server.token
        if route == "state":
            self.respond(200, json.dumps(self.server.state(), ensure_ascii=False), "application/json; charset=utf-8")
        elif route == "fixture":
            self.respond(200, self.page("Relay browser qualification", f'''<p>{MARKER}</p>
<p>Only synthetic content. Navigation and reading must not submit this form.</p>
<a href="/next/{token}">Next synthetic page</a>
<form method="post" action="/submit/{token}"><label for="note">Synthetic note</label>
<input id="note" name="note" value="{EDITABLE_SENTINEL}" maxlength="128" autocomplete="off">
<button type="submit">Apply synthetic note</button></form>'''))
        elif route == "reading":
            self.respond(200, self.page("Relay read-only qualification", f'<p>{MARKER}</p><p>No forms or editable controls exist on this route.</p><a href="/next/{token}">Next synthetic page</a>'))
        elif route == "next":
            self.respond(200, self.page("Relay next page", "<p>NEXT_PAGE_MARKER_456</p>"))
        elif route == "redirect":
            self.respond(302, "Synthetic local redirect", location=f"/next/{token}")
        elif route == "secure-field":
            self.respond(200, self.page("Synthetic secure field", '<p>Reader should refuse secure controls.</p><label for="secret">Synthetic password (leave empty)</label><input id="secret" type="password" value="">'))
        elif route == "result":
            state = self.server.state()
            self.respond(200, self.page("Relay form result", f'<p>Submission count: {state["submissions"]}</p><p>Applied value: {html.escape(state["applied"] or "none")}</p>'))
        else:
            self.respond(404, "Unknown synthetic route", "text/plain; charset=utf-8")

    def do_POST(self):
        with self.server.lock:
            self.server.post_attempts += 1
        # Count every attempt before rejection: zero accepted submissions alone does not
        # establish that a navigation/read avoided dispatching a form POST.
        # Only the known synthetic value can be stored, even if this fixture is misused.
        if not self.valid_host() or self.route() != "submit" or self.headers.get("Transfer-Encoding"):
            self.close_connection = True
            self.respond(403, "Rejected", "text/plain; charset=utf-8"); return
        try:
            length = int(self.headers.get("Content-Length", "-1"))
            if not 0 <= length <= 512 or self.headers.get_content_type() != "application/x-www-form-urlencoded":
                raise ValueError()
            self.connection.settimeout(2)
            data = self.rfile.read(length)
            if len(data) != length:
                raise ValueError()
            values = parse_qs(data.decode("ascii"), strict_parsing=True, max_num_fields=2)
            if values != {"note": [FORM_VALUE]}:
                raise ValueError()
        except (ValueError, UnicodeError, TimeoutError):
            self.close_connection = True
            self.respond(400, "Only the exact synthetic note is accepted; nothing changed.", "text/plain; charset=utf-8"); return
        with self.server.lock:
            self.server.submissions += 1
        self.respond(303, "Synthetic note applied", location=f"/result/{self.server.token}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    if not 0 <= args.port <= 65535:
        parser.error("port must be 0…65535")
    server = FixtureServer(args.port)
    base = f"http://127.0.0.1:{server.server_port}"
    print(json.dumps({"base": base, "token": server.token, "fixture": f"{base}/fixture/{server.token}",
                      "state": f"{base}/state/{server.token}", "synthetic_value": FORM_VALUE}), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
