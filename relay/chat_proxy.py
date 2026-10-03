#!/usr/bin/env python3
"""LAN relay for Tiger Build.

Mac OS X Tiger cannot speak modern HTTPS. This process accepts plain HTTP from
Tiger Build, calls the model APIs, and, when the model asks, runs
ppc-commander tools on that Mac over SSH.
"""

import json
import os
import re
import socket
import ssl
import sys
import threading
import plistlib
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from app_config import cached_local_models
from app_config import clean_title
from app_config import context_for
from app_config import ensure_config_file
from app_config import local_models_text
from app_config import settings_public
from app_config import update_settings
from security import TOKEN_HEADER
from security import allowed_clients
from security import client_allowed
from security import listen_address
from security import relay_token
from security import token_ok
from security import token_path
from version import VERSION
from integrations import fetch_image, save_output_file
from media import create_media
from media import media_dir
from media import media_tools
from media import safe_name
from providers import AnswerStream
from providers import ensure_user_first
from providers import qwen_tool_calls
from providers import gemini_contents
from providers import normalize as normalize_provider
from providers import resolve_model
from providers import stream_round
from providers import set_live
from discovery import Discovery
from discovery import pretty_title
from discovery import _transient as transient_error
from integrations import Connections, read as integrations_config
from security import support_dir
from providers import CATALOG
from mcp_bridge import (
    McpClient,
    McpError,
    load_shell_config,
    result_images,
    result_text,
    ssh_command,
    tool_summary,
    xai_tools_from_mcp,
)
import connection
import pricing
import runs
from discovery import has_key as disc_has_key
from integrations import function as function_tool
from providers import PROVIDERS as CATALOG_PROVIDERS
from providers import _openai_usage, openai_responses_input

MODEL = "grok-4.7"
API_URL = "https://api.x.ai/v1/responses"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SYSTEM = (
    "You are an assistant chatting inside Tiger Build on {machine} running "
    "{os}. You have ppc-commander tools that read files, "
    "edit files, and run shell commands on that Mac. Use them when "
    "the person asks about that computer or wants something done there. "
    "Do not use them for ordinary questions. "
    "Finish the task in this turn. Do not stop halfway, and do not ask the "
    "person to type continue, even if an earlier message did. Write a whole file in one call, then compile "
    "or test. Use timeout_ms of 15000, or 20000 for a compile. "
    "You may launch GUI applications when the person asks. For a GUI, or anything "
    "that should keep running, call start_process with detach set to true so it "
    "is not tied to this chat. Use open for a Mac .app. "
    "The shell is bash and the system Python is 2.3. "
    "After the tools finish, answer in a few plain sentences."
)
MAX_TOOL_ROUNDS = 40  # the default; "max_tool_steps" in the tool settings changes it


ENV_PATH = os.path.join(ROOT, ".env")
TOKEN = ""
ALLOWED = set()


def show_thinking_on():
    from providers import show_thinking
    return show_thinking()


def reload_allowed(config=None):
    """The addresses that may connect, after the Tiger Mac's address changed."""
    config = config or load_shell_config()
    allowed = allowed_clients(config)
    if "private" not in allowed and not (config.get("ALLOWED_CLIENTS") or "").strip():
        # Computers that have connected for Commander may keep using the relay.
        allowed.update(connection.load_clients().keys())
    address = listen_address(config)
    if address not in ("0.0.0.0", "::"):
        allowed.add(address)
    return allowed


def refresh_settings():
    """Pick up edits to .env or providers.json. Runs at the start of each request."""
    return ensure_config_file(ENV_PATH)


def load_key():
    return os.environ.get("XAI_API_KEY", "").strip()


def ssl_context():
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        cafile = "/etc/ssl/cert.pem"
        if os.path.isfile(cafile):
            return ssl.create_default_context(cafile=cafile)
        return ssl.create_default_context()


def extract_text(data):
    if isinstance(data.get("output_text"), str) and data["output_text"].strip():
        return data["output_text"].strip()
    parts = []
    for item in data.get("output") or []:
        if not isinstance(item, dict):
            continue
        if item.get("type") not in (None, "message"):
            continue
        content = item.get("content")
        if isinstance(content, str):
            parts.append(content)
        elif isinstance(content, list):
            for piece in content:
                if isinstance(piece, dict) and piece.get("text"):
                    parts.append(piece["text"])
                elif isinstance(piece, str):
                    parts.append(piece)
    text = "\n".join(parts).strip()
    if text:
        return text
    error = data.get("error")
    if isinstance(error, dict) and error.get("message"):
        raise RuntimeError(error["message"])
    if isinstance(error, str) and error:
        raise RuntimeError(error)
    return ""


def function_calls(data):
    calls = []
    for item in data.get("output") or []:
        if isinstance(item, dict) and item.get("type") == "function_call":
            calls.append(item)
    return calls


def api_error_text(detail, code):
    try:
        parsed = json.loads(detail)
    except ValueError:
        parsed = None
    if isinstance(parsed, dict):
        err = parsed.get("error")
        if isinstance(err, dict) and err.get("message"):
            detail = err["message"]
        elif isinstance(err, str):
            detail = err
    text = "The model service returned %s: %s" % (code, detail[:800])
    if "anthropic-workspace-id" in detail:
        text += (" Your Anthropic key needs its workspace ID: add it in Tiger Build "
                 "Preferences under Workspace ID (optional).")
    return text


# Which providers a saved setting affects, so their model checks start over.
SETTING_PROVIDERS = {
    "xai_api_key": ("grok",),
    "openai_api_key": ("chatgpt",),
    "anthropic_api_key": ("claude",),
    "anthropic_workspace_id": ("claude",),
    "mistral_api_key": ("mistral",),
    "muse_api_key": ("muse",),
    "gemini_api_key": ("gemini",),
}


def event_error_message(event):
    err = None
    if isinstance(event, dict):
        err = event.get("error")
        response = event.get("response")
        if err is None and isinstance(response, dict):
            err = response.get("error")
    if isinstance(err, dict) and err.get("message"):
        return err["message"]
    if isinstance(err, str) and err:
        return err
    return "The model failed."


def text_delta(event):
    if not isinstance(event, dict) or event.get("type") != "response.output_text.delta":
        return ""
    delta = event.get("delta") or ""
    if not isinstance(delta, str):
        return ""
    return delta


def events_from_lines(lines):
    for raw in lines:
        if isinstance(raw, bytes):
            raw = raw.decode("utf-8", "replace")
        line = raw.strip()
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if data == "[DONE]":
            break
        if not data:
            continue
        yield json.loads(data)


def open_stream(payload, run=None):
    key = load_key()
    if not key:
        raise RuntimeError(
            "XAI_API_KEY is not set. Add it in Tiger Build Preferences or the relay .env."
        )
    body_payload = dict(payload)
    body_payload["stream"] = True
    body = json.dumps(body_payload).encode("utf-8")
    request = urllib.request.Request(
        API_URL,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer " + key,
            "User-Agent": "TigerBuild-relay/%s" % VERSION,
        },
        method="POST",
    )
    try:
        response = urllib.request.urlopen(request, timeout=180, context=ssl_context())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        raise RuntimeError(api_error_text(detail, exc.code))
    if run is not None:
        run.on_abort(response.close)
    return response


def iter_response_events(payload, run=None):
    response = open_stream(payload, run)
    try:
        while True:
            raw = response.readline()
            if not raw:
                break
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            if not data:
                continue
            yield json.loads(data)
    finally:
        if run is not None:
            run.off_abort(response.close)
        response.close()


PROBE_SYSTEM = "This is a connection check. Reply with the single word ok."
PROBE_TOOL = {
    "type": "function",
    "name": "ping",
    "description": "Connection check. Do not call it.",
    "parameters": {
        "type": "object",
        "properties": {"word": {"type": "string", "description": "Any word."}},
    },
}
DISCOVERY = None


def probe_model(provider, model, endpoint=None):
    """Raise unless this model streams a reply to a request that includes a
    tool, through the same code a Tiger Build chat uses. The stream is closed
    as soon as the model starts answering, so a check costs a few tokens."""
    log = [{"role": "user", "content": "ping"}]
    if provider == "grok":
        payload = {
            "model": model,
            "store": False,
            "input": [{"role": "system", "content": PROBE_SYSTEM}] + log,
            "tools": [PROBE_TOOL],
            "tool_choice": "auto",
        }
        events = iter_response_events(payload)
        try:
            for event in events:
                etype = event.get("type") if isinstance(event, dict) else ""
                if etype in ("error", "response.failed", "response.error"):
                    raise RuntimeError(event_error_message(event))
                item = event.get("item") if isinstance(event, dict) else None
                if text_delta(event) or etype == "response.completed" or (
                    isinstance(item, dict) and item.get("type") == "function_call"
                ):
                    return
        finally:
            events.close()
        raise RuntimeError("The model stream ended early.")
    stream = stream_round(
        provider, PROBE_SYSTEM, log, [PROBE_TOOL], {}, ssl_context(), api_error_text,
        model=model, endpoint=endpoint, probing=True,
    )
    try:
        for _piece in stream:
            return
    finally:
        stream.close()


def start_discovery(run=True):
    global DISCOVERY
    if DISCOVERY is None:
        DISCOVERY = Discovery(
            os.path.join(support_dir(), "models-cache.json"),
            probe_model, ssl_context, refresh_settings,
        )
        set_live(DISCOVERY.allowed, DISCOVERY.default, DISCOVERY.endpoint, DISCOVERY.info)
    if run:
        DISCOVERY.start()
    return DISCOVERY


_TOOL_CACHE = {}  # host -> {"tools", "at", "offline", "code", "detail"}
_TOOL_LOCK = threading.Lock()
TOOL_CACHE_SECONDS = 300
OFFLINE_RETRY_SECONDS = 15

CONSULT_TOOL = "consult_model"
SCREENSHOT_TOOL = "take_screenshot"
LIMIT_NOTE = (
    "\n\n[The reply stopped here because the model reached its output limit. "
    "Say \"continue\" and it will pick up where it left off.]"
)
STEP_NOTE = (
    "\n\n[Stopped after %d tool steps in one turn. Say \"continue\" to keep going.]"
)
COMPACT_AT = 0.80  # share of the context window that starts trimming a long run


# Opening an SSH login to an old Mac is slow and its sshd refuses a crowd (it
# drops connections beyond a handful that are still signing in). Starts to the
# same Mac go through a small gate, one tool-list lookup at a time.
START_GATE = 3
_GATES = {}
_LOOKUP_LOCKS = {}
_GATE_LOCK = threading.Lock()


def _gate(host):
    with _GATE_LOCK:
        if host not in _GATES:
            _GATES[host] = threading.BoundedSemaphore(START_GATE)
        return _GATES[host]


def _lookup_lock(host):
    with _GATE_LOCK:
        return _LOOKUP_LOCKS.setdefault(host, threading.Lock())


class StartFailure(Exception):
    """A Commander session could not be started; stderr is what ssh printed."""

    def __init__(self, exc, stderr):
        Exception.__init__(self, str(exc))
        self.cause = exc
        self.stderr = stderr


# Retrying will not fix these.
FINAL_CODES = ("auth", "host_key_changed", "stopped", "key_missing", "kex", "old_ssh", "unset", "unlinked")


def start_commander(config, root="", run=None, attempts=3):
    """A started ppc-commander session for this Mac, or StartFailure. Starts
    wait their turn and are retried, since a refused login is usually just a
    busy sshd."""
    failure = None
    for attempt in range(attempts):
        if run is not None:
            run.check()
        client = McpClient(ssh_command(config, root))
        gate = _gate(config.get("TIGER_HOST") or "")
        gate.acquire()
        try:
            if run is not None:
                run.on_abort(client.close)
            client.start()
            return client
        except Exception as exc:
            text = client.stderr_text()
            client.close()
            failure = StartFailure(exc, text)
            if connection.diagnose(text, exc, config)[0] in FINAL_CODES:
                break
        finally:
            gate.release()
        time.sleep(0.8 * (attempt + 1))
    raise failure


def invalidate_tools(host=None):
    """Forget the cached tool list (one Mac's, or all), so the next request
    looks again. Called after an address, user or key changes."""
    with _TOOL_LOCK:
        if host is None:
            _TOOL_CACHE.clear()
        else:
            _TOOL_CACHE.pop(host, None)


def cached_status(config):
    """(known, code, problem) for the Mac config points at, without connecting."""
    if not config:
        code, message = connection.diagnose("This Mac has not been connected", None, {"TIGER_HOST": "x", "TIGER_USER": "x"})
        return False, code, message
    with _TOOL_LOCK:
        entry = _TOOL_CACHE.get(config.get("TIGER_HOST") or "")
    if entry is None:
        return False, "", ""
    return entry["tools"] is not None, entry["code"], entry["detail"] or entry["offline"]


def clean_options(incoming):
    """The per-chat switches Tiger Build sends with a request. Anything that is
    not the expected shape is ignored."""
    options = {"servers": {}, "approve": {}, "root": ""}
    if not isinstance(incoming, dict):
        return options
    for name in ("servers", "approve"):
        table = incoming.get(name)
        if isinstance(table, dict):
            for key, value in table.items():
                if isinstance(key, str) and len(key) <= 40 and isinstance(value, bool):
                    options[name][key] = value
    root = incoming.get("root")
    if isinstance(root, str):
        root = root.strip()
        if root.startswith("/") and len(root) <= 300 and "\n" not in root and "\x00" not in root:
            options["root"] = root.rstrip("/") or "/"
    return options


def supports_images(provider, model):
    """Whether a model can look at a picture. A wrong guess only costs a tool."""
    model = (model or "").lower()
    if provider in ("claude", "gemini", "muse"):
        return True
    if provider == "grok":
        return "build" not in model
    if provider == "chatgpt":
        return not (model in ("gpt-4", "gpt-3.5-turbo", "o1-mini", "o3-mini") or model.startswith("gpt-3"))
    if provider == "mistral":
        return any(word in model for word in ("ministral", "pixtral", "medium", "large", "small", "magistral"))
    if provider == "local":
        return any(word in model for word in ("vl", "vision", "llava", "gemma-3", "gemma-4", "pixtral", "minicpm-v", "-v-", "qwen3.5", "mistral-small-3", "ministral"))
    return False


def without_pictures(messages):
    """For a model that cannot look at pictures: drop them and say so in the message."""
    out = []
    for item in messages:
        if item.get("images"):
            count = len(item["images"])
            item = {k: v for k, v in item.items() if k != "images"}
            item["content"] += "\n[%d attached picture%s not shown: this model cannot view pictures.]" % (count, "" if count == 1 else "s")
        out.append(item)
    return out


_CONTROL = re.compile("[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def clean_text(value):
    """Property lists cannot hold control characters. Terminal output has
    plenty (colour codes, backspaces, carriage returns), so drop colour
    sequences and replace the rest."""
    if not isinstance(value, str):
        return value
    value = re.sub("\x1b\\[[0-9;?]*[ -/]*[@-~]", "", value)
    value = re.sub("\x1b\\][^\x07\x1b]*(\x07|\x1b\\\\)", "", value)
    return _CONTROL.sub("\ufffd", value)


def _clean(data):
    if isinstance(data, dict):
        return dict((clean_text(k), _clean(v)) for k, v in data.items())
    if isinstance(data, (list, tuple)):
        return [_clean(v) for v in data]
    return clean_text(data)


def _plist(data):
    return plistlib.dumps(_clean(data), fmt=plistlib.FMT_XML).decode()


class ToolSession(object):
    """State for one request. Every HTTP request gets its own instance.

    The tool list is shared between requests. A good list is kept for five
    minutes. An offline result is retried after 15 seconds, so a Tiger Mac
    that was asleep at the first request does not stay offline until restart.
    """

    def __init__(self, run=None, options=None, address=None):
        self.config = load_shell_config()
        # Commander runs on the Mac that is chatting. None means that Mac has
        # not been connected; a health check or test passes no address.
        self.linked = address is None or connection.target_config(self.config, address) is not None
        if address is not None and self.linked:
            self.config = connection.target_config(self.config, address)
        self.tools = None
        self.offline = ""
        self.offline_code = ""
        self.extra = Connections()
        self.client = {}
        self.run = run if run is not None else runs.Run("local")
        self.options = options or clean_options({})
        self.side = []
        self.last_context = 0

    # ---- who we are talking to ----

    def set_client(self, info):
        """What Tiger Build reports about the Mac it runs on. Plain short
        strings only; anything else is ignored."""
        clean = {}
        if isinstance(info, dict):
            for key in ("machine", "os", "user", "home"):
                value = info.get(key)
                if isinstance(value, str):
                    value = " ".join(value.split())[:160]
                    if value:
                        clean[key] = value
        self.client = clean
        return clean

    def machine(self):
        return self.client.get("machine") or "a Mac"

    def os_name(self):
        return self.client.get("os") or "Mac OS X"

    def account(self):
        return (self.config.get("TIGER_USER") or "").strip()

    def home(self):
        home = (self.config.get("TIGER_HOME") or "").strip()
        # Tools run as TIGER_USER over SSH. When Tiger Build runs as that
        # same account, the home folder it reports is the right one.
        reported = self.client.get("home") or ""
        if not home and reported.startswith("/") and self.client.get("user") == self.account():
            home = reported
        if home:
            return home.rstrip("/")
        if self.account():
            return "/Users/%s" % self.account()
        return "~"

    def max_steps(self):
        """Tool rounds allowed in one reply (a runaway guard)."""
        try:
            return max(1, min(int(self.extra.config.get("max_tool_steps") or MAX_TOOL_ROUNDS), 200))
        except (TypeError, ValueError):
            return MAX_TOOL_ROUNDS

    def media_root(self):
        return self.home() + "/Library/Application Support/Tiger Build/media"

    # ---- which tools this chat may use ----

    def skip_keys(self):
        """Tool groups the chat has switched off. Consulting another model
        costs money, so it is off unless the chat turned it on."""
        skip = set(key for key, value in self.options["servers"].items() if value is False)
        if self.options["servers"].get("consult") is not True:
            skip.add("consult")
        return skip

    def _tool_key(self, name):
        if name in ("generate_image", "generate_video"):
            return "media"
        if name == CONSULT_TOOL:
            return "consult"
        if name in self.extra.owners:
            return self.extra.owners[name]
        return "commander"

    def _needs_approval(self, key):
        approve = self.options["approve"]
        if key in approve:
            return approve[key]
        if "all" in approve:
            return approve["all"]
        return self.extra.approval_default(key)

    # ---- the Tiger Mac's own tools ----

    def definitions(self):
        if self.tools is not None:
            return self.tools
        if not self.linked:
            code, message = connection.diagnose("This Mac has not been connected", None, {"TIGER_HOST": "x", "TIGER_USER": "x"})
            self.offline = "Tiger Mac tools are offline. %s" % message
            self.offline_code = code
            self.tools = []
            return self.tools
        if not self.config.get("TIGER_HOST") or not self.account():
            code, message = connection.diagnose("", None, self.config)
            self.offline = message
            self.offline_code = code
            self.tools = []
            return self.tools
        host = self.config["TIGER_HOST"]

        def cached():
            with _TOOL_LOCK:
                entry = _TOOL_CACHE.get(host)
            if entry is None:
                return None
            age = time.time() - entry["at"]
            keep = TOOL_CACHE_SECONDS if entry["tools"] else OFFLINE_RETRY_SECONDS
            return entry if age < keep else None

        entry = cached()
        if entry is None:
            # Everyone who arrives together waits for one lookup.
            with _lookup_lock(host):
                entry = cached()
                if entry is None:
                    code = ""
                    message = ""
                    client = None
                    try:
                        client = start_commander(self.config, "", self.run)
                        tools = xai_tools_from_mcp(client.request("tools/list", {}, timeout=30))
                        offline = ""
                    except runs.Stopped:
                        raise
                    except Exception as exc:
                        tools = []
                        text = exc.stderr if isinstance(exc, StartFailure) else ""
                        code, message = connection.diagnose(text, exc, self.config)
                        offline = "Tiger Mac tools are offline. %s" % (message or str(exc))
                        sys.stderr.write("tigerbuild-relay: %s (%s)\n" % (offline, exc))
                    finally:
                        if client is not None:
                            client.close()
                    entry = {"tools": tools, "at": time.time(), "offline": offline, "code": code,
                             "detail": (message or "") if offline else ""}
                    with _TOOL_LOCK:
                        _TOOL_CACHE[host] = entry
        tools, offline, code = entry["tools"], entry["offline"], entry["code"]
        self.tools = tools
        self.offline = offline
        self.offline_code = code
        return tools

    def _cap_command_wait(self, args):
        # A command that never prints and never exits used to block the chat
        # for the full timeout, which the model often sets to two minutes.
        capped = dict(args)
        raw = capped.get("timeout_ms")
        try:
            wait_ms = int(raw)
        except (TypeError, ValueError):
            wait_ms = 15000
        if wait_ms < 1000:
            wait_ms = 1000
        if wait_ms > 20000:
            wait_ms = 20000
        capped["timeout_ms"] = wait_ms
        return capped

    def _call_args(self, call):
        raw_args = call.get("arguments") or "{}"
        try:
            args = json.loads(raw_args) if isinstance(raw_args, str) else raw_args
        except ValueError:
            args = {}
        if not isinstance(args, dict):
            return {}
        return args

    def _stopped_early(self, output, exc):
        detail = (output or "").strip()
        if not detail and exc is not None:
            detail = str(exc).strip()
        if len(detail) > 600:
            detail = detail[:600] + "..."
        if not detail:
            return "\n\nI couldn't finish after that step."
        return "\n\nThe last command stopped with an error:\n" + detail

    def _saved_media_text(self, kind, filename):
        path = "%s/%s" % (self.media_root(), filename)
        if kind == "video":
            return "Saved the video on the Tiger Mac at %s." % path
        return "Saved the image on the Tiger Mac at %s." % path

    def _media_status(self, name):
        if name == "generate_image":
            return "Generating an image..."
        if name == "generate_video":
            return "Generating a video. This can take a minute..."
        if name == CONSULT_TOOL:
            return "Asking another model..."
        return ""

    def _tool_event(self, call, phase, output="", failed=False, elapsed=0):
        args = self._call_args(call)
        name = call.get("name") or "tool"
        detail = args.get("command") or args.get("input") or args.get("query") or args.get("url") or args.get("question") or json.dumps(args, ensure_ascii=False)
        return _plist({"id": call.get("id") or call.get("call_id") or name, "name": name, "phase": phase,
                       "detail": str(detail)[:20000], "output": str(output)[:100000],
                       "failed": bool(failed), "elapsed": float(elapsed)})

    # ---- model consult ----

    def _consult_choices(self):
        """[(provider, model, title)] for every working model, each
        provider's default first."""
        rows = []
        disc = DISCOVERY
        for provider, _title in CATALOG_PROVIDERS:
            if provider == "local":
                try:
                    for item in cached_local_models():
                        rows.append(("local", item["id"], item["id"]))
                except Exception:
                    pass
                continue
            if disc is None or not disc_has_key(provider):
                continue
            default = disc.default(provider)
            usable = sorted(disc.usable(provider), key=lambda item: item["id"] != default)
            for item in usable:
                rows.append((provider, item["id"], item["title"]))
        return rows

    def _consult_definition(self):
        rows = self._consult_choices()
        if not rows:
            return None
        seen = {}
        listing = []
        for provider, model, title in rows:
            seen[provider] = seen.get(provider, 0) + 1
            if seen[provider] <= 6:
                listing.append("%s/%s" % (provider, model))
        return function_tool(
            CONSULT_TOOL,
            "Ask a different AI model for advice or a review: a second opinion on a plan, a bug, a design, or "
            "a draft. The other model cannot use tools or see this chat, so put what it needs in question. "
            "Its answer comes back as the tool result; weigh it, do not just repeat it. Available: "
            + ", ".join(listing) + ".",
            {
                "provider": {"type": "string", "description": "grok, chatgpt, claude, mistral, muse, gemini or local"},
                "model": {"type": "string", "description": "Model id from the list. Optional; the provider's default is used when blank."},
                "question": {"type": "string", "description": "What to ask. Be specific and include any code or text to review."},
            },
            ("provider", "question"),
        )

    def _consult(self, args):
        question = args.get("question")
        if not isinstance(question, str) or not question.strip():
            raise ValueError("Give a question.")
        if len(question) > 60000:
            raise ValueError("The question is too long; send the key parts.")
        try:
            provider = normalize_provider(args.get("provider"))
        except RuntimeError as exc:
            raise ValueError(str(exc))
        model = args.get("model") if isinstance(args.get("model"), str) else None
        choices = self._consult_choices()
        pool = [row for row in choices if row[0] == provider]
        if not pool:
            raise ValueError("%s has no working models right now." % provider)
        if model and model not in [row[1] for row in pool]:
            raise ValueError("%s is not an available %s model." % (model, provider))
        chosen = resolve_model(provider, model) if provider != "local" else (model or pool[0][1])
        child = ToolSession(self.run, clean_options({}))
        system = (
            "Another AI assistant is consulting you for advice or a review. Answer directly and concisely. "
            "Say plainly what you would change and why, and what you are unsure about. You have no tools."
        )
        parts = []
        for kind, text in child.iter_turn([{"role": "user", "content": question}], False, provider, chosen, system):
            if kind == "t":
                parts.append(text)
            elif kind == "u":
                self.side.append(("u", text))
        answer = "".join(parts).strip()
        if not answer:
            raise RuntimeError("%s returned no answer." % chosen)
        return "Answer from %s/%s:\n\n%s" % (provider, chosen, answer)

    # ---- running one tool call ----

    def _client_for(self, client_holder):
        if client_holder[0] is None:
            client_holder[0] = start_commander(self.config, self.options["root"], self.run)
        return client_holder[0]

    def _run_one_call(self, provider, call, client_holder):
        """(summary, output, media, failed, images)"""
        name = call.get("name") or ""
        args = self._call_args({"arguments": call.get("arguments") or "{}"})
        if not args and isinstance(call.get("arguments"), dict):
            args = call.get("arguments")
        if name in ("start_process", "interact_with_process"):
            args = self._cap_command_wait(args)
        if name in ("generate_image", "generate_video"):
            label = "Generating an image..." if name == "generate_image" else "Generating a video. This can take a minute..."
            kind = "image" if name == "generate_image" else "video"
            try:
                info = create_media(provider, name, args.get("prompt") or "", ssl_context())
            except Exception as exc:
                return label, "error: %s" % exc, None, True, []
            return label, self._saved_media_text(kind, info["filename"]), "%s %s" % (kind, info["filename"]), False, []
        if name == CONSULT_TOOL:
            try:
                return "Asking another model", self._consult(args), None, False, []
            except Exception as exc:
                return "Asking another model", "error: %s" % exc, None, True, []
        if name == "agent_save_file":
            try:
                if name not in self.extra.offered:
                    raise ValueError("Tool was not enabled or advertised for this request.")
                stored = save_output_file(args.get("name"), args.get("content"))
            except Exception as exc:
                return "Saving a file", "error: %s" % exc, None, True, []
            return "Saving a file", "The file is now in the chat with a Save As button. Do not paste it again.", "file " + stored, False, []
        if name == "agent_show_image":
            try:
                if name not in self.extra.offered:
                    raise ValueError("Tool was not enabled or advertised for this request.")
                filename = fetch_image(args.get("url"))
            except Exception as exc:
                return "Showing a picture", "error: %s" % exc, None, True, []
            return "Showing a picture", "The picture is now shown in the chat.", "image " + filename, False, []
        if self.extra.handles(name):
            try:
                return "Running " + name, self.extra.call(name, args), None, False, []
            except Exception as exc:
                return "Running " + name, "error: %s" % exc, None, True, []
        if not self.extra.config['ppc_enabled']:
            return "Commander disabled", "error: Commander is disabled in the relay's tool settings.", None, True, []
        images = []
        shown = None
        try:
            client = self._client_for(client_holder)
            result = client.request("tools/call", {"name": name, "arguments": args})
            output = result_text(result)
            failed = bool(isinstance(result, dict) and result.get("isError"))
            images = result_images(result)
            if images and not failed:
                # Show the picture the model looked at in the chat too.
                try:
                    import base64
                    from media import save_bytes
                    ext = {"image/png": "png", "image/gif": "gif"}.get(images[0]["mime"], "jpg")
                    shown = "image " + save_bytes(base64.b64decode(images[0]["data"]), ext)
                except Exception:
                    shown = None
        except Exception as exc:
            self.run.check()
            if client_holder[0] is not None:
                stderr = client_holder[0].stderr_text()
            else:
                stderr = exc.stderr if isinstance(exc, StartFailure) else ""
            code, message = connection.diagnose(stderr, exc, self.config)
            output = "error: %s" % (message or exc)
            if code and code not in ("closed",):
                output = "error: Commander could not run (%s). %s" % (exc, message)
            failed = True
            # The next request should look at the link again.
            invalidate_tools(self.config.get("TIGER_HOST"))
        return tool_summary(name, args), output, shown, failed, images

    def _gate(self, call):
        """Ask the person before a tool runs, when approval is on for it.
        Yields the question for Tiger Build; returns "allow" or "deny"."""
        key = self._tool_key(call.get("name") or "")
        if not self._needs_approval(key):
            return "allow"
        call_id = call.get("id") or call.get("call_id") or call.get("name") or "call"
        self.run.ask(call_id)
        args = self._call_args(call)
        detail = args.get("command") or args.get("path") or args.get("query") or args.get("question") or json.dumps(args, ensure_ascii=False)
        yield ("q", _plist({"id": call_id, "name": call.get("name") or "tool", "server": key,
                            "detail": str(detail)[:4000]}))
        decision = self.run.wait(call_id)
        return "allow" if decision in ("allow", "always") else "deny"

    def _execute(self, provider, call, client_holder):
        """Run one call and yield its events. Returns (output, failed, images)."""
        self.run.check()
        decision = yield from self._gate(call)
        announced = self._media_status(call.get("name") or "")
        if announced and decision == "allow":
            yield ("s", announced)
        yield ("a", self._tool_event(call, "start"))
        started = time.monotonic()
        if decision != "allow":
            output = "The person declined to run this tool. Do not retry it; continue without it or explain what you need."
            failed, media, images = True, None, []
        else:
            summary, output, media, failed, images = self._run_one_call(provider, call, client_holder)
        self.run.check()
        yield ("a", self._tool_event(call, "result", output, failed, time.monotonic() - started))
        side, self.side = self.side, []
        for event in side:
            yield event
        if media:
            yield ("m", media)
        return output, failed, images

    def _screenshot_note(self, provider, model, images):
        if images and supports_images(provider, model):
            return {"role": "user", "content": "This is the image that your last tool call returned.", "images": images}
        return None

    # ---- usage and cost ----

    def _usage_event(self, provider, model, usage):
        usage = usage or {}
        if not any(usage.get(name) for name in ("input", "cached", "written", "output")):
            return None
        row = {"provider": provider, "model": model}
        for name in ("input", "cached", "written", "output"):
            row[name] = int(usage.get(name) or 0)
        amount = pricing.cost(provider, model, usage)
        if amount is not None:
            row["cost"] = float(amount)
        self.last_context = row["input"] + row["cached"] + row["written"]
        row["context"] = self.last_context
        return ("u", _plist(row))

    def _context_limit(self, provider, model):
        live = DISCOVERY.context(provider, model) if DISCOVERY else 0
        return live or context_for(provider, model)

    # ---- one turn ----

    def iter_turn(self, messages, use_tools=True, provider="grok", model=None, system_override=None):
        """Yield (kind, text) frames: t text, s status, a tool card, h thinking,
        m media, u usage, q approval question, g guidance delivered, c context
        compacted. Reasoning is shown only as 'h'. use_tools is per chat."""
        try:
            yield from self._iter_turn(messages, use_tools, provider, model, system_override)
        except runs.Stopped:
            return

    def _iter_turn(self, messages, use_tools, provider, model, system_override):
        refresh_settings()
        chosen = resolve_model(provider, model)
        if not supports_images(provider, chosen):
            messages = without_pictures(messages)
        skip = self.skip_keys()
        tools = []
        if use_tools and not system_override:
            if self.extra.config['ppc_enabled'] and "commander" not in skip:
                tools = list(self.definitions())
                if not supports_images(provider, chosen):
                    tools = [t for t in tools if t.get("name") not in (SCREENSHOT_TOOL, "view_image")]
            tools = tools + self.extra.definitions(provider, skip)
            if self.extra.config.get("consult_enabled") and "consult" not in skip:
                consult = self._consult_definition()
                if consult:
                    tools.append(consult)
        if system_override:
            system = system_override
            use_tools = False
        else:
            system = SYSTEM.replace("{machine}", self.machine()).replace("{os}", self.os_name())
            extra = media_tools(provider) if "media" not in skip else []
            if extra:
                tools = list(tools) + extra
                system += (
                    " If the person asks for a picture, call generate_image. "
                    "If they ask for a video or animation, call generate_video. "
                    "Do not say a file was created unless that tool saved one. "
                    "Saved pictures and videos are files in %s on the Tiger Mac. "
                    "If the person asks to put one somewhere else, copy that file "
                    "with the shell. Do not invent a path."
                ) % self.media_root()
        if system_override:
            pass
        elif not use_tools:
            system += (
                " ppc-commander is turned off for this chat. Do not claim you "
                "can read files or run commands on the Tiger Mac. If asked to, "
                "say those tools are off for this chat."
            )
        elif "commander" in skip or not self.extra.config['ppc_enabled']:
            system += (
                " Commander is switched off for this chat. Do not claim you can read files "
                "or run commands on the Tiger Mac."
            )
        elif not any(t.get("name") == "start_process" for t in tools):
            system += (
                " The Tiger Mac tools are offline right now. If asked to touch "
                "that computer, say you cannot reach it."
            )
            if self.offline:
                yield ("s", self.offline)
        else:
            system += (
                " The account on that Mac is %s. Home is %s and the "
                "Desktop is %s/Desktop. Do not look for other users "
                "or call tools just to discover the home directory."
            ) % (self.account(), self.home(), self.home())
            if any(t.get("name") == SCREENSHOT_TOOL for t in tools):
                system += " Use take_screenshot when you need to see what is on that Mac's screen."
            if any(t.get("name") == "agent_save_file" for t in tools):
                system += (" Files the person attaches are given to you in the conversation (text, PDF and document contents as text, "
                           "pictures as pictures). To give them a new or changed file, call agent_save_file with the whole content; "
                           "they get a Save As button.")
            if any(t.get("name") == "view_image" for t in tools):
                system += (" To look at a picture file on that Mac (JPEG, PNG, GIF, TIFF, PDF and so on), call view_image "
                           "with its path; read_file only returns text.")
            if self.options["root"]:
                system += (
                    " This workspace is restricted to the directory %s. File tools and shell commands "
                    "cannot reach outside it; work inside it."
                ) % self.options["root"]
        if any(t.get("name") == CONSULT_TOOL for t in tools):
            system += (
                " You may use consult_model to get a second opinion from another model on hard "
                "decisions or reviews. Do not use it for simple questions."
            )
        if self.extra.errors:
            sys.stderr.write("tigerbuild-relay: custom MCP connection failures: %s\n" % "; ".join(self.extra.errors))
        if provider == "grok":
            system = system.replace("You are an assistant", "You are Grok", 1)
        try:
            if provider != "grok":
                yield from self._iter_foreign(provider, messages, system, tools, chosen)
            else:
                yield from self._iter_grok(messages, system, tools, chosen, bool(system_override))
        finally:
            self.extra.close()

    def _guidance_items(self):
        """Notes the person typed while the model worked. Yields a frame for
        each and returns their text, ready to add to the transcript."""
        notes = self.run.take_guidance()
        for note in notes:
            yield ("g", note)
        return notes

    def _iter_grok(self, messages, system, tools, chosen, bare):
        payload = {
            "model": chosen,
            "store": True,
            "input": [{"role": "system", "content": system}] + openai_responses_input(messages),
        }
        if not bare and self.extra.config['grok_native_search'] and "search" not in self.skip_keys():
            tools = list(tools) + [{"type": "web_search"}]
        if tools:
            payload["tools"] = tools
            payload["tool_choice"] = "auto"
        client = None
        round_index = 0
        forced = False
        last_output = ""
        last_failed = False
        client_holder = [None]
        try:
            while True:
                self.run.check()
                if round_index:
                    yield ("s", "Working on the next step...")
                saw_text = False
                completed = None
                truncated = False
                try:
                    for event in iter_response_events(payload, self.run):
                        self.run.check()
                        etype = event.get("type") if isinstance(event, dict) else ""
                        delta = text_delta(event)
                        if etype == "response.reasoning_summary_text.delta" and show_thinking_on():
                            piece = event.get("delta")
                            if isinstance(piece, str) and piece:
                                yield ("h", piece)
                            continue
                        if etype == "response.reasoning_summary_part.done" and show_thinking_on():
                            yield ("h", "\n\n")
                            continue
                        if delta:
                            saw_text = True
                            yield ("t", delta)
                        elif etype in ("response.completed", "response.incomplete") and isinstance(event.get("response"), dict):
                            completed = event["response"]
                            truncated = etype == "response.incomplete"
                        elif etype in ("error", "response.failed", "response.error"):
                            raise RuntimeError(event_error_message(event))
                except Exception as exc:
                    self.run.check()
                    if saw_text or last_output:
                        yield ("t", self._stopped_early(last_output if last_failed else "", exc))
                        return
                    raise
                self.run.check()
                if isinstance(completed, dict):
                    row = completed.get("usage") or {}
                    holder = {}
                    _openai_usage(holder, row)
                    event = self._usage_event("grok", chosen, holder.get("usage"))
                    if event:
                        yield event
                if not isinstance(completed, dict):
                    if saw_text:
                        return
                    if last_failed:
                        yield ("t", self._stopped_early(last_output, None))
                        return
                    raise RuntimeError("The model stream ended early.")
                if completed.get("error"):
                    raise RuntimeError(event_error_message(completed))
                if truncated:
                    yield ("t", LIMIT_NOTE)
                    return
                calls = function_calls(completed) if tools else []
                if calls and completed.get("id") and not forced and round_index < self.max_steps():
                    outputs = []
                    extra_input = []
                    for call in calls:
                        output, failed, images = yield from self._execute("grok", call, client_holder)
                        client = client_holder[0]
                        last_output = output
                        last_failed = failed
                        if round_index >= self.max_steps() - 3:
                            output += (
                                "\n\nFinish the task with the calls you have left. "
                                "Do not ask the user to type continue."
                            )
                        outputs.append({
                            "type": "function_call_output",
                            "call_id": call.get("call_id") or call.get("id"),
                            "output": output,
                        })
                        shot = self._screenshot_note("grok", chosen, images)
                        if shot:
                            extra_input.extend(openai_responses_input([shot]))
                    notes = yield from self._guidance_items()
                    for note in notes:
                        extra_input.append({"role": "user", "content": "Note from the person while you work: " + note})
                    payload = {
                        "model": chosen,
                        "store": True,
                        "previous_response_id": completed.get("id"),
                        "tools": tools,
                        "tool_choice": "auto",
                        "input": outputs + extra_input,
                    }
                    round_index += 1
                    continue
                if calls and completed.get("id") and not forced:
                    outputs = []
                    for call in calls:
                        outputs.append({
                            "type": "function_call_output",
                            "call_id": call.get("call_id") or call.get("id"),
                            "output": (
                                "No more tools this turn. Tell the user what "
                                "already finished. Do not ask them to type continue."
                            ),
                        })
                    payload = {
                        "model": chosen,
                        "store": True,
                        "previous_response_id": completed.get("id"),
                        "tools": tools,
                        "tool_choice": "none",
                        "input": outputs,
                    }
                    forced = True
                    continue
                if not saw_text:
                    text = ""
                    try:
                        text = extract_text(completed)
                    except RuntimeError:
                        text = ""
                    if text:
                        yield ("t", text)
                    elif last_failed:
                        yield ("t", self._stopped_early(last_output, None))
                    elif last_output:
                        yield ("t", last_output)
                    elif round_index:
                        yield ("t", "Done.")
                    else:
                        raise RuntimeError("The model returned no text.")
                return
        finally:
            if client is not None:
                client.close()

    # ---- keeping a long run inside the context window ----

    @staticmethod
    def _trim_tool_output(log, keep=6):
        """Shorten old tool results. A long run piles up command output that the
        model no longer needs word for word."""
        trimmed = 0
        tool_positions = [i for i, item in enumerate(log) if item.get("role") == "tool"]
        for index in tool_positions[:-keep] if len(tool_positions) > keep else []:
            text = log[index].get("content") or ""
            if len(text) > 700:
                log[index] = dict(log[index], content=text[:350] + "\n...[%d characters removed to save space]...\n" % (len(text) - 550) + text[-200:])
                trimmed += 1
        return trimmed

    def _compact_log(self, provider, model, log):
        """Make room in a long run. First shorten old tool output; if that is
        not enough, replace the oldest part of the run with a summary. Returns
        a sentence for the person, or "" when nothing changed."""
        before = sum(len(item.get("content") or "") for item in log)
        trimmed = self._trim_tool_output(log)
        limit = self._context_limit(provider, model)
        estimate = self.last_context
        if trimmed:
            after = sum(len(item.get("content") or "") for item in log)
            estimate = int(estimate * (after / float(before or 1)))
        if estimate < limit * COMPACT_AT:
            return "Context was getting full, so older tool output was shortened." if trimmed else ""
        # Keep the latest steps whole; summarize everything before them.
        cut = len(log) - 6
        while cut > 1 and log[cut].get("role") == "tool":
            cut -= 1
        if cut < 2:
            return "Context was getting full, so older tool output was shortened." if trimmed else ""
        older = []
        for item in log[:cut]:
            piece = item.get("content") or ""
            if item.get("calls"):
                piece += " [called %s]" % ", ".join(c.get("name") or "" for c in item["calls"])
            if piece:
                older.append("%s: %s" % (item.get("role"), piece[:3000]))
        text = "\n\n".join(older)[:60000]
        try:
            summary = self.plain_complete(provider, model, (
                "Summarize this conversation and the work done so far so the assistant can carry on. Keep names, "
                "decisions, file paths, commands that worked, errors seen and unfinished work. Plain prose."
            ), [{"role": "user", "content": text}])
        except Exception:
            return "Context was getting full, so older tool output was shortened." if trimmed else ""
        log[:cut] = [{"role": "user", "content": "Summary of the earlier part of this conversation:\n" + summary}]
        return "Context was full, so the earlier part of this run was summarized."

    def _iter_foreign(self, provider, messages, system, tools, model):
        log = []
        for message in messages:
            entry = {"role": message["role"], "content": message["content"]}
            if message.get("images"):
                entry["images"] = message["images"]
            log.append(entry)
        client_holder = [None]
        round_index = 0
        last_output = ""
        last_failed = False
        any_text = False
        try:
            while True:
                self.run.check()
                if round_index:
                    yield ("s", "Working on the next step...")
                    if self.last_context and self.last_context >= self._context_limit(provider, model) * COMPACT_AT:
                        note = self._compact_log(provider, model, log)
                        if note:
                            yield ("c", note)
                holder = {"run": self.run}
                saw_text = False
                spoken = []
                try:
                    for delta in stream_round(
                        provider, system, log, tools, holder, ssl_context(), api_error_text, model
                    ):
                        self.run.check()
                        if isinstance(delta, dict) and "thinking" in delta:
                            yield ("h", delta["thinking"])
                            continue
                        if delta:
                            saw_text = True
                            any_text = True
                            spoken.append(delta)
                            yield ("t", delta)
                except Exception as exc:
                    self.run.check()
                    if any_text or last_output:
                        yield ("t", self._stopped_early(last_output if last_failed else "", exc))
                        return
                    raise
                self.run.check()
                event = self._usage_event(provider, model, holder.get("usage"))
                if event:
                    yield event
                calls = holder.get("calls") or []
                if holder.get("truncated"):
                    if not holder.get("noted"):
                        yield ("t", LIMIT_NOTE)
                    return
                if not calls or round_index >= self.max_steps():
                    if calls and round_index >= self.max_steps():
                        yield ("t", STEP_NOTE % self.max_steps())
                    elif not saw_text and last_failed:
                        yield ("t", self._stopped_early(last_output, None))
                    elif not saw_text and last_output and not any_text:
                        yield ("t", last_output)
                    elif not saw_text and not calls and not any_text and not round_index:
                        raise RuntimeError("The model returned no text.")
                    elif not saw_text and round_index and not any_text:
                        yield ("t", "Done.")
                    return
                log.append({
                    "role": "assistant",
                    "content": "".join(spoken),
                    "calls": calls,
                    "claude_blocks": holder.get("claude_blocks"),
                })
                shots = []
                for call in calls:
                    output, failed, images = yield from self._execute(provider, call, client_holder)
                    last_output = output
                    last_failed = failed
                    shots.extend(images)
                    log.append({
                        "role": "tool",
                        "id": call.get("id") or call.get("name") or "",
                        "name": call.get("name") or "",
                        "content": output,
                    })
                shot = self._screenshot_note(provider, model, shots)
                if shot:
                    log.append(shot)
                elif shots:
                    log.append({"role": "user", "content": "(A picture was returned, but this model cannot view images, so describe what you can from the file name, size and other tools.)"})
                notes = yield from self._guidance_items()
                for note in notes:
                    log.append({"role": "user", "content": "Note from the person while you work: " + note})
                round_index += 1
        finally:
            if client_holder[0] is not None:
                client_holder[0].close()

    def plain_complete(self, provider, model, system, messages):
        parts = []
        for kind, text in self.iter_turn(messages, False, provider, model, system):
            if kind == "t":
                parts.append(text)
            elif kind == "u":
                self.side.append(("u", text))
        text = "".join(parts).strip()
        if not text:
            raise RuntimeError("The model returned no text.")
        return text

    def run_turn(self, messages, use_tools=True, provider="grok", model=None):
        parts = []
        statuses = []
        for kind, text in self.iter_turn(messages, use_tools, provider, model):
            if kind == "t":
                parts.append(text)
            elif kind == "s":
                statuses.append(text)
        text = "".join(parts).strip()
        if not text:
            text = "Done." if statuses else ""
            if not text:
                raise RuntimeError("The model returned no text.")
        if statuses:
            notes = "\n".join("STATUS: " + line for line in statuses)
            return notes + "\n---\n" + text
        return text



_LAST_SEEN = {"at": 0.0}


def note_client(address, info=None):
    """Keep a small, secret-free record of the last client for the relay app."""
    now = time.time()
    record = {}
    path = os.path.join(support_dir(), "last-client.json")
    try:
        with open(path) as handle:
            record = json.load(handle)
    except (OSError, ValueError):
        record = {}
    changed = record.get("address") != address or bool(info)
    if not changed and now - _LAST_SEEN["at"] < 30:
        return
    record["address"] = address
    record["seen"] = now
    for key in ("machine", "os", "user"):
        if info and info.get(key):
            record[key] = info[key]
    _LAST_SEEN["at"] = now
    temporary = path + ".tmp"
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            json.dump(record, handle)
        os.replace(temporary, path)
    except OSError:
        pass


class Handler(BaseHTTPRequestHandler):
    # Tiger's CFNetwork reads until the
    # connection closes. Chunked encoding is not reliable there, so HTTP/1.0.
    protocol_version = "HTTP/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("tigerbuild-relay: " + (fmt % args) + "\n")

    def _send(self, code, text):
        data = text.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def _frame(self, kind, text):
        data = text.encode("utf-8")
        # The keepalive thread writes too, so a frame must go out whole.
        lock = self.__dict__.setdefault("_wlock", threading.Lock())
        with lock:
            self.wfile.write(("%s %d\n" % (kind, len(data))).encode("ascii"))
            if data:
                self.wfile.write(data)
            self.wfile.flush()

    def _begin_stream(self):
        try:
            self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except Exception:
            pass
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.flush()

    def _read_json(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length < 0 or length > 40000000:
            raise RuntimeError("request is too large")
        raw = self.rfile.read(length) if length else b""
        try:
            incoming = json.loads(raw.decode("utf-8")) if raw else {}
        except ValueError:
            raise RuntimeError("request was not JSON")
        if not isinstance(incoming, dict):
            raise RuntimeError("request was not an object")
        return incoming

    def _cleaned_messages(self, incoming, require_user_end=True):
        messages = incoming.get("messages")
        if not isinstance(messages, list) or not messages:
            raise RuntimeError("messages must be a non-empty list")
        cleaned = []
        for item in messages:
            if not isinstance(item, dict):
                raise RuntimeError("each message must be an object")
            role = item.get("role")
            content = item.get("content")
            if role not in ("user", "assistant") or not isinstance(content, str):
                raise RuntimeError("messages need role user or assistant and string content")
            if content.strip() == "":
                continue
            entry = {"role": role, "content": content}
            pictures = self._clean_pictures(item.get("images")) if role == "user" else []
            if pictures:
                entry["images"] = pictures
            cleaned.append(entry)
        if not cleaned:
            raise RuntimeError("messages must be a non-empty list")
        if require_user_end and cleaned[-1]["role"] != "user":
            raise RuntimeError("the last message must be from the user")
        return cleaned

    @staticmethod
    def _clean_pictures(value):
        """Pictures the person attached to a message: [{"mime", "data" (base64)}]."""
        pictures = []
        if not isinstance(value, list):
            return pictures
        for image in value[:8]:
            if (isinstance(image, dict) and image.get("mime") in ("image/jpeg", "image/png", "image/gif")
                    and isinstance(image.get("data"), str) and 0 < len(image["data"]) <= 8000000):
                pictures.append({"mime": image["mime"], "data": image["data"]})
        return pictures

    def _provider_and_model(self, incoming):
        try:
            provider = normalize_provider(incoming.get("provider"))
        except RuntimeError as exc:
            raise RuntimeError(str(exc))
        requested = incoming.get("model")
        if not isinstance(requested, str):
            requested = None
        return provider, requested

    def _authorized(self, need_token=True):
        """Only the Tiger Mac (and this Mac) may connect, and only with the token."""
        address = self.client_address[0] if self.client_address else ""
        if not client_allowed(address, ALLOWED):
            self._send(403, "This address may not use the relay.\n")
            return False
        if need_token and not token_ok(self.headers.get(TOKEN_HEADER), TOKEN):
            self._send(401, "The relay token is missing or wrong. Set it in Tiger Build Preferences.\n")
            return False
        if need_token and address not in ("127.0.0.1", "::1"):
            note_client(address)
        return True

    def _health(self):
        """Report whether the relay can actually do its job."""
        refresh_settings()
        problems = []
        keyed = []
        for provider, env_name in (
            ("grok", "XAI_API_KEY"), ("chatgpt", "OPENAI_API_KEY"),
            ("claude", "ANTHROPIC_API_KEY"), ("mistral", "MISTRAL_API_KEY"),
            ("muse", "MUSE_API_KEY"), ("gemini", "GEMINI_API_KEY"),
        ):
            if os.environ.get(env_name, "").strip():
                keyed.append(provider)
        local_line = "none"
        try:
            local_count = len(cached_local_models())
        except Exception:
            local_count = 0
        if local_count:
            local_line = "%d models" % local_count
        if not keyed and not local_count:
            # One key is enough, and so is a local server with no keys at all.
            problems.append("no provider API keys are set and the local server has no models")
        session = ToolSession()
        tools = session.definitions()
        if tools:
            tool_line = "online (%d tools)" % len(tools)
        else:
            tool_line = session.offline or "offline"
            problems.append("Tiger Mac tools are offline")
        models_line = DISCOVERY.summary() if DISCOVERY else "not loaded"
        lines = [
            ("ok " if not problems else "degraded ") + MODEL,
            "version: %s" % VERSION,
            "providers with keys: %s" % (", ".join(keyed) or "none"),
            "working models: %s" % models_line,
            "local server: %s" % local_line,
            "tiger mac tools: %s" % tool_line,
        ]
        if problems:
            lines.append("problems: %s" % "; ".join(problems))
        self._send(200 if not problems else 503, "\n".join(lines) + "\n")

    def _post_settings(self):
        refresh_settings()
        try:
            incoming = self._read_json()
            update_settings(incoming)
            if incoming.get("clear_all") is True:
                from integrations import write as reset_integrations
                reset_integrations({})
            if DISCOVERY and isinstance(incoming, dict):
                # A changed key means a new model list, and old checks no
                # longer say anything, so those providers start over.
                touched = set(SETTING_PROVIDERS[name][0] for name in SETTING_PROVIDERS) if incoming.get("clear_all") is True else set()
                for name in list(incoming.keys()) + list(incoming.get("clear") or []):
                    if name in SETTING_PROVIDERS and (name != "clear"):
                        value = incoming.get(name)
                        if name in (incoming.get("clear") or []) or (isinstance(value, str) and value.strip()):
                            touched.update(SETTING_PROVIDERS[name])
                DISCOVERY.poke(sorted(touched))
        except RuntimeError as exc:
            self._send(400, str(exc) + "\n")
            return
        except Exception as exc:
            self._send(502, str(exc) + "\n")
            return
        self._send(200, settings_public())

    def _history_upload(self):
        # A single, owner-private snapshot. No caller-supplied paths.
        from history_store import save_snapshot
        try:
            size = int(self.headers.get("Content-Length") or "0")
            if size < 1 or size > 16 * 1024 * 1024:
                raise ValueError("History must be between 1 byte and 16 MB.")
            self.connection.settimeout(30)
            payload = self.rfile.read(size)
            if len(payload) != size:
                raise ValueError("Incomplete history upload.")
            save_snapshot(payload)
        except (ValueError, OSError) as exc:
            self._send(400, str(exc) + "\n")
            return
        self._send(200, "History copied to relay host.\n")

    def _history_download(self):
        from history_store import read_snapshot
        try:
            payload = read_snapshot()
        except OSError:
            self._send(404, "No history snapshot on this relay yet. Export to Relay Host first.\n")
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/x-plist")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def _post_side_task(self, path):
        try:
            incoming = self._read_json()
            cleaned = self._cleaned_messages(incoming, True)
            provider, requested = self._provider_and_model(incoming)
        except RuntimeError as exc:
            self._send(400, str(exc) + "\n")
            return
        if path == "/v1/title":
            system = (
                "You name chats. Reply with a short title of at most six words. "
                "No quotes."
            )
        else:
            system = (
                "Summarize this conversation so a later reply can continue it. "
                "Keep names, decisions, file paths, and unfinished work. "
                "Write plain prose."
            )
        try:
            text = ToolSession().plain_complete(provider, requested, system, cleaned)
        except Exception as exc:
            self._send(502, str(exc) + "\n")
            return
        if path == "/v1/title":
            text = clean_title(text)
        self._send(200, text)

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path == "/health":
            # Allowed addresses only; no token so a plain curl can check it.
            if self._authorized(need_token=False):
                self._health()
            return
        if not self._authorized():
            return
        refresh_settings()
        if path in ("/v1/integrations", "/v1/config-export"):
            from integrations import public
            from config_backup import export
            payload = export() if path == "/v1/config-export" else plistlib.dumps(public(), fmt=plistlib.FMT_XML)
            self.send_response(200)
            self.send_header("Content-Type", "application/x-plist")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers(); self.wfile.write(payload)
            return
        if path == "/v1/history":
            self._history_download()
            return
        if path == "/v1/tools":
            from integrations import catalogue
            target, _address = self._client_target()
            _known, code, offline = cached_status(target)
            payload = plistlib.dumps({"tools": catalogue(), "commander_problem": offline,
                                      "commander_code": code}, fmt=plistlib.FMT_XML)
            self.send_response(200)
            self.send_header("Content-Type", "application/x-plist")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)
            return
        if path == "/v1/ssh":
            self._ssh_state()
            return
        if path == "/v1/ssh/public-key":
            try:
                self._send(200, connection.ensure_key(load_shell_config()) + "\n")
            except Exception as exc:
                self._send(502, str(exc) + "\n")
            return
        if path == "/v1/models":
            self._send(200, start_discovery(False).models_text())
            return
        if path.startswith("/v1/media/"):
            name = safe_name(path[len("/v1/media/"):])
            folder = os.path.realpath(media_dir())
            file_path = os.path.realpath(os.path.join(folder, name)) if name else ""
            if (
                not name
                or not file_path.startswith(folder + os.sep)
                or not os.path.isfile(file_path)
            ):
                self._send(404, "not found\n")
                return
            handle = open(file_path, "rb")
            try:
                payload = handle.read()
            finally:
                handle.close()
            kind = "image/jpeg"
            if name.endswith(".png"):
                kind = "image/png"
            elif name.endswith(".gif"):
                kind = "image/gif"
            elif not name.endswith((".jpg", ".jpeg", ".png", ".mp4")):
                kind = "application/octet-stream"
            elif name.endswith(".mp4"):
                kind = "video/mp4"
            self.send_response(200)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)
            return
        if path == "/v1/settings":
            self._send(200, settings_public())
            return
        if path == "/v1/local-models":
            self._send(200, local_models_text())
            return
        if path == "/v1/context":
            fields = {}
            for piece in query.split("&"):
                if "=" not in piece:
                    continue
                name, value = piece.split("=", 1)
                fields[name] = value
            try:
                provider = normalize_provider(fields.get("provider"))
            except RuntimeError:
                provider = "grok"
            model = urllib.parse.unquote(fields.get("model") or "")
            live = DISCOVERY.context(provider, model) if DISCOVERY else 0
            self._send(200, "%s\n" % (live or context_for(provider, model)))
            return
        self._send(404, "not found\n")

    def _extract(self):
        """Turn an Office, iWork, HEIC or WebP file into text and JPEG pictures (see extract.py)."""
        import extract as converter
        from urllib.parse import unquote
        try:
            size = int(self.headers.get("Content-Length") or "0")
            if size < 1 or size > 80 * 1024 * 1024:
                raise ValueError("Files from 1 byte to 80 MB can be converted.")
            self.connection.settimeout(120)
            data = self.rfile.read(size)
            if len(data) != size:
                raise ValueError("The upload was cut short.")
            name = unquote(self.headers.get("X-Filename") or "file")
            if not converter.handles(name):
                raise ValueError("The relay does not convert this kind of file.")
            result = converter.extract(name, data)
        except (ValueError, converter.Unsupported) as exc:
            self._send(422, str(exc) + "\n")
            return
        except Exception as exc:
            self._send(500, "Could not convert the file: %s\n" % exc)
            return
        payload = plistlib.dumps({"text": result["text"], "images": result["images"], "note": result["note"]}, fmt=plistlib.FMT_XML)
        self.send_response(200)
        self.send_header("Content-Type", "application/x-plist")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        if not self._authorized():
            return
        path = self.path.split("?", 1)[0]
        if path == "/v1/extract":
            self._extract()
            return
        if path in ("/v1/integrations", "/v1/config-import"):
            from integrations import write as write_integrations
            from config_backup import restore
            try:
                size = int(self.headers.get("Content-Length") or "0")
                if size < 1 or size > 2 * 1024 * 1024: raise ValueError("Configuration limit is 2 MB.")
                self.connection.settimeout(30)
                data = self.rfile.read(size)
                if len(data) != size: raise ValueError("Incomplete configuration upload.")
                if path == "/v1/integrations":
                    write_integrations(plistlib.loads(data), preserve_key=True)
                else:
                    # Client imports keep the running relay's address/token/SSH
                    # connection intact, so remote imports cannot lock it out.
                    restore(data, connection=False)
                    if DISCOVERY: DISCOVERY.poke(["grok","chatgpt","claude","mistral","muse","gemini"])
                self._send(200, "Configuration saved. Imported custom MCP servers stay disabled until enabled.\n")
            except Exception as exc:
                self._send(400, str(exc) + "\n")
            return
        if path == "/v1/history":
            self._history_upload()
            return
        if path == "/v1/settings":
            self._post_settings()
            return
        if path in ("/v1/title", "/v1/summarize"):
            self._post_side_task(path)
            return
        if path == "/v1/run":
            self._post_run()
            return
        if path in ("/v1/ssh/connect", "/v1/ssh/settings", "/v1/ssh/forget", "/v1/ssh/test", "/v1/ssh/remove"):
            self._post_ssh(path)
            return
        if path != "/v1/chat":
            self._send(404, "not found\n")
            return
        try:
            incoming = self._read_json()
        except RuntimeError as exc:
            self._send(400, str(exc) + "\n")
            return
        try:
            cleaned = self._cleaned_messages(incoming, True)
        except RuntimeError as exc:
            self._send(400, str(exc) + "\n")
            return
        use_tools = True
        if "tools" in incoming:
            flag = incoming.get("tools")
            if flag is False or flag == 0:
                use_tools = False
        try:
            provider = normalize_provider(incoming.get("provider"))
        except RuntimeError as exc:
            self._send(400, str(exc))
            return
        requested_model = incoming.get("model")
        if not isinstance(requested_model, str):
            requested_model = None
        streaming = self.headers.get("X-TigerBuild-Protocol") == "frames"
        run = runs.start(incoming.get("run"))
        session = ToolSession(run, clean_options(incoming), self.client_address[0] if self.client_address else "")
        reported = session.set_client(incoming.get("client"))
        if reported:
            note_client(self.client_address[0] if self.client_address else "", reported)
        if not streaming:
            try:
                reply = session.run_turn(cleaned, use_tools, provider, requested_model)
            except Exception as exc:
                self._send(502, str(exc))
                return
            finally:
                runs.finish(run)
            self._send(200, reply)
            return
        self._begin_stream()
        done = threading.Event()

        def keepalive():
            # A long tool run can go minutes without a frame. This tells Tiger
            # Build the relay is still working, and notices when it has left.
            while not done.wait(8):
                try:
                    self._frame("k", "")
                except Exception:
                    run.cancel()
                    return

        threading.Thread(target=keepalive, daemon=True).start()
        turn = session.iter_turn(cleaned, use_tools, provider, requested_model)
        try:
            for kind, text in turn:
                if kind in ("t", "s", "m", "a", "h", "u", "q", "g", "c"):
                    self._frame(kind, text)
            self._frame("d", "")
        except (BrokenPipeError, ConnectionError, OSError):
            run.cancel()
        except Exception as exc:
            try:
                self._frame("e", str(exc))
                self._frame("d", "")
            except Exception:
                pass
        finally:
            done.set()
            turn.close()
            runs.finish(run)

    def _post_run(self):
        """Stop, guidance or an approval answer for a running turn."""
        try:
            incoming = self._read_json()
        except RuntimeError as exc:
            self._send(400, str(exc) + "\n")
            return
        run = runs.get(incoming.get("id"))
        if run is None:
            self._send(404, "That turn is not running.\n")
            return
        action = incoming.get("action")
        if action == "stop":
            run.cancel()
        elif action == "guide":
            if not run.add_guidance(incoming.get("text")):
                self._send(400, "Could not take that note.\n")
                return
        elif action == "approve":
            if not run.answer(str(incoming.get("call") or ""), str(incoming.get("decision") or "deny")):
                self._send(404, "Nothing is waiting for that answer.\n")
                return
        else:
            self._send(400, "Unknown action.\n")
            return
        self._send(200, "ok\n")

    def _lines(self, rows):
        self._send(200, "".join("%s=%s\n" % (key, str(value).replace("\n", " ")) for key, value in rows))

    def _client_target(self):
        """(config, is_relay_itself): the Commander settings for whoever is asking."""
        config = load_shell_config()
        address = self.client_address[0] if self.client_address else ""
        return connection.target_config(config, address), address

    def _ssh_state(self):
        target, address = self._client_target()
        known, code, offline = cached_status(target)
        info = connection.describe(target) if target else {
            "host": "", "user": "", "home": "", "key_exists": os.path.isfile(load_shell_config()["TIGER_KEY"]),
            "host_key_saved": False}
        rows = [
            ("host", info["host"]), ("user", info["user"]), ("home", info["home"]),
            ("key_exists", "1" if info["key_exists"] else "0"),
            ("host_key_saved", "1" if info["host_key_saved"] else "0"),
            ("commander", "online" if known and not offline else ("offline" if offline else "unknown")),
            ("code", code), ("problem", offline),
        ]
        self._lines(rows)

    def _post_ssh(self, path):
        global ALLOWED
        try:
            incoming = self._read_json() if int(self.headers.get("Content-Length", "0") or "0") else {}
        except RuntimeError as exc:
            self._send(400, str(exc) + "\n")
            return
        address = (self.client_address[0] if self.client_address else "")
        if address.startswith("::ffff:"):
            address = address[7:]
        relay_itself = address in ("", "127.0.0.1", "::1")
        try:
            base = load_shell_config()
            if path == "/v1/ssh/remove" and not relay_itself:
                # A Mac disconnecting itself.
                removed = connection.remove_client(address)
                invalidate_tools(address)
                ALLOWED = reload_allowed(load_shell_config())
                self._lines([("ok", "1" if removed else "0"), ("code", ""),
                             ("message", "Disconnected." if removed else "This Mac was not connected.")])
                return
            if relay_itself:
                # From the relay computer: the default Mac in config.sh.
                if path == "/v1/ssh/connect":
                    changes = {"TIGER_USER": incoming.get("user")}
                    if incoming.get("host"):
                        changes["TIGER_HOST"] = incoming.get("host")
                    home = incoming.get("home")
                    if isinstance(home, str) and home.startswith("/"):
                        changes["TIGER_HOME"] = home
                    base = connection.update_config(changes)
                    connection.ensure_key(base)
                    connection.remember_host_key(base)
                elif path == "/v1/ssh/settings":
                    changes = {}
                    for field, name in (("host", "TIGER_HOST"), ("user", "TIGER_USER"), ("home", "TIGER_HOME")):
                        if field in incoming:
                            changes[name] = incoming.get(field) or ""
                    base = connection.update_config(changes)
                    if incoming.get("remember_host_key") and base.get("TIGER_HOST"):
                        connection.ensure_key(base)
                        connection.remember_host_key(base)
                elif path == "/v1/ssh/forget":
                    connection.forget_host_key(base)
                    if incoming.get("relearn"):
                        connection.remember_host_key(base)
                target = base
            else:
                # From a Tiger Build computer: its own link, by the address it
                # connects from. It cannot point the relay at someone else's
                # address, only at a different host for its own tools.
                previous = connection.load_clients().get(address) or {}
                if path in ("/v1/ssh/connect", "/v1/ssh/settings"):
                    user = incoming.get("user") or previous.get("user") or ""
                    home = incoming.get("home") if "home" in incoming else previous.get("home", "")
                    host = incoming.get("host") if path == "/v1/ssh/settings" and incoming.get("host") else (previous.get("host") or "")
                    if path == "/v1/ssh/connect":
                        host = ""
                    connection.register_client(address, user, home if isinstance(home, str) and home.startswith("/") else "", host)
                    # The first computer to connect becomes the default in config.sh.
                    if not base.get("TIGER_HOST"):
                        connection.update_config({"TIGER_HOST": address, "TIGER_USER": user})
                target = connection.target_config(load_shell_config(), address)
                if target is None:
                    raise ValueError("This Mac is not connected yet. Choose Connect Commander over SSH.")
                if path in ("/v1/ssh/connect", "/v1/ssh/settings"):
                    connection.ensure_key(target)
                    connection.remember_host_key(target)
                elif path == "/v1/ssh/forget":
                    connection.forget_host_key(target)
                    if incoming.get("relearn"):
                        connection.remember_host_key(target)
            ALLOWED = reload_allowed(load_shell_config())
            invalidate_tools(target.get("TIGER_HOST") if target else None)
            result = connection.test(target)
        except (ValueError, RuntimeError) as exc:
            self._send(400, str(exc) + "\n")
            return
        except Exception as exc:
            self._send(502, str(exc) + "\n")
            return
        self._lines([("ok", "1" if result["ok"] else "0"), ("code", result["code"]), ("message", result["message"])])




def self_test():
    sample = {
        "output": [
            {"type": "reasoning", "summary": []},
            {
                "type": "message",
                "role": "assistant",
                "content": [{"type": "output_text", "text": "Hello from Grok."}],
            },
        ]
    }
    if extract_text(sample) != "Hello from Grok.":
        raise SystemExit("extract failed")
    calls = function_calls({
        "output": [
            {"type": "function_call", "name": "list_directory", "call_id": "c1", "arguments": "{}"},
        ]
    })
    if len(calls) != 1 or calls[0]["name"] != "list_directory":
        raise SystemExit("function call parse failed")
    lines = [
        "event: response.reasoning_summary_text.delta\n",
        '{"nope": true}\n',
        'data: {"type":"response.reasoning_summary_text.delta","delta":"hidden"}\n',
        'data: {"type":"response.output_text.delta","delta":"Hello"}\n',
        'data: {"type":"response.output_text.delta","delta":" there"}\n',
        "data: [DONE]\n",
    ]
    pieces = []
    for event in events_from_lines(lines):
        delta = text_delta(event)
        if delta:
            pieces.append(delta)
    if "".join(pieces) != "Hello there":
        raise SystemExit("stream parse failed")
    if normalize_provider("Claude") != "claude" or normalize_provider("Muse") != "muse":
        raise SystemExit("provider name failed")
    if normalize_provider("Mistral") != "mistral":
        raise SystemExit("mistral name failed")
    if resolve_model("claude", "claude-fable-5-1") != "claude-fable-5-1":
        raise SystemExit("model pick failed")
    if resolve_model("grok", "grok-4.3") != "grok-4.3":
        raise SystemExit("grok model pick failed")
    if resolve_model("mistral", "codestral-latest") != "codestral-latest":
        raise SystemExit("mistral model pick failed")
    if resolve_model("chatgpt", "gpt-5.5-pro") != "gpt-5.5-pro":
        raise SystemExit("pro model was dropped")
    if resolve_model("chatgpt", "not-a-model") != "gpt-5.5":
        raise SystemExit("unknown chat model was accepted")
    if resolve_model("claude", "claude-haiku-4-5-20251001") != "claude-haiku-4-5-20251001":
        raise SystemExit("haiku model pick failed")
    if resolve_model("gemini", "../secret") != "gemini-3.8-flash":
        raise SystemExit("model allowlist failed")
    if normalize_provider("local") != "local":
        raise SystemExit("local provider name failed")
    if resolve_model("local", "qwen/qwen3.8-27b") != "qwen/qwen3.8-27b":
        raise SystemExit("local model pick failed")
    if resolve_model("local", "../secret") != "":
        raise SystemExit("local model allowlist failed")
    if clean_title('  "Four word title"  ') != "Four word title":
        raise SystemExit("title cleanup failed")
    hidden = AnswerStream()
    pieces = []
    pieces.extend(hidden.add_content("Hello <think>secret"))
    pieces.extend(hidden.add_content(" thought</think> there"))
    if "".join(pieces) != "Hello  there" or hidden.finish():
        raise SystemExit("think tags leaked")
    quiet = AnswerStream()
    quiet.add_reasoning("The answer is pong.")
    if quiet.finish() != "The answer is pong.":
        raise SystemExit("reasoning fallback failed")
    wrapped = AnswerStream()
    wrapped.add_reasoning("<think>scratch</think>The answer is pong.")
    if wrapped.finish() != "The answer is pong.":
        raise SystemExit("reasoning think tags leaked")
    only = AnswerStream()
    if only.add_content("<think>secret answer</think>") or only.finish() != "secret answer":
        raise SystemExit("think-only answer was dropped")
    if media_tools("claude") or media_tools("mistral") or media_tools("local"):
        raise SystemExit("media tools were offered to a provider without them")
    if len(media_tools("grok")) != 2 or len(media_tools("muse")) != 1:
        raise SystemExit("media tool list failed")
    if safe_name("../x") or safe_name("a/b") or safe_name("ok.png") != "ok.png":
        raise SystemExit("media name check failed")
    grounded = ensure_user_first([
        {"role": "assistant", "content": "Hello. Ask me anything."},
        {"role": "user", "content": "ping"},
    ])
    if grounded[0].get("role") != "user" or grounded[2].get("content") != "ping":
        raise SystemExit("local transcript was not grounded")
    if ensure_user_first([{"role": "user", "content": "ping"}])[0]["content"] != "ping":
        raise SystemExit("user transcript was rewritten")
    marked = AnswerStream()
    shown = marked.add_content(
        "Sure.\n<tool_call>\n<function=list_directory>\n<parameter=path>\n/Users/example/Desktop\n</parameter>\n</function>\n</tool_call>"
    )
    if "".join(shown).strip() != "Sure.":
        raise SystemExit("tool markup was shown")
    parsed = qwen_tool_calls("\n".join(marked.tool_markup))
    if len(parsed) != 1 or parsed[0]["name"] != "list_directory":
        raise SystemExit("qwen tool call was not parsed")
    if json.loads(parsed[0]["arguments"]).get("path") != "/Users/example/Desktop":
        raise SystemExit("qwen tool arguments were not parsed")
    if context_for("grok", "grok-4.7") < 1000:
        raise SystemExit("context limit missing")
    from app_config import usable_local_models
    listed = usable_local_models(
        [
            {"id": "embed-me", "type": "embeddings", "max_context_length": 2048},
            {"id": "qwen/qwen3.8-27b", "type": "vlm", "max_context_length": 262144},
        ],
        [
            {"id": "embed-me"},
            {"id": "qwen/qwen3.8-27b"},
            {"id": "text-embedding-nomic-embed-text-v1.5"},
        ],
    )
    if len(listed) != 1 or listed[0]["context"] != 262144:
        raise SystemExit("local model filter failed")
    replay = gemini_contents([
        {"role": "user", "content": "ping"},
        {
            "role": "assistant",
            "content": "",
            "calls": [{
                "id": "call_1",
                "name": "ping",
                "arguments": "{\"word\": \"pong\"}",
                "thought_signature": "sig",
            }],
        },
        {"role": "tool", "id": "call_1", "name": "ping", "content": "pong"},
    ])
    call_part = replay[1]["parts"][0]
    if call_part.get("thoughtSignature") != "sig" or call_part["functionCall"].get("id") != "call_1":
        raise SystemExit("gemini thought signature was dropped")
    if replay[2]["parts"][0]["functionResponse"].get("id") != "call_1":
        raise SystemExit("gemini tool result id was dropped")
    discovery_self_test()
    print("proxy self-test ok")


def discovery_self_test():
    import tempfile
    if pretty_title("chatgpt", "gpt-7-mini") != "7 Mini" or pretty_title("mistral", "mistral-large-latest") != "Mistral Large":
        raise SystemExit("model title failed")
    if not transient_error("The model service returned 429: slow down") or transient_error("The model service returned 404: no such model"):
        raise SystemExit("transient error check failed")
    folder = tempfile.mkdtemp()
    calls = []

    def fake_probe(provider, model, endpoint=None):
        calls.append((provider, model, endpoint))
        if model == "gpt-broken":
            raise RuntimeError("The model service returned 400: tools are not supported")
        if model == "gpt-busy":
            raise RuntimeError("The model service returned 429: rate limit")
        if model == "gpt-9-pro" and endpoint != "responses":
            raise RuntimeError("The model service returned 404: use the Responses API")

    found = Discovery(os.path.join(folder, "cache.json"), fake_probe, lambda: None)
    old_key = os.environ.get("OPENAI_API_KEY")
    os.environ["OPENAI_API_KEY"] = "test"
    try:
        found.listed["chatgpt"] = {"at": time.time(), "error": "", "models": [
            {"id": "gpt-5.5", "created": 1}, {"id": "gpt-9", "created": 9},
            {"id": "gpt-9-pro", "created": 8}, {"id": "gpt-broken", "created": 7},
            {"id": "gpt-busy", "created": 6},
        ]}
        ids = [m["id"] for m in found.usable("chatgpt")]
        if ids != ["gpt-5.5"]:
            raise SystemExit("unchecked new models were shown: %s" % ids)
        for model in ("gpt-5.5", "gpt-9", "gpt-9-pro", "gpt-broken", "gpt-busy"):
            found._check("chatgpt", model)
        ids = [m["id"] for m in found.usable("chatgpt")]
        if ids != ["gpt-9", "gpt-9-pro", "gpt-5.5"]:
            raise SystemExit("model check filter failed: %s" % ids)
        if found.endpoint("chatgpt", "gpt-9-pro") != "responses":
            raise SystemExit("responses endpoint was not remembered")
        if found.allowed("chatgpt", "../x") or not found.allowed("chatgpt", "gpt-9"):
            raise SystemExit("live allowlist failed")
        if "model\tchatgpt\tgpt-9\t9\t0\t0" not in found.models_text():
            raise SystemExit("models text failed: %r" % found.models_text())
        found.save()
        again = Discovery(os.path.join(folder, "cache.json"), fake_probe, lambda: None)
        if [m["id"] for m in again.usable("chatgpt")] != ids:
            raise SystemExit("model cache did not reload")
    finally:
        if old_key is None:
            os.environ.pop("OPENAI_API_KEY", None)
        else:
            os.environ["OPENAI_API_KEY"] = old_key
        found.pool.shutdown(wait=False)


def main(argv):
    global TOKEN, ALLOWED
    if len(argv) > 1 and argv[1] == "--self-test":
        self_test()
        return
    created = refresh_settings()
    if len(argv) > 1 and argv[1] == "--models-text":
        # The list as of the last checks, for the copy built into the app.
        sys.stdout.write(start_discovery(False).models_text())
        return
    config = load_shell_config()
    if len(argv) > 1 and argv[1] == "--write-config":
        if created:
            print("Wrote the provider config.")
        else:
            print("Provider config already exists.")
        return
    TOKEN = relay_token(config)
    if len(argv) > 1 and argv[1] == "--print-token":
        print(TOKEN)
        return
    port = int(config.get("LISTEN_PORT") or "8765")
    address = listen_address(config)
    if len(argv) > 1 and argv[1] == "--print-address":
        print(address)
        return
    ALLOWED = reload_allowed(config)
    start_discovery(True)
    pricing.start(ssl_context())
    # The default queue holds 5 waiting connections, so a burst of chats from
    # several computers had some of them reset before the relay accepted them.
    ThreadingHTTPServer.request_queue_size = 128
    server = ThreadingHTTPServer((address, port), Handler)
    server.daemon_threads = True
    from paths import support_dir as _support
    pid_path = os.path.join(_support(), "relay.pid")
    handle = open(pid_path, "w")
    try:
        handle.write("%d\n" % os.getpid())
    finally:
        handle.close()
    sys.stderr.write(
        "tigerbuild-relay listening on %s:%s model %s; clients %s; token in %s\n"
        % (address, port, MODEL, ", ".join(sorted(ALLOWED)), token_path())
    )
    try:
        server.serve_forever()
    finally:
        try:
            if open(pid_path).read().strip() == str(os.getpid()):
                os.remove(pid_path)
        except OSError:
            pass


if __name__ == "__main__":
    main(sys.argv)
