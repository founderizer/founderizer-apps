#!/usr/bin/env python3
"""Loopback-only, synthetic owner API fault harness. No fleet or AI connections."""

import argparse
import hashlib
import json
import os
import signal
import socket
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


CANARY = "SYNTHETIC-FLEET-422-CANARY"
MODES = ("lost-response", "reject-422", "notifications")


class FaultState:
    def __init__(self, mode, log, hold_receipt=False):
        if mode not in MODES:
            raise ValueError("unknown fault mode")
        self.mode = mode
        self.db = "synthetic-fault-" + str(uuid.uuid4())
        self.created = time.time()
        self.log = log
        self.lock = threading.Lock()
        self.message = None
        self.receipt_visible = not hold_receipt
        self.identity = None
        self.posts = 0
        self.dispatches = 0
        self.dropped_responses = 0
        self.state_reads = 0
        self.receipt_exposures = 0
        self.refusals_422 = 0
        self.requests = {}
        self.notification_needs = []
        self.manager_warning = None

    def event(self, event, **safe_metadata):
        # Callers pass counts, status and validated UUIDs only. Never bodies/headers.
        print(json.dumps(dict(event=event, **safe_metadata)), file=self.log, flush=True)

    def snapshot(self):
        with self.lock:
            self.state_reads += 1
            messages = [] if self.message is None or not self.receipt_visible else [dict(self.message)]
            if messages:
                self.receipt_exposures += 1
            return dict(
                schema_version=1, db=self.db, time=time.time(),
                manager_flag="SYNTHETIC LOCAL TEST: no agents or fleet writes (" + self.mode + ").",
                manager_warning=self.manager_warning,
                agents=[], tasks=[], notes=[], permissions=[], reports=[], messages=messages,
                needs=self.notification_needs if self.mode == "notifications" else [dict(id=900001, title="SYNTHETIC draft-removal check",
                            why="Local test only. This request has no agent or worker task.",
                            todo="Store an answer draft for the test. Do not send this answer.",
                            raised=self.created, by="manager", answer=None, answered=None)],
            )

    def control(self, data):
        if not data or set(data) - {"mode", "release_receipt", "raise_need", "answer_need", "raise_warning", "clear_warning"}:
            return 400, {"error": "unsupported control"}
        if "mode" in data and data["mode"] not in MODES:
            return 400, {"error": "unknown fault mode"}
        if "release_receipt" in data and data["release_receipt"] is not True:
            return 400, {"error": "release_receipt must be true"}
        if any(key in data for key in ("raise_need", "answer_need", "raise_warning", "clear_warning")) and self.mode != "notifications":
            return 400, {"error": "notification mode required"}
        with self.lock:
            if data.get("raise_warning") is True:
                self.manager_warning = dict(kind="down", since=time.time())
            if data.get("clear_warning") is True:
                self.manager_warning = None
            if data.get("raise_need") is True:
                self.notification_needs.append(dict(id=900001 + len(self.notification_needs),
                    title="SYNTHETIC notification check", why="Local notification test only.",
                    todo="Open this request from the Fleet notification.", raised=time.time(),
                    by="manager", answer=None, answered=None))
            if data.get("answer_need") is True and self.notification_needs:
                self.notification_needs[-1]["answer"] = "Synthetic check complete"
                self.notification_needs[-1]["answered"] = time.time()
            if "mode" in data:
                self.mode = data["mode"]
                self.event("mode-changed", mode=self.mode)
            if data.get("release_receipt"):
                self.receipt_visible = True
                self.event("receipt-released")
            # Preserve generation, receipts and all counts when selecting the next fault.
            return 200, dict(ok=True, mode=self.mode, db=self.db, receipt_visible=self.receipt_visible)

    def summary(self):
        with self.lock:
            return dict(
                synthetic=True, mode=self.mode, db=self.db, pid=os.getpid(),
                post_attempts=self.posts, dispatches=self.dispatches,
                dropped_responses=self.dropped_responses, state_reads=self.state_reads,
                receipt_exposures=self.receipt_exposures, refusals_422=self.refusals_422,
                receipts=0 if self.message is None else 1,
                receipt_visible=self.receipt_visible,
                requests=[dict(request_id=key, **value) for key, value in self.requests.items()],
            )

    def submit(self, data, client):
        request_id = data.get("request_id")
        text = data.get("text")
        try:
            if not isinstance(request_id, str) or str(uuid.UUID(request_id)) != request_id.lower():
                raise ValueError()
        except (ValueError, AttributeError):
            return 400, {"error": "request_id must be a UUID"}
        request_id = request_id.lower()
        if not isinstance(text, str) or not text.strip() or len(text) > 16_000:
            return 400, {"error": "text must contain 1 to 16000 characters"}
        if not client or len(client) > 128:
            return 400, {"error": "X-Fleet-Client is required (at most 128 characters)"}
        text = text.strip()
        with self.lock:
            self.posts += 1
            observed = self.requests.setdefault(request_id, {"posts": 0, "outcome": "refused"})
            observed["posts"] += 1
            if data.get("db") != self.db:
                self.event("refused", request_id=request_id, status=409)
                return 409, {"error": "synthetic database generation changed"}
            if self.mode == "reject-422":
                if CANARY not in text:
                    self.event("refused", request_id=request_id, status=400)
                    return 400, {"error": "Use the documented synthetic canary for this test"}
                self.refusals_422 += 1
                observed["outcome"] = "refused-422"
                self.event("refused", request_id=request_id, status=422)
                return 422, {"error": "a registered login cannot be sent as text"}

            # Retain only the single accepted synthetic message, needed for reconciliation.
            identity = hashlib.sha256(json.dumps([request_id, text, client]).encode()).digest()
            if self.message is not None and identity != self.identity:
                self.event("refused", request_id=request_id, status=409)
                return 409, {"error": "This harness accepts only one unique goal per process"}
            if self.message is None:
                self.identity = identity
                self.message = dict(request_id=request_id, kind="message", need_id=None, text=text,
                                    event_id=1, created=time.time(), read_at=None, client=client)
                self.dispatches += 1
            observed["outcome"] = "accepted-response-dropped"
            self.dropped_responses += 1
            self.event("accepted-response-dropped", request_id=request_id,
                       dispatches=self.dispatches, posts=observed["posts"])
            # All matching POST responses are dropped, so a transport retry cannot mask the fault.
            return None, None


class FaultHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def log_message(self, *_):
        pass  # Default request logging can include arbitrary input in a URL.

    def json_response(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def allowed(self):
        port = self.server.server_port
        if self.headers.get("Host") not in (f"127.0.0.1:{port}", f"localhost:{port}"):
            self.json_response(403, {"error": "loopback host required"})
            return False
        if self.headers.get("Origin"):
            self.json_response(403, {"error": "browser origins are not accepted"})
            return False
        return True

    def do_GET(self):
        if not self.allowed():
            return
        if self.path == "/ui/state":
            self.json_response(200, self.server.state.snapshot())
        elif self.path == "/test/summary":
            self.json_response(200, self.server.state.summary())
        else:
            self.json_response(404, {"error": "test route not found"})

    def do_POST(self):
        if not self.allowed():
            return
        if self.path not in ("/ui/messages", "/control"):
            return self.json_response(404, {"error": "test route not found"})
        if self.path == "/control" and self.headers.get("X-Fleet-Harness-Control") != "test-only":
            return self.json_response(403, {"error": "terminal control header required"})
        if self.headers.get("Content-Type", "").split(";", 1)[0].strip() != "application/json":
            return self.json_response(415, {"error": "application/json required"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 65536:
                return self.json_response(413, {"error": "invalid body size"})
            data = json.loads(self.rfile.read(length))
            if not isinstance(data, dict):
                raise ValueError()
        except (ValueError, UnicodeDecodeError, TimeoutError):
            return self.json_response(400, {"error": "invalid JSON request"})
        if self.path == "/control":
            status, body = self.server.state.control(data)
        else:
            status, body = self.server.state.submit(data, self.headers.get("X-Fleet-Client", ""))
        if status is None:
            self.close_connection = True
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.connection.close()
        else:
            self.json_response(status, body)


class FaultServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, mode, port=0, log=None, hold_receipt=False):
        self.state = FaultState(mode, sys.stdout if log is None else log, hold_receipt)
        super().__init__(("127.0.0.1", port), FaultHandler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=MODES, required=True)
    parser.add_argument("--port", type=int, default=0, help="Default: choose an unused loopback port")
    parser.add_argument("--hold-receipt", action="store_true", help="Hide receipt until terminal control release")
    args = parser.parse_args()

    def stop(_signal, _frame):
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, stop)
    with FaultServer(args.mode, args.port, hold_receipt=args.hold_receipt) as server:
        port = server.server_port
        server.state.event("started", mode=args.mode, pid=os.getpid(), db=server.state.db,
                           app_url=f"http://localhost:{port}",
                           summary_url=f"http://127.0.0.1:{port}/test/summary",
                           receipt_visible=server.state.receipt_visible)
        try:
            server.serve_forever(poll_interval=0.1)
        except KeyboardInterrupt:
            server.state.event("stopped", **server.state.summary())


if __name__ == "__main__":
    main()
