#!/usr/bin/env python3
"""Loopback Responses fixture for the signed CLI's planning-only capability gate.

No model, credentials, native tools, filesystem tools, or outbound connections.
Prints its endpoint once. --oracle records only protocol counters/schema metadata.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Fixture:
    def __init__(self, mode, oracle):
        self.mode = mode
        self.oracle = Path(oracle)
        self.lock = threading.Lock()
        self.state = {"requests": 0, "invalid_requests": 0, "advertised_tools": [],
                      "models": [], "output_schema_seen": False, "native_calls_offered": 0,
                      "native_refusal_reported": False, "native_output_metadata": [], "unexpected_authorization": False}
        self.save()

    def save(self):
        temporary = self.oracle.with_suffix(self.oracle.suffix + ".new")
        temporary.write_text(json.dumps(self.state, indent=2), encoding="utf-8")
        os.chmod(temporary, 0o600)
        os.replace(temporary, self.oracle)

    def process(self, body, authorization):
        with self.lock:
            self.state["requests"] += 1
            request_number = self.state["requests"]
            tools = body.get("tools", [])
            names = [item.get("name", item.get("type", "unknown")) for item in tools if isinstance(item, dict)] if isinstance(tools, list) else ["invalid"]
            self.state["advertised_tools"].extend(names)
            self.state["models"].append(body.get("model"))
            for item in body.get("input", []):
                if isinstance(item, dict) and "output" in item:
                    output = item["output"]
                    summary = json.dumps(output).lower()
                    self.state["native_output_metadata"].append({"type": item.get("type"),
                        "matches_fixture_call": item.get("call_id") == "call_fixture_forbidden", "output_type": type(output).__name__,
                        "unsupported": "unsupported" in summary, "unknown": "unknown" in summary,
                        "denied": "denied" in summary, "exec_command": "exec_command" in summary})
                    if item.get("type") == "function_call_output" and item.get("call_id") == "call_fixture_forbidden":
                        self.state["native_refusal_reported"] |= "exec_command" in summary and ("unsupported" in summary or "unknown" in summary)
            schema = body.get("text", {}).get("format", {}).get("schema", {})
            has_schema = set(schema.get("properties", {})) == {"content", "tool_name", "arguments_json"}
            self.state["output_schema_seen"] |= has_schema
            bad_auth = authorization is not None and authorization != "Bearer relay-loopback-not-a-real-key"
            self.state["unexpected_authorization"] |= bad_auth
            valid = isinstance(tools, list) and not tools and body.get("model") == "gpt-6.1-terra" and not bad_auth and has_schema
            if not valid:
                self.state["invalid_requests"] += 1
                self.save()
                return None
            response_id = "resp_fixture_" + uuid.uuid4().hex
            if self.mode == "native" and request_number == 1:
                self.state["native_calls_offered"] += 1
                item = {"type": "function_call", "id": "fc_fixture_forbidden", "call_id": "call_fixture_forbidden",
                        "name": "exec_command", "arguments": json.dumps({"cmd": "/usr/bin/true"}), "status": "completed"}
            else:
                proposal = self.mode == "proposal"
                answer = {"content": "Propose opening the synthetic fixture." if proposal else "Relay synthetic planning ready.",
                          "tool_name": "launch_app" if proposal else "",
                          "arguments_json": json.dumps({"name": "Synthetic Fixture"}) if proposal else "{}"}
                item = {"type": "message", "id": "msg_fixture", "role": "assistant", "status": "completed",
                        "content": [{"type": "output_text", "text": json.dumps(answer), "annotations": []}]}
            self.save()
            return response_id, item


def events(response_id, item):
    base = {"id": response_id, "object": "response", "created_at": 1, "model": "gpt-6.1-terra", "error": None,
            "incomplete_details": None, "status": "in_progress", "output": []}
    yield "response.created", {"type": "response.created", "response": base}
    pending = dict(item, status="in_progress")
    if item["type"] == "message":
        pending["content"] = []
    else:
        pending["arguments"] = ""
    yield "response.output_item.added", {"type": "response.output_item.added", "output_index": 0, "item": pending}
    if item["type"] == "message":
        part = item["content"][0]
        yield "response.content_part.added", {"type": "response.content_part.added", "item_id": item["id"], "output_index": 0,
                                               "content_index": 0, "part": dict(part, text="")}
        yield "response.output_text.delta", {"type": "response.output_text.delta", "item_id": item["id"], "output_index": 0,
                                             "content_index": 0, "delta": part["text"]}
        yield "response.output_text.done", {"type": "response.output_text.done", "item_id": item["id"], "output_index": 0,
                                            "content_index": 0, "text": part["text"]}
        yield "response.content_part.done", {"type": "response.content_part.done", "item_id": item["id"], "output_index": 0,
                                              "content_index": 0, "part": part}
    else:
        yield "response.function_call_arguments.delta", {"type": "response.function_call_arguments.delta", "item_id": item["id"],
                                                         "output_index": 0, "delta": item["arguments"]}
        yield "response.function_call_arguments.done", {"type": "response.function_call_arguments.done", "item_id": item["id"],
                                                        "output_index": 0, "arguments": item["arguments"]}
    yield "response.output_item.done", {"type": "response.output_item.done", "output_index": 0, "item": item}
    yield "response.completed", {"type": "response.completed", "response": dict(base, status="completed", output=[item],
        usage={"input_tokens": 16, "output_tokens": 16, "total_tokens": 32, "input_tokens_details": {"cached_tokens": 0},
               "output_tokens_details": {"reasoning_tokens": 0}})}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["answer", "proposal", "native"], default="answer")
    parser.add_argument("--oracle", required=True)
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    fixture = Fixture(args.mode, args.oracle)

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_POST(self):
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if self.client_address[0] != "127.0.0.1" or self.path != "/v1/responses" or not 0 < length <= 524288:
                    raise ValueError("invalid request boundary")
                body = json.loads(self.rfile.read(length))
                if not isinstance(body, dict):
                    raise ValueError("request must be an object")
                result = fixture.process(body, self.headers.get("Authorization"))
                if result is None:
                    raise ValueError("native tools, unexpected model, or real authorization are forbidden")
            except (ValueError, TypeError, json.JSONDecodeError):
                self.send_error(400)
                return
            payload = b"".join(("event: " + name + "\ndata: " + json.dumps(dict(event, sequence_number=index)) + "\n\n").encode()
                               for index, (name, event) in enumerate(events(*result)))
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                self.wfile.write(payload)
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    def terminate(_signal, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, terminate)
    print(json.dumps({"endpoint": f"http://127.0.0.1:{server.server_port}/v1", "mode": args.mode}), flush=True)
    try:
        server.serve_forever(poll_interval=0.1)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
