import http.client
import io
import json
import threading
import unittest
import uuid

from fault_hub import CANARY, FaultServer


class FaultHarnessTests(unittest.TestCase):
    def setUp(self):
        self.logs = io.StringIO()
        self.server = FaultServer("lost-response", log=self.logs)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01})
        self.thread.start()
        self.client = "founderizer-swift/1/" + str(uuid.uuid4())

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def request(self, method, path, data=None, extra_headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=2)
        headers = {"Content-Type": "application/json", "X-Fleet-Client": self.client}
        headers.update(extra_headers or {})
        try:
            connection.request(method, path, None if data is None else json.dumps(data), headers)
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def goal(self, text="SYNTHETIC lost-response test"):
        return {"request_id": str(uuid.uuid4()), "db": self.server.state.db, "text": text}

    def drop(self, goal):
        with self.assertRaises(http.client.RemoteDisconnected):
            self.request("POST", "/ui/messages", goal)

    def summary(self):
        status, result = self.request("GET", "/test/summary")
        self.assertEqual(status, 200)
        return result

    def test_accept_then_drop_response_next_get_has_exact_receipt(self):
        goal = self.goal()
        self.drop(goal)
        status, state = self.request("GET", "/ui/state")
        self.assertEqual(status, 200)
        self.assertEqual(state["schema_version"], 1)
        self.assertEqual(state["db"], goal["db"])
        self.assertEqual(state["tasks"], [])
        self.assertEqual(state["reports"], [])
        self.assertEqual(state["needs"][0]["id"], 900001)
        self.assertIsNone(state["needs"][0]["answered"])
        self.assertEqual(state["messages"][0]["request_id"], goal["request_id"])
        self.assertEqual(state["messages"][0]["text"], goal["text"])
        self.assertEqual(state["messages"][0]["client"], self.client)
        self.assertIsNone(state["messages"][0]["read_at"])
        summary = self.summary()
        self.assertEqual(summary["dispatches"], 1)
        self.assertEqual(summary["dropped_responses"], 1)
        self.assertEqual(summary["receipt_exposures"], 1)
        self.assertNotIn(goal["text"], self.logs.getvalue())
        self.assertNotIn(goal["text"], json.dumps(summary))

    def test_duplicate_post_keeps_one_dispatch_and_still_drops_response(self):
        goal = self.goal()
        self.drop(goal)
        self.drop(goal)
        summary = self.summary()
        self.assertEqual(summary["dispatches"], 1)
        self.assertEqual(summary["post_attempts"], 2)
        self.assertEqual(summary["dropped_responses"], 2)
        self.assertEqual(len(summary["requests"]), 1)

    def test_second_goal_changed_body_and_client_cannot_dispatch(self):
        goal = self.goal()
        self.drop(goal)
        changed = dict(goal, text="Different synthetic text")
        self.assertEqual(self.request("POST", "/ui/messages", changed)[0], 409)
        self.assertEqual(self.request("POST", "/ui/messages", goal, {"X-Fleet-Client": "other"})[0], 409)
        self.assertEqual(self.request("POST", "/ui/messages", self.goal())[0], 409)
        self.assertEqual(self.summary()["dispatches"], 1)

    def test_stale_database_is_refused_without_dispatch(self):
        goal = dict(self.goal(), db="a-different-generation")
        self.assertEqual(self.request("POST", "/ui/messages", goal)[0], 409)
        self.assertEqual(self.summary()["dispatches"], 0)

    def test_422_has_no_receipt_dispatch_or_canary_in_logs_or_summary(self):
        self.server.state.mode = "reject-422"
        goal = self.goal("Synthetic canary: " + CANARY)
        self.assertEqual(self.request("POST", "/ui/messages", goal)[0], 422)
        summary = self.summary()
        self.assertEqual(summary["dispatches"], 0)
        self.assertEqual(summary["receipts"], 0)
        self.assertEqual(summary["refusals_422"], 1)
        self.assertEqual(self.request("GET", "/ui/state")[1]["messages"], [])
        self.assertNotIn(CANARY, self.logs.getvalue())
        self.assertNotIn(CANARY, json.dumps(summary))

    def test_422_mode_does_not_accept_unrelated_text(self):
        self.server.state.mode = "reject-422"
        self.assertEqual(self.request("POST", "/ui/messages", self.goal())[0], 400)
        self.assertEqual(self.summary()["dispatches"], 0)

    def test_browser_wrong_host_and_worker_routes_are_refused(self):
        goal = self.goal()
        self.assertEqual(self.request("POST", "/ui/messages", goal, {"Origin": "https://example.com"})[0], 403)
        self.assertEqual(self.request("POST", "/ui/messages", goal, {"Host": "example.com"})[0], 403)
        self.assertEqual(self.request("GET", "/events/manager")[0], 404)
        self.assertEqual(self.request("POST", "/say", goal)[0], 404)
        self.assertEqual(self.summary()["dispatches"], 0)

    def test_binds_only_ipv4_loopback_and_generations_are_unique(self):
        self.assertEqual(self.server.server_address[0], "127.0.0.1")
        with FaultServer("lost-response", log=io.StringIO()) as other:
            self.assertNotEqual(self.server.state.db, other.state.db)

    def test_control_changes_fault_without_resetting_identity_or_counts(self):
        goal = self.goal()
        self.drop(goal)
        self.assertEqual(self.request("POST", "/control", {"mode": "reject-422"})[0], 403)
        status, control = self.request("POST", "/control", {"mode": "reject-422"},
                                       {"X-Fleet-Harness-Control": "test-only"})
        self.assertEqual(status, 200)
        self.assertEqual(control["db"], goal["db"])
        self.assertEqual(self.request("POST", "/ui/messages", self.goal(CANARY))[0], 422)
        summary = self.summary()
        self.assertEqual(summary["dispatches"], 1)
        self.assertEqual(summary["receipts"], 1)
        self.assertEqual(summary["refusals_422"], 1)
        self.assertEqual(len(summary["requests"]), 2)
        self.assertNotIn(CANARY, self.logs.getvalue())

    def test_held_receipt_survives_repeated_reads_until_explicit_release(self):
        self.server.state.receipt_visible = False
        goal = self.goal()
        self.drop(goal)
        for _ in range(3):
            self.assertEqual(self.request("GET", "/ui/state")[1]["messages"], [])
        before = self.summary()
        self.assertEqual(before["dispatches"], 1)
        self.assertEqual(before["receipts"], 1)
        self.assertEqual(before["receipt_exposures"], 0)
        status, _ = self.request("POST", "/control", {"release_receipt": True},
                                 {"X-Fleet-Harness-Control": "test-only"})
        self.assertEqual(status, 200)
        messages = self.request("GET", "/ui/state")[1]["messages"]
        self.assertEqual(messages[0]["request_id"], goal["request_id"])
        self.assertEqual(self.summary()["dispatches"], 1)
        self.assertEqual(self.summary()["post_attempts"], 1)


if __name__ == "__main__":
    unittest.main()
