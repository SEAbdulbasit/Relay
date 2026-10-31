import http.server
import socketserver
import threading
import socket
import urllib.request
import time
from pathlib import Path

class LocalWebsiteServer:
    """
    Spins up an ephemeral HTTP server serving /website locally
    to perform opaque-box network queries, asset checks, and link crawls.
    """

    def __init__(self, directory: Path):
        self.directory = directory
        self.port = self._find_free_port()
        self.httpd = None
        self.thread = None

    def _find_free_port(self) -> int:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.bind(('', 0))
            return s.getsockname()[1]

    def start(self):
        handler = lambda *args, **kwargs: http.server.SimpleHTTPRequestHandler(
            *args, directory=str(self.directory), **kwargs
        )
        self.httpd = socketserver.TCPServer(("127.0.0.1", self.port), handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()
        # Give server time to bind
        time.sleep(0.1)

    def stop(self):
        if self.httpd:
            self.httpd.shutdown()
            self.httpd.server_close()
        if self.thread:
            self.thread.join(timeout=1.0)

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def fetch(self, path: str = "/") -> tuple:
        """Returns (status_code, headers, body_str)"""
        url = f"{self.base_url}{path}"
        req = urllib.request.Request(url, headers={"User-Agent": "Relay-E2E-Tester"})
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                body = resp.read().decode("utf-8")
                return resp.status, resp.headers, body
        except urllib.error.HTTPError as e:
            return e.code, e.headers, ""
        except Exception as e:
            return 500, {}, str(e)
