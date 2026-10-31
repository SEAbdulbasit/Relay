import http.client
import importlib.util
from pathlib import Path
import threading
import unittest
from urllib.parse import urlencode

spec = importlib.util.spec_from_file_location("relay_fixture", Path(__file__).parents[1] / "browser-qualification-fixture.py")
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class BrowserFixtureTests(unittest.TestCase):
    def setUp(self):
        self.server = fixture.FixtureServer()
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.token = self.server.token

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def request(self, method, route, body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        try:
            connection.request(method, f"/{route}/{self.token}", body=body, headers=headers or {})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read().decode("utf-8")
        finally:
            connection.close()

    def test_read_has_unicode_no_external_assets_and_no_form_effect(self):
        status, headers, body = self.request("GET", "fixture")
        self.assertEqual(status, 200)
        self.assertIn(fixture.MARKER, body)
        self.assertIn(fixture.EDITABLE_SENTINEL, body)
        self.assertNotIn("<script", body)
        self.assertNotIn("https://", body)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(self.server.state()["submissions"], 0)
        self.assertEqual(self.server.state()["postAttempts"], 0)
        self.assertEqual(self.server.state()["rejectedPosts"], 0)

    def test_only_exact_synthetic_form_changes_independent_state(self):
        headers = {"Content-Type": "application/x-www-form-urlencoded"}
        for body in ["note=private", "note=Relay+synthetic+note+123&extra=bad", "note=x&note=y"]:
            self.assertEqual(self.request("POST", "submit", body, headers)[0], 400)
            self.assertEqual(self.server.state()["submissions"], 0)
        status, response_headers, _ = self.request("POST", "submit", urlencode({"note": fixture.FORM_VALUE}), headers)
        self.assertEqual(status, 303)
        self.assertEqual(response_headers["Location"], f"/result/{self.token}")
        self.assertEqual(self.server.state()["submissions"], 1)
        self.assertEqual(self.server.state()["applied"], fixture.FORM_VALUE)
        self.assertIn('"submissions": 1', self.request("GET", "state")[2])
        self.assertEqual(self.server.state()["postAttempts"], 4)
        self.assertEqual(self.server.state()["rejectedPosts"], 3)

    def test_wrong_host_route_and_body_budget_do_not_mutate(self):
        self.assertEqual(self.request("GET", "fixture", headers={"Host": "external.invalid"})[0], 403)
        self.assertEqual(self.request("GET", "unknown")[0], 404)
        self.assertEqual(self.request("POST", "submit", "x" * 513, {"Content-Type": "application/x-www-form-urlencoded"})[0], 400)
        self.assertEqual(self.server.state()["submissions"], 0)

    def test_rejected_posts_remain_visible_even_when_no_submission_succeeds(self):
        headers = {"Content-Type": "application/x-www-form-urlencoded"}
        self.assertEqual(self.request("POST", "submit", "note=wrong", headers)[0], 400)
        self.assertEqual(self.request("POST", "unknown", "note=wrong", headers)[0], 403)
        state = self.server.state()
        self.assertEqual(state["submissions"], 0)
        self.assertEqual(state["postAttempts"], 2)
        self.assertEqual(state["rejectedPosts"], 2)
        self.assertEqual(state["recentRequests"], [
            {"method": "POST", "route": "submit", "status": 400},
            {"method": "POST", "route": "unknown", "status": 403}])
        self.assertNotIn("note=wrong", str(state))
        self.assertNotIn(self.token, str(state))

    def test_reading_route_has_no_form_and_audit_is_bounded(self):
        status, _, body = self.request("GET", "reading")
        self.assertEqual(status, 200)
        self.assertIn(fixture.MARKER, body)
        self.assertNotIn("<form", body)
        self.assertNotIn("<input", body)
        for _ in range(40):
            self.request("GET", "next")
        state = self.server.state()
        self.assertEqual(state["getRequests"], 41)
        self.assertEqual(len(state["recentRequests"]), 32)
        self.assertEqual(state["postAttempts"], 0)

    def test_redirect_and_secure_control_are_explicit_synthetic_cases(self):
        status, headers, _ = self.request("GET", "redirect")
        self.assertEqual(status, 302)
        self.assertEqual(headers["Location"], f"/next/{self.token}")
        self.assertIn('type="password" value=""', self.request("GET", "secure-field")[2])
        self.assertEqual(self.server.state()["submissions"], 0)


if __name__ == "__main__":
    unittest.main()
