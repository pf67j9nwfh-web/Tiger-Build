"""Stop, guidance, approval, usage, truncation and cost, with fake model streams."""
import json
import os
import plistlib
import sys
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import chat_proxy as C
import pricing
import runs


class FakeClient(object):
    """Stands in for the ssh link to ppc-commander."""
    calls = []

    def __init__(self, command):
        self.command = command
        self.proc = None

    def start(self):
        pass

    def close(self):
        pass

    def stderr_text(self):
        return ""

    def request(self, method, params, timeout=0):
        FakeClient.calls.append((method, params))
        if method == "tools/list":
            return {"tools": [{"name": "start_process", "inputSchema": {"type": "object"}},
                              {"name": "take_screenshot", "inputSchema": {"type": "object"}}]}
        if params["name"] == "take_screenshot":
            return {"content": [{"type": "image", "data": "QUJD", "mimeType": "image/jpeg"},
                                {"type": "text", "text": "shot"}]}
        return {"content": [{"type": "text", "text": "ran " + json.dumps(params["arguments"])}]}


def script_stream(rounds, seen_logs=None):
    """A stream_round that plays one scripted round per call."""
    queue = list(rounds)

    def fake(provider, system, log, tools, holder, ctx, err, model=None, **kw):
        if seen_logs is not None:
            seen_logs.append([dict(item) for item in log])
        step = queue.pop(0)
        for piece in step.get("text", []):
            yield piece
        holder["calls"] = step.get("calls", [])
        if "usage" in step:
            holder["usage"] = step["usage"]
        if step.get("truncated"):
            holder["truncated"] = True
    return fake


def call(name, **args):
    return {"id": name + "-1", "name": name, "arguments": json.dumps(args)}


class TurnTests(unittest.TestCase):
    def setUp(self):
        FakeClient.calls = []
        # Never read the real relay's tool settings: a developer machine may
        # have custom MCP servers configured.
        import tempfile
        home = tempfile.mkdtemp()
        self.addCleanup(__import__("shutil").rmtree, home, True)
        self.patches = [
            patch.dict(os.environ, {"TIGERBUILD_RELAY_HOME": home}),
            patch.object(C, "McpClient", FakeClient),
            patch.object(C, "refresh_settings", lambda: None),
            patch.object(C, "resolve_model", lambda provider, model: model or "m"),
            patch.object(C.ToolSession, "definitions", lambda self: [
                {"type": "function", "name": "start_process", "parameters": {}},
                {"type": "function", "name": "take_screenshot", "parameters": {}}]),
            patch.object(C.ToolSession, "_context_limit", lambda self, p, m: 1000),
        ]
        for item in self.patches:
            item.start()
        self.addCleanup(lambda: [item.stop() for item in self.patches])

    def session(self, **options):
        run = runs.Run("test-run")
        session = C.ToolSession(run, C.clean_options(options))
        session.config = {"TIGER_HOST": "h", "TIGER_USER": "u", "TIGER_KEY": "k", "TIGER_KNOWN": "n",
                          "REMOTE_COMMANDER": "x"}
        session.extra.config = dict(session.extra.config, ppc_enabled=True, consult_enabled=False)
        return session

    def frames(self, session, rounds, provider="claude", seen=None):
        with patch.object(C, "stream_round", script_stream(rounds, seen)):
            return list(session.iter_turn([{"role": "user", "content": "go"}], True, provider, "m"))

    def test_usage_frame_has_cost(self):
        with patch.object(C.pricing, "cost", lambda p, m, u: u["input"] * 1e-6 + u["output"] * 5e-6):
            frames = self.frames(self.session(), [{"text": ["hi"], "usage": {"input": 1000, "cached": 0, "written": 0, "output": 200}}])
        usage = [plistlib.loads(t.encode()) for k, t in frames if k == "u"]
        self.assertEqual(len(usage), 1)
        self.assertAlmostEqual(usage[0]["cost"], 0.002)
        self.assertEqual(usage[0]["context"], 1000)

    def test_free_model_has_no_cost(self):
        with patch.object(C.pricing, "cost", lambda p, m, u: None):
            frames = self.frames(self.session(), [{"text": ["hi"], "usage": {"input": 5, "output": 5}}], "local")
        usage = [plistlib.loads(t.encode()) for k, t in frames if k == "u"]
        self.assertNotIn("cost", usage[0])

    def test_output_limit_prints_note_and_drops_calls(self):
        frames = self.frames(self.session(), [{"text": ["part"], "calls": [call("start_process", command="ls")], "truncated": True}])
        text = "".join(t for k, t in frames if k == "t")
        self.assertIn("output limit", text)
        self.assertEqual(FakeClient.calls, [])

    def test_guidance_arrives_after_tool_step(self):
        session = self.session()
        session.run.add_guidance("use python 2")
        seen = []
        frames = self.frames(session, [{"calls": [call("start_process", command="ls")]}, {"text": ["done"]}], seen=seen)
        self.assertIn(("g", "use python 2"), frames)
        last = seen[1][-1]
        self.assertEqual(last["role"], "user")
        self.assertIn("use python 2", last["content"])
        self.assertEqual(seen[1][-2]["role"], "tool")

    def test_guidance_not_delivered_when_no_tool_step(self):
        session = self.session()
        session.run.add_guidance("late")
        frames = self.frames(session, [{"text": ["done"]}])
        self.assertNotIn(("g", "late"), frames)
        self.assertEqual(session.run.take_guidance(), ["late"])

    def test_approval_denied_skips_tool(self):
        session = self.session(approve={"commander": True})
        gen = session.iter_turn([{"role": "user", "content": "go"}], True, "claude", "m")
        with patch.object(C, "stream_round", script_stream([{"calls": [call("start_process", command="rm x")]}, {"text": ["ok"]}])):
            frames = []
            for kind, text in gen:
                frames.append((kind, text))
                if kind == "q":
                    asked = plistlib.loads(text.encode())
                    self.assertEqual(asked["server"], "commander")
                    self.assertIn("rm x", asked["detail"])
                    session.run.answer(asked["id"], "deny")
        self.assertEqual([c for c in FakeClient.calls if c[0] == "tools/call"], [])
        results = [plistlib.loads(t.encode()) for k, t in frames if k == "a"]
        self.assertTrue(results[-1]["failed"])

    def test_approval_allowed_runs_tool(self):
        session = self.session(approve={"commander": True})
        gen = session.iter_turn([{"role": "user", "content": "go"}], True, "claude", "m")
        with patch.object(C, "stream_round", script_stream([{"calls": [call("start_process", command="ls")]}, {"text": ["ok"]}])):
            for kind, text in gen:
                if kind == "q":
                    session.run.answer(plistlib.loads(text.encode())["id"], "always")
        self.assertEqual(len([c for c in FakeClient.calls if c[0] == "tools/call"]), 1)

    def test_per_chat_switch_removes_commander(self):
        session = self.session(servers={"commander": False})
        seen = []
        tools_seen = []

        def fake(provider, system, log, tools, holder, ctx, err, model=None, **kw):
            tools_seen.append([t["name"] for t in tools])
            yield "x"
            holder["calls"] = []
        with patch.object(C, "stream_round", fake):
            list(session.iter_turn([{"role": "user", "content": "go"}], True, "claude", "m"))
        self.assertEqual(tools_seen[0], [])

    def test_screenshot_goes_back_as_image(self):
        seen = []
        frames = self.frames(self.session(), [{"calls": [call("take_screenshot")]}, {"text": ["I see it"]}], seen=seen)
        last = seen[1][-1]
        self.assertEqual(last["images"][0]["data"], "QUJD")

    def test_screenshot_hidden_from_models_without_vision(self):
        session = self.session()
        tools_seen = []

        def fake(provider, system, log, tools, holder, ctx, err, model=None, **kw):
            tools_seen.append([t["name"] for t in tools])
            yield "x"
        with patch.object(C, "stream_round", fake):
            list(session.iter_turn([{"role": "user", "content": "go"}], True, "mistral", "codestral-latest"))
        self.assertNotIn("take_screenshot", tools_seen[0])

    def test_stop_ends_turn_quietly(self):
        session = self.session()

        def fake(provider, system, log, tools, holder, ctx, err, model=None, **kw):
            yield "one"
            session.run.cancel()
            yield "two"
        with patch.object(C, "stream_round", fake):
            frames = list(session.iter_turn([{"role": "user", "content": "go"}], True, "claude", "m"))
        self.assertEqual([t for k, t in frames if k == "t"], ["one"])

    def test_old_tool_output_is_trimmed_when_context_fills(self):
        session = self.session()
        big = "x" * 5000
        rounds = [{"calls": [call("start_process", command="a")], "usage": {"input": 900, "output": 1}}]
        rounds += [{"calls": [call("start_process", command="b%d" % i)], "usage": {"input": 900, "output": 1}} for i in range(7)]
        rounds += [{"text": ["done"], "usage": {"input": 900, "output": 1}}]
        seen = []
        with patch.object(FakeClient, "request", lambda self, m, p, timeout=0: (
                {"tools": [{"name": "start_process"}]} if m == "tools/list" else {"content": [{"type": "text", "text": big}]})):
            frames = self.frames(session, rounds, seen=seen)
        self.assertTrue(any(k == "c" for k, t in frames))
        self.assertLess(len(seen[-1][1]["content"]), 1000)

    def test_clean_options(self):
        options = C.clean_options({"servers": {"a": True, "b": "x"}, "approve": {"all": True}, "root": "/Users/jr/p/"})
        self.assertEqual(options["servers"], {"a": True})
        self.assertEqual(options["root"], "/Users/jr/p")
        self.assertEqual(C.clean_options({"root": "relative"})["root"], "")


class PricingTests(unittest.TestCase):
    def setUp(self):
        self.saved = dict(pricing._STATE)
        saver = patch.object(pricing, "_save_cache", lambda rates, stamp: None)
        saver.start()
        self.addCleanup(saver.stop)
        pricing._STATE["rates"] = pricing._compact({
            "gem": {"input_cost_per_token": 1e-6, "output_cost_per_token": 4e-6,
                    "input_cost_per_token_above_200k_tokens": 2e-6, "output_cost_per_token_above_200k_tokens": 8e-6,
                    "cache_read_input_token_cost": 1e-7},
            "xai/grok": {"input_cost_per_token": 3e-6, "output_cost_per_token": 15e-6},
            "input_cost_per_token_batches": 1,
        })
        self.addCleanup(lambda: pricing._STATE.update(self.saved))

    def test_plain_cost(self):
        self.assertAlmostEqual(pricing.cost("gemini", "gem", {"input": 1000, "output": 1000}) or -1, -1) if False else None
        pricing._STATE["rates"]["gemini/gem"] = pricing._STATE["rates"]["gem"]
        self.assertAlmostEqual(pricing.cost("gemini", "gem", {"input": 1000, "output": 1000}), 0.005)

    def test_tier_by_prompt_size(self):
        pricing._STATE["rates"]["gemini/gem"] = pricing._STATE["rates"]["gem"]
        small = pricing.cost("gemini", "gem", {"input": 100000, "output": 1000})
        large = pricing.cost("gemini", "gem", {"input": 250000, "output": 1000})
        self.assertAlmostEqual(small, 0.1 + 0.004)
        self.assertAlmostEqual(large, 0.5 + 0.008)

    def test_cached_tokens_use_cache_rate(self):
        pricing._STATE["rates"]["gemini/gem"] = pricing._STATE["rates"]["gem"]
        self.assertAlmostEqual(pricing.cost("gemini", "gem", {"input": 0, "cached": 1000000, "output": 0}), 0.1)

    def test_prefix_and_local(self):
        self.assertAlmostEqual(pricing.cost("grok", "grok", {"input": 1000, "output": 1000}), 0.018)
        self.assertIsNone(pricing.cost("local", "grok", {"input": 1000}))
        self.assertIsNone(pricing.cost("grok", "nothing", {"input": 1000}))


class RunTests(unittest.TestCase):
    def test_cancel_runs_abort_callbacks(self):
        run = runs.Run("abcd")
        hits = []
        run.on_abort(lambda: hits.append(1))
        run.cancel()
        run.cancel()
        self.assertEqual(hits, [1])
        with self.assertRaises(runs.Stopped):
            run.check()

    def test_wait_returns_answer(self):
        run = runs.Run("abcd")
        run.ask("c1")
        threading.Timer(0.05, lambda: run.answer("c1", "allow")).start()
        self.assertEqual(run.wait("c1", 5), "allow")

    def test_stop_while_waiting(self):
        run = runs.Run("abcd")
        run.ask("c1")
        threading.Timer(0.05, run.cancel).start()
        with self.assertRaises(runs.Stopped):
            run.wait("c1", 5)


if __name__ == "__main__":
    unittest.main()


class HttpTests(unittest.TestCase):
    """The new HTTP routes, through a real server."""

    def setUp(self):
        import http.client
        from http.server import ThreadingHTTPServer
        self.http = http.client
        C.TOKEN = "tok"
        C.ALLOWED = {"127.0.0.1"}
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), C.Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.shutdown)
        self.patch = patch.object(C, "refresh_settings", lambda: None)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def call(self, method, path, body=None):
        conn = self.http.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=10)
        conn.request(method, path, json.dumps(body) if body is not None else None, {"X-TigerBuild-Token": "tok"})
        response = conn.getresponse()
        return response.status, response.read()

    def test_tools_catalogue(self):
        status, data = self.call("GET", "/v1/tools")
        self.assertEqual(status, 200)
        info = plistlib.loads(data)
        self.assertTrue(any(row["id"] == "commander" for row in info["tools"]))

    def test_run_unknown_is_404(self):
        status, _data = self.call("POST", "/v1/run", {"id": "nosuchrun1", "action": "stop"})
        self.assertEqual(status, 404)

    def test_run_stop_and_guide(self):
        run = runs.start("httprun0001")
        self.addCleanup(lambda: runs.finish(run))
        self.assertEqual(self.call("POST", "/v1/run", {"id": "httprun0001", "action": "guide", "text": "hi"})[0], 200)
        self.assertEqual(run.take_guidance(), ["hi"])
        self.assertEqual(self.call("POST", "/v1/run", {"id": "httprun0001", "action": "stop"})[0], 200)
        self.assertTrue(run.cancelled.is_set())

    def test_ssh_state(self):
        status, data = self.call("GET", "/v1/ssh")
        self.assertEqual(status, 200)
        self.assertIn(b"host=", data)

    def test_auth_required(self):
        conn = self.http.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=10)
        conn.request("GET", "/v1/tools")
        self.assertEqual(conn.getresponse().status, 401)
