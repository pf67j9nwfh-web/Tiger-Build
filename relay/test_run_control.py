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
                              {"name": "take_screenshot", "inputSchema": {"type": "object"}},
                              {"name": "git_read", "inputSchema": {"type": "object"}}]}
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


class ChangeStatsTests(unittest.TestCase):
    def test_git_diff(self):
        out = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1,2 @@\n-old\n+new\n+more\ndiff --git a/y b/y\n--- a/y\n+++ b/y\n@@ -1 +1 @@\n-a\n+b\n"
        self.assertEqual(C.change_stats("git_read", out), (2, 3, 2))

    def test_svn_diff_and_commit_line_and_nothing(self):
        out = "Index: a.txt\n===\n--- a.txt\t(revision 1)\n+++ a.txt\t(working copy)\n@@ -1 +1,2 @@\n hello\n+world\n"
        self.assertEqual(C.change_stats("svn_read", out), (1, 1, 0))
        self.assertEqual(C.change_stats("git_write", "[main abc] fix\n 3 files changed, 12 insertions(+), 4 deletions(-)\n"), (3, 12, 4))
        self.assertEqual(C.change_stats("git_write", " 1 file changed, 1 insertion(+)\n"), (1, 1, 0))
        self.assertIsNone(C.change_stats("git_read", "On branch main\nnothing to commit"))
        self.assertIsNone(C.change_stats("start_process", "diff --git a b\n+x"))


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

    def test_read_only_repo_tools_never_ask(self):
        session = self.session(approve={"commander": True})
        asked = []
        gen = session.iter_turn([{"role": "user", "content": "go"}], True, "claude", "m")
        with patch.object(C, "stream_round", script_stream([{"calls": [call("git_read", args=["status"])]}, {"text": ["ok"]}])):
            for kind, text in gen:
                if kind == "q":
                    asked.append(text)
                    session.run.answer(plistlib.loads(text.encode())["id"], "deny")
        self.assertEqual(asked, [])
        self.assertEqual(len([c for c in FakeClient.calls if c[0] == "tools/call" and c[1]["name"] == "git_read"]), 1)

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
        self.assertEqual([n for n in tools_seen[0] if not n.startswith("agent_")], [])

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

    def test_attached_pictures_reach_vision_models_only(self):
        pictures = [{"mime": "image/png", "data": "QUJD"}]
        for provider, model, shown in (("claude", "claude-haiku-4-5-20251001", True), ("mistral", "codestral-latest", False)):
            session = self.session()
            logs = []

            def fake(provider, system, log, tools, holder, ctx, err, model=None, **kw):
                logs.append([dict(m) for m in log])
                yield "x"
            with patch.object(C, "stream_round", fake):
                list(session.iter_turn([{"role": "user", "content": "what is this?", "images": pictures}], False, provider, model))
            first = logs[0][0]
            self.assertEqual(bool(first.get("images")), shown)
            if not shown:
                self.assertIn("cannot view pictures", first["content"])

    def test_picture_field_is_validated(self):
        clean = C.Handler._clean_pictures if hasattr(C, "Handler") else None
        if clean is None:
            return
        self.assertEqual(clean([{"mime": "text/html", "data": "QUJD"}, {"mime": "image/png", "data": ""}, "x"]), [])
        self.assertEqual(clean([{"mime": "image/gif", "data": "QUJD"}]), [{"mime": "image/gif", "data": "QUJD"}])

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

    def test_tunnelled_client_is_recognised_only_from_this_computer(self):
        C.ALLOWED = {"127.0.0.1", "10.9.9.9", "10.9.9.10"}
        class Fake(C.Handler):
            def __init__(self, address, claimed):
                self.client_address = (address, 1)
                self.headers = {"X-TigerBuild-Client": claimed} if claimed else {}
                self.server = type("S", (), {"server_address": ("10.0.1.105", 8765)})()
            def _x(self):
                return self._caller_address()
        self.assertEqual(Fake("127.0.0.1", "10.9.9.10, 10.9.9.9")._x(), "10.9.9.10")
        self.assertEqual(Fake("10.0.1.105", "10.9.9.9")._x(), "10.9.9.9")
        self.assertEqual(Fake("127.0.0.1", "10.7.7.7")._x(), "127.0.0.1")       # not an allowed client
        self.assertEqual(Fake("10.9.9.10", "10.9.9.9")._x(), "10.9.9.10")       # a remote Mac cannot pretend
        self.assertEqual(Fake("127.0.0.1", None)._x(), "127.0.0.1")

    def test_transcribe_route(self):
        def post(body, token="tok"):
            conn = self.http.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=20)
            conn.request("POST", "/v1/transcribe", body, {"X-TigerBuild-Token": token, "Content-Type": "audio/wav"})
            response = conn.getresponse()
            return response.status, response.read(), response.getheader("X-Transcribed-By")
        import transcribe
        wav = b"RIFF" + b"\x24\x00\x00\x00" + b"WAVE" + b"\0" * 200
        with patch.object(transcribe, "transcribe", lambda data, ctx, language="": ("hello world", "OpenAI")):
            status, data, who = post(wav)
        self.assertEqual((status, data, who), (200, b"hello world", "OpenAI"))
        self.assertEqual(post(b"short")[0], 422)
        self.assertEqual(post(wav, token="wrong")[0], 401)
        with patch.object(transcribe, "transcribe", lambda data, ctx, language="": (_ for _ in ()).throw(transcribe.NoService("no key"))):
            self.assertEqual(post(wav)[0], 424)

    def test_version_route(self):
        from version import VERSION
        status, data = self.call("GET", "/v1/version")
        self.assertEqual((status, data.decode().strip()), (200, VERSION))

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

    def test_extract_route(self):
        import io, zipfile, urllib.parse
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as zf:
            zf.writestr("word/document.xml", '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Hello from Word</w:t></w:r></w:p></w:body></w:document>')
        def post(name, body, token="tok"):
            conn = self.http.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=20)
            conn.request("POST", "/v1/extract", body, {"X-TigerBuild-Token": token, "X-Filename": urllib.parse.quote(name),
                                                        "Content-Type": "application/octet-stream"})
            response = conn.getresponse()
            return response.status, response.read()
        status, data = post("My File.docx", buffer.getvalue())
        self.assertEqual(status, 200)
        self.assertEqual(plistlib.loads(data)["text"], "Hello from Word")
        self.assertEqual(post("x.docx", b"not a zip")[0], 422)
        self.assertEqual(post("x.exe", b"abc")[0], 422)
        self.assertEqual(post("x.docx", buffer.getvalue(), token="wrong")[0], 401)

    def test_auth_required(self):
        conn = self.http.HTTPConnection("127.0.0.1", self.server.server_address[1], timeout=10)
        conn.request("GET", "/v1/tools")
        self.assertEqual(conn.getresponse().status, 401)


class ControlCharTests(unittest.TestCase):
    """Terminal output is full of control characters; none may break a turn."""

    def test_activity_card_survives_escape_codes(self):
        session = C.ToolSession(runs.Run("cc"), C.clean_options({}))
        event = session._tool_event({"id": "1", "name": "start_process", "arguments": json.dumps({"command": "ls\x1b[1m"})},
                                    "result", "\x1b[31mred\x1b[0m\x08\x00 text\r\nmore\x1b]0;title\x07", False, 0.5)
        card = plistlib.loads(event.encode())
        self.assertEqual(card["output"].replace("\r", ""), "red�� text\nmore")
        self.assertNotIn("\x1b", card["detail"])

    def test_approval_question_survives_control_characters(self):
        session = C.ToolSession(runs.Run("cc2"), C.clean_options({"approve": {"all": True}}))
        gen = session._gate({"id": "c1", "name": "start_process", "arguments": json.dumps({"command": "echo \x07\x1b[0m hi"})})
        kind, text = next(gen)
        self.assertEqual(kind, "q")
        self.assertIn("hi", plistlib.loads(text.encode())["detail"])
        session.run.cancel()

    def test_tool_step_limit_is_a_setting(self):
        session = C.ToolSession(runs.Run("cc3"), C.clean_options({}))
        session.extra.config = dict(session.extra.config, max_tool_steps=5)
        self.assertEqual(session.max_steps(), 5)
        session.extra.config = dict(session.extra.config, max_tool_steps="junk")
        self.assertEqual(session.max_steps(), C.MAX_TOOL_ROUNDS)
        session.extra.config = dict(session.extra.config, max_tool_steps=9999)
        self.assertEqual(session.max_steps(), 200)

    def test_step_limit_stops_the_loop_and_says_so(self):
        # Reuses the fake model/commander from TurnTests.
        case = TurnTests("test_usage_frame_has_cost")
        case.setUp()
        try:
            session = case.session()
            session.extra.config = dict(session.extra.config, max_tool_steps=3)
            rounds = [{"calls": [call("start_process", command="echo %d" % i)]} for i in range(10)]
            frames = case.frames(session, rounds)
            ran = [c for c in FakeClient.calls if c[0] == "tools/call"]
            self.assertEqual(len(ran), 3)
            self.assertIn("Stopped after 3 tool steps", "".join(t for k, t in frames if k == "t"))
        finally:
            for item in case.patches:
                item.stop()


class ConcurrencyTests(unittest.TestCase):
    def test_runs_with_different_ids_do_not_touch_each_other(self):
        a, b = runs.start("conc-a-0001"), runs.start("conc-b-0001")
        a.add_guidance("only a")
        b.cancel()
        self.assertTrue(b.cancelled.is_set())
        self.assertFalse(a.cancelled.is_set())
        self.assertEqual(b.take_guidance(), [])
        self.assertEqual(a.take_guidance(), ["only a"])
        runs.finish(a)
        runs.finish(b)

    def test_start_gate_limits_simultaneous_logins_per_mac(self):
        peak = {"now": 0, "max": 0}
        lock = threading.Lock()

        class Slow(FakeClient):
            def start(self):
                with lock:
                    peak["now"] += 1
                    peak["max"] = max(peak["max"], peak["now"])
                import time
                time.sleep(0.15)
                with lock:
                    peak["now"] -= 1

        with patch.object(C, "McpClient", Slow):
            threads = [threading.Thread(target=C.start_commander, args=({"TIGER_HOST": "gate-host", "TIGER_USER": "u",
                       "TIGER_KEY": "k", "TIGER_KNOWN": "n", "REMOTE_COMMANDER": "x"},)) for _ in range(9)]
            [t.start() for t in threads]
            [t.join() for t in threads]
        self.assertLessEqual(peak["max"], C.START_GATE)
        self.assertGreater(peak["max"], 1)

    def test_one_tool_lookup_for_a_crowd(self):
        starts = []

        class Counting(FakeClient):
            def start(self):
                starts.append(1)
                import time
                time.sleep(0.2)

        config = {"TIGER_HOST": "crowd-host", "TIGER_USER": "u", "TIGER_KEY": "k", "TIGER_KNOWN": "n", "REMOTE_COMMANDER": "x"}
        C.invalidate_tools()
        results = []

        def one():
            session = C.ToolSession(runs.Run("crowd"), C.clean_options({}))
            session.config = config
            session.linked = True
            results.append(len(session.definitions()))

        with patch.object(C, "McpClient", Counting):
            threads = [threading.Thread(target=one) for _ in range(8)]
            [t.start() for t in threads]
            [t.join() for t in threads]
        self.assertEqual(len(starts), 1)
        self.assertEqual(results, [3] * 8)
        C.invalidate_tools()


if __name__ == "__main__":
    unittest.main()
