"""Chat providers other than Grok.

The Tiger app speaks one framed stream. Each provider below turns that
provider's own event stream into text deltas and a list of tool calls.
"""

import json
import os
import re
import socket
import urllib.error
import urllib.request

OPENAI_URL = "https://api.openai.com/v1/chat/completions"
OPENAI_RESPONSES_URL = "https://api.openai.com/v1/responses"
MUSE_URL = "https://api.meta.ai/v1/chat/completions"
MISTRAL_URL = "https://api.mistral.ai/v1/chat/completions"
ANTHROPIC_URL = "https://api.anthropic.com/v1/messages"
GEMINI_URL = "https://generativelanguage.googleapis.com/v1beta/models/%s:streamGenerateContent?alt=sse"

ALIASES = {
    "grok": "grok",
    "xai": "grok",
    "chatgpt": "chatgpt",
    "openai": "chatgpt",
    "gpt": "chatgpt",
    "claude": "claude",
    "anthropic": "claude",
    "muse": "muse",
    "meta": "muse",
    "mistral": "mistral",
    "gemini": "gemini",
    "google": "gemini",
    "local": "local",
    "lmstudio": "local",
    "lm-studio": "local",
}


def normalize(name):
    if not name:
        return "grok"
    key = str(name).strip().lower()
    if key not in ALIASES:
        raise RuntimeError("Unknown model %s." % name)
    return ALIASES[key]


def _env_key(*names):
    for name in names:
        value = os.environ.get(name, "").strip()
        if value:
            return value
    return ""


def require_key(provider):
    if provider == "chatgpt":
        key = _env_key("OPENAI_API_KEY")
        label = "OPENAI_API_KEY"
    elif provider == "claude":
        key = _env_key("ANTHROPIC_API_KEY")
        label = "ANTHROPIC_API_KEY"
    elif provider == "muse":
        key = _env_key("MUSE_API_KEY", "MODEL_API_KEY")
        label = "MUSE_API_KEY"
    elif provider == "mistral":
        key = _env_key("MISTRAL_API_KEY")
        label = "MISTRAL_API_KEY"
    elif provider == "gemini":
        key = _env_key("GEMINI_API_KEY", "GOOGLE_API_KEY")
        label = "GEMINI_API_KEY"
    else:
        raise RuntimeError("Unknown model.")
    if not key:
        raise RuntimeError("Add %s in Tiger Build Preferences or the relay .env." % label)
    return key


# Ids are an allowlist. Gemini puts the id in a URL, so unknown names are rejected.
# Each id answered a streaming call that included a tool on the endpoint this
# relay uses. The first id is that provider's default. Gemini 2.5 is closed
# to new keys. Mistral Medium, Small, and Magistral report a zero per-minute
# limit. Grok's multi-agent model needs beta access.
PROVIDERS = (
    ("grok", "Grok"),
    ("chatgpt", "ChatGPT"),
    ("claude", "Claude"),
    ("mistral", "Mistral"),
    ("muse", "Muse"),
    ("gemini", "Gemini"),
    ("local", "Local"),
)

# (id, title) in the order Tiger Build shows them. This is the only copy of
# the list: Tiger Build reads it from /v1/models, and install-tiger.sh bakes
# it into the app bundle as models.txt for when the relay cannot be reached.
CATALOG = {
    "grok": (
        ("grok-4.7", "4.7"),
        ("grok-4.6", "4.6"),
        ("grok-4.5", "4.5"),
        ("grok-4.3", "4.3"),
        ("grok-4.20-0309-reasoning", "4.20 Reasoning"),
        ("grok-4.20-0309-non-reasoning", "4.20"),
        ("grok-build-0.1", "Build 0.1"),
    ),
    "chatgpt": (
        ("gpt-6-astra", "6 Astra"),
        ("gpt-6-luna", "6 Luna"),
        ("gpt-6-sol", "6 Sol"),
        ("gpt-5.6-luna", "5.6 Luna"),
        ("gpt-5.6-sol", "5.6 Sol"),
        ("gpt-5.6-terra", "5.6 Terra"),
        ("gpt-5.5", "5.5"),
        ("gpt-5.5-pro", "5.5 Pro"),
        ("gpt-5.4", "5.4"),
        ("gpt-5.4-mini", "5.4 Mini"),
        ("gpt-5.4-nano", "5.4 Nano"),
        ("gpt-5.4-pro", "5.4 Pro"),
        ("gpt-5.2", "5.2"),
        ("gpt-5.2-pro", "5.2 Pro"),
        ("gpt-5.1", "5.1"),
        ("gpt-5", "5"),
        ("gpt-5-mini", "5 Mini"),
        ("gpt-5-nano", "5 Nano"),
        ("gpt-5-pro", "5 Pro"),
        ("gpt-4.1", "4.1"),
        ("gpt-4.1-mini", "4.1 Mini"),
        ("gpt-4.1-nano", "4.1 Nano"),
        ("gpt-4o", "4o"),
        ("gpt-4o-mini", "4o Mini"),
        ("gpt-4-turbo", "4 Turbo"),
        ("gpt-4", "4"),
        ("gpt-3.5-turbo", "3.5"),
        ("o3", "o3"),
        ("o4-mini", "o4 Mini"),
        ("o3-mini", "o3 Mini"),
        ("o1", "o1"),
        ("o1-pro", "o1 Pro"),
        ("chat-latest", "Latest"),
    ),
    "claude": (
        ("claude-opus-5-5", "Opus 5.5"),
        ("claude-opus-5", "Opus 5"),
        ("claude-opus-4-8", "Opus 4.8"),
        ("claude-opus-4-7", "Opus 4.7"),
        ("claude-opus-4-6", "Opus 4.6"),
        ("claude-opus-4-5-20251101", "Opus 4.5"),
        ("claude-fable-5-1", "Fable 5.1"),
        ("claude-fable-5", "Fable 5"),
        ("claude-sonnet-5", "Sonnet 5"),
        ("claude-sonnet-4-6", "Sonnet 4.6"),
        ("claude-sonnet-4-5-20250929", "Sonnet 4.5"),
        ("claude-haiku-4-5-20251001", "Haiku 4.5"),
    ),
    "mistral": (
        ("ministral-14b-latest", "Ministral 14B"),
        ("ministral-8b-latest", "Ministral 8B"),
        ("ministral-3b-latest", "Ministral 3B"),
        ("codestral-latest", "Codestral"),
        ("mistral-code-latest", "Mistral Code"),
        ("voxtral-small-latest", "Voxtral Small"),
    ),
    "muse": (
        ("muse-spark-1.3", "Spark 1.3"),
        ("muse-spark-1.3-contributor", "1.3 Contributor"),
        ("muse-spark-1.2", "Spark 1.2"),
        ("muse-spark-1.2-contributor", "1.2 Contributor"),
        ("muse-spark-1.1", "Spark 1.1"),
    ),
    "gemini": (
        ("gemini-3.8-flash", "3.8 Flash"),
        ("gemini-3.7-flash", "3.7 Flash"),
        ("gemini-3.6-flash", "3.6 Flash"),
        ("gemini-3.5-flash", "3.5 Flash"),
        ("gemini-3.5-flash-lite", "3.5 Flash Lite"),
        ("gemini-3.1-pro-preview", "3.1 Pro"),
        ("gemini-3.1-pro-preview-customtools", "3.1 Pro Tools"),
        ("gemini-3.1-flash-lite", "3.1 Flash Lite"),
        ("gemini-3-flash-preview", "3 Flash"),
        ("gemma-4-31b-it", "Gemma 4 31B"),
        ("gemma-4-26b-a4b-it", "Gemma 4 26B"),
    ),
}

DEFAULTS = {
    "grok": "grok-4.7",
    "chatgpt": "gpt-5.5",
    "claude": "claude-sonnet-5",
    "mistral": "ministral-14b-latest",
    "muse": "muse-spark-1.3",
    "gemini": "gemini-3.8-flash",
}


def models_text():
    """Tab-separated catalogue for Tiger Build: provider and model lines."""
    lines = []
    for provider, title in PROVIDERS:
        lines.append("provider\t%s\t%s" % (provider, title))
        for model, label in CATALOG.get(provider, ()):
            is_default = "1" if model == DEFAULTS.get(provider) else "0"
            lines.append("model\t%s\t%s\t%s\t%s" % (provider, model, label, is_default))
    return "\n".join(lines) + "\n"


def catalog_ids(provider):
    return tuple(model for model, _title in CATALOG.get(provider) or CATALOG["grok"])


# These chat models reject function tools unless reasoning_effort is one of these.
OPENAI_EFFORT = {
    "gpt-5.6-luna": "none",
    "gpt-5.6-sol": "none",
    "gpt-5.6-terra": "none",
    "gpt-6-luna": "none",
    "gpt-6-sol": "none",
}

# These ids are not chat-completions models. Astra also rejects tools there.
OPENAI_RESPONSES = (
    "gpt-6-astra",
    "gpt-5.5-pro",
    "gpt-5.4-pro",
    "gpt-5.2-pro",
    "gpt-5-pro",
    "o1-pro",
)

def openai_reasoning_model(model):
    """Models that reason before answering, so they have something to show."""
    model = (model or "").lower()
    if "chat" in model or "audio" in model or "realtime" in model or "image" in model:
        return False
    return model.startswith(("o1", "o3", "o4", "gpt-5", "gpt-6"))


ENV_MODEL = {
    "grok": "XAI_MODEL",
    "chatgpt": "OPENAI_MODEL",
    "claude": "ANTHROPIC_MODEL",
    "muse": "MUSE_MODEL",
    "mistral": "MISTRAL_MODEL",
    "gemini": "GEMINI_MODEL",
}


def local_model_name(requested):
    if not isinstance(requested, str):
        return ""
    name = requested.strip()
    if not name or len(name) > 180:
        return ""
    if any(ch in name for ch in ("\r", "\n", "\t", " ")):
        return ""
    if name.startswith("/") or name.startswith("\\") or ".." in name:
        return ""
    return name


# discovery.py fills these in at relay start. Without it (self-tests, an
# MCP client importing this file) only the static catalog is used.
LIVE = {"allowed": None, "default": None, "endpoint": None, "info": None}


def set_live(allowed, default, endpoint, info=None):
    LIVE["allowed"] = allowed
    LIVE["default"] = default
    LIVE["endpoint"] = endpoint
    LIVE["info"] = info


def live_info(provider, model):
    getter = LIVE.get("info")
    if not getter:
        return {}
    try:
        return getter(provider, model) or {}
    except Exception:
        return {}


def model_allowed(provider, model):
    if not isinstance(model, str) or not model:
        return False
    if model in catalog_ids(provider):
        return True
    check = LIVE["allowed"]
    return bool(check and check(provider, model))


def resolve_model(provider, requested):
    if provider == "local":
        return local_model_name(requested)
    if provider not in CATALOG:
        provider = "grok"
    wanted = requested.strip() if isinstance(requested, str) else ""
    if wanted and model_allowed(provider, wanted):
        return wanted
    env_name = ENV_MODEL.get(provider)
    if env_name:
        env_value = os.environ.get(env_name, "").strip()
        if env_value and model_allowed(provider, env_value):
            return env_value
    live_default = LIVE["default"](provider) if LIVE["default"] else ""
    return live_default or DEFAULTS[provider]


def model_name(provider, requested=None):
    return resolve_model(provider, requested)


def openai_tools(tools):
    converted = []
    for tool in tools:
        converted.append({
            "type": "function",
            "function": {
                "name": tool["name"],
                "description": tool.get("description") or tool["name"],
                "parameters": tool.get("parameters") or {"type": "object", "properties": {}},
            },
        })
    return converted


def anthropic_tools(tools):
    converted = []
    for tool in tools:
        converted.append({
            "name": tool["name"],
            "description": tool.get("description") or tool["name"],
            "input_schema": tool.get("parameters") or {"type": "object", "properties": {}},
        })
    return converted


def gemini_tools(tools):
    declarations = []
    for tool in tools:
        declarations.append({
            "name": tool["name"],
            "description": tool.get("description") or tool["name"],
            "parameters": tool.get("parameters") or {"type": "object", "properties": {}},
        })
    return [{"functionDeclarations": declarations}] if declarations else []


def _parse_args(raw):
    if isinstance(raw, dict):
        return raw
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
    except ValueError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def openai_messages(system, log):
    messages = [{"role": "system", "content": system}]
    for item in log:
        role = item.get("role")
        if role == "tool":
            messages.append({
                "role": "tool",
                "tool_call_id": item.get("id") or "",
                "content": item.get("content") or "",
            })
            continue
        if role == "assistant" and item.get("calls"):
            tool_calls = []
            for call in item["calls"]:
                arguments = call.get("arguments")
                if not isinstance(arguments, str):
                    arguments = json.dumps(arguments or {})
                tool_calls.append({
                    "id": call.get("id") or "",
                    "type": "function",
                    "function": {
                        "name": call.get("name") or "",
                        "arguments": arguments,
                    },
                })
            messages.append({
                "role": "assistant",
                "content": item.get("content") or None,
                "tool_calls": tool_calls,
            })
            continue
        images = image_parts(item) if role == "user" else []
        if images:
            parts = [{"type": "text", "text": item.get("content") or "(screenshot)"}]
            for image in images:
                parts.append({"type": "image_url", "image_url": {
                    "url": "data:%s;base64,%s" % (image.get("mime") or "image/jpeg", image["data"])}})
            messages.append({"role": role, "content": parts})
            continue
        messages.append({"role": role, "content": item.get("content") or ""})
    return messages


def anthropic_messages(log):
    messages = []
    for item in log:
        role = item.get("role")
        if role == "tool":
            block = {
                "type": "tool_result",
                "tool_use_id": item.get("id") or "",
                "content": item.get("content") or "",
            }
            if messages and messages[-1]["role"] == "user" and isinstance(messages[-1]["content"], list):
                messages[-1]["content"].append(block)
            else:
                messages.append({"role": "user", "content": [block]})
            continue
        if role == "assistant" and item.get("claude_blocks"):
            # Replay original signed/encrypted blocks, in their original order.
            # Never reconstruct thinking from UI text or merge it with answers.
            messages.append({"role":"assistant", "content":item["claude_blocks"]})
            continue
        if role == "assistant" and item.get("calls"):
            blocks = []
            if item.get("content"):
                blocks.append({"type": "text", "text": item["content"]})
            for call in item["calls"]:
                blocks.append({
                    "type": "tool_use",
                    "id": call.get("id") or "",
                    "name": call.get("name") or "",
                    "input": _parse_args(call.get("arguments")),
                })
            messages.append({"role": "assistant", "content": blocks})
            continue
        if role == "user" and (image_parts(item) or (messages and messages[-1]["role"] == "user"
                                                      and isinstance(messages[-1]["content"], list))):
            blocks = [{"type": "text", "text": item.get("content") or "(screenshot)"}]
            for image in image_parts(item):
                blocks.append({"type": "image", "source": {
                    "type": "base64", "media_type": image.get("mime") or "image/jpeg", "data": image["data"]}})
            if messages and messages[-1]["role"] == "user" and isinstance(messages[-1]["content"], list):
                messages[-1]["content"].extend(blocks)
            else:
                messages.append({"role": "user", "content": blocks})
            continue
        if role in ("user", "assistant"):
            messages.append({"role": role, "content": item.get("content") or ""})
    return messages


def _gemini_call_part(call):
    function_call = {
        "name": call.get("name") or "",
        "args": _parse_args(call.get("arguments")),
    }
    call_id = call.get("id") or ""
    if call_id and call_id != function_call["name"]:
        function_call["id"] = call_id
    part = {"functionCall": function_call}
    signature = call.get("thought_signature") or ""
    if signature:
        part["thoughtSignature"] = signature
    return part


def _gemini_response_part(item):
    response = {
        "name": item.get("name") or "",
        "response": {"result": item.get("content") or ""},
    }
    call_id = item.get("id") or ""
    if call_id and call_id != response["name"]:
        response["id"] = call_id
    return {"functionResponse": response}


def gemini_contents(log):
    contents = []
    for item in log:
        role = item.get("role")
        if role == "tool":
            part = _gemini_response_part(item)
            if contents and contents[-1]["role"] == "user":
                contents[-1]["parts"].append(part)
            else:
                contents.append({"role": "user", "parts": [part]})
            continue
        if role == "assistant":
            parts = []
            if item.get("content"):
                parts.append({"text": item["content"]})
            for call in item.get("calls") or []:
                parts.append(_gemini_call_part(call))
            if parts:
                contents.append({"role": "model", "parts": parts})
            continue
        if role == "user":
            parts = [{"text": item.get("content") or "(screenshot)"}]
            for image in image_parts(item):
                parts.append({"inlineData": {"mimeType": image.get("mime") or "image/jpeg", "data": image["data"]}})
            if contents and contents[-1]["role"] == "user" and any("functionResponse" in p for p in contents[-1]["parts"]):
                contents[-1]["parts"].extend(parts)
            else:
                contents.append({"role": "user", "parts": parts})
    return contents


def iter_sse(response):
    event_name = ""
    while True:
        raw = response.readline()
        if not raw:
            break
        line = raw.decode("utf-8", "replace").strip()
        if not line:
            event_name = ""
            continue
        if line.startswith("event:"):
            event_name = line[6:].strip()
            continue
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if data == "[DONE]":
            break
        if not data:
            continue
        try:
            payload = json.loads(data)
        except ValueError:
            continue
        yield event_name, payload


def _post_stream(url, payload, headers, ssl_context, api_error_text):
    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        return urllib.request.urlopen(request, timeout=180, context=ssl_context)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        raise RuntimeError(api_error_text(detail, exc.code))


def _open(holder, url, payload, headers, ssl_context, api_error_text):
    """_post_stream, but a Stop from Tiger Build closes the response, which
    wakes the read that is waiting on the model."""
    response = _post_stream(url, payload, headers, ssl_context, api_error_text)
    run = holder.get("run")
    if run is not None:
        run.on_abort(response.close)
        holder["_abort"] = response.close
    return response


def _release(holder, response):
    run = holder.get("run")
    callback = holder.pop("_abort", None)
    if run is not None and callback is not None:
        run.off_abort(callback)
    try:
        response.close()
    except Exception:
        pass


def _note_usage(holder, inputs=0, cached=0, written=0, output=0):
    """Add one response's token counts. Services report them once per call."""
    usage = holder.setdefault("usage", {"input": 0, "cached": 0, "written": 0, "output": 0})
    usage["input"] += max(int(inputs or 0), 0)
    usage["cached"] += max(int(cached or 0), 0)
    usage["written"] += max(int(written or 0), 0)
    usage["output"] += max(int(output or 0), 0)


def _openai_usage(holder, usage):
    if not isinstance(usage, dict):
        return
    prompt = int(usage.get("prompt_tokens") or usage.get("input_tokens") or 0)
    details = usage.get("prompt_tokens_details") or usage.get("input_tokens_details") or {}
    cached = int((details or {}).get("cached_tokens") or 0)
    output = int(usage.get("completion_tokens") or usage.get("output_tokens") or 0)
    _note_usage(holder, max(prompt - cached, 0), cached, 0, output)


def image_parts(item):
    return [
        image for image in (item.get("images") or [])
        if isinstance(image, dict) and image.get("data")
    ]


def _piece_text(value):
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        return value.get("text") or value.get("content") or ""
    if isinstance(value, list):
        parts = []
        for item in value:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict):
                parts.append(item.get("text") or item.get("content") or "")
        return "".join(parts)
    return ""


def _chunk_thinking(value):
    """Mistral Magistral sends content as chunks; {"type":"thinking"} ones
    hold the reasoning. _piece_text skips them because they have no text key."""
    if not isinstance(value, list):
        return ""
    parts = []
    for item in value:
        if isinstance(item, dict) and item.get("type") == "thinking":
            parts.append(_piece_text(item.get("thinking")))
    return "".join(parts)


# Mistral models that rejected reasoning_effort during this run.
MISTRAL_NO_REASONING = set()


def show_thinking():
    """One switch for every service. The key keeps its original name so
    saved settings and backups still load. It asks Claude, ChatGPT Responses,
    Gemini and Mistral for thinking, and shows what local models return."""
    from integrations import read as integration_config
    return bool(integration_config().get("claude_thinking"))


class AnswerStream(object):
    """Hide think blocks and Qwen tool-call markup. Keep a hidden answer if needed."""

    def __init__(self):
        self.visible = []
        self.hidden = []
        self.reasoning = []
        self.tool_markup = []
        self.hiding = ""
        self.buf = ""
        self.thoughts = []

    def take_thoughts(self):
        """Inline <think> text seen since the last call, for live display."""
        out = [piece for piece in self.thoughts if piece]
        self.thoughts = []
        return out

    def add_reasoning(self, text):
        if text:
            self.reasoning.append(text)

    def add_content(self, text):
        if not text:
            return []
        self.buf += text
        return self._drain(False)

    def _think(self, text):
        if text:
            self.hidden.append(text)
            self.thoughts.append(text)

    def _drain(self, final):
        fresh = []
        while True:
            if self.hiding == "think":
                end = self.buf.find("</think>")
                if end >= 0:
                    self._think(self.buf[:end])
                    self.buf = self.buf[end + len("</think>"):]
                    self.hiding = ""
                    continue
                # Release finished think text now; hold back a possible partial tag.
                keep = 0 if final else len("</think>") - 1
                if len(self.buf) > keep:
                    cut = len(self.buf) - keep
                    self._think(self.buf[:cut])
                    self.buf = self.buf[cut:]
                if final:
                    self.hiding = ""
                break
            if self.hiding == "tool":
                end = self.buf.find("</tool_call>")
                if end < 0:
                    if final:
                        self.tool_markup.append("<tool_call>" + self.buf)
                        self.buf = ""
                        self.hiding = ""
                    break
                self.tool_markup.append("<tool_call>" + self.buf[:end] + "</tool_call>")
                self.buf = self.buf[end + len("</tool_call>"):]
                self.hiding = ""
                continue
            think_at = self.buf.find("<think>")
            tool_at = self.buf.find("<tool_call>")
            start = -1
            kind = ""
            tag_len = 0
            if think_at >= 0 and (tool_at < 0 or think_at <= tool_at):
                start = think_at
                kind = "think"
                tag_len = len("<think>")
            elif tool_at >= 0:
                start = tool_at
                kind = "tool"
                tag_len = len("<tool_call>")
            if start < 0:
                if not final:
                    cut = self.buf.rfind("<")
                    if cut >= 0 and cut >= len(self.buf) - 20:
                        fresh.append(self.buf[:cut])
                        self.buf = self.buf[cut:]
                        break
                fresh.append(self.buf)
                self.buf = ""
                break
            fresh.append(self.buf[:start])
            self.buf = self.buf[start + tag_len:]
            self.hiding = kind
        pieces = []
        for piece in fresh:
            if piece:
                pieces.append(piece)
                self.visible.append(piece)
        return pieces

    def flush(self):
        """Visible text still buffered at the end of the stream."""
        return self._drain(True)

    def finish(self):
        self._drain(True)
        if "".join(self.visible).strip():
            return ""
        thought = "".join(self.reasoning).strip()
        if thought:
            if "<tool_call>" in thought:
                self.tool_markup.append(thought)
            return _strip_think(thought)
        return "".join(self.hidden).strip()


def _strip_think(text):
    stream = AnswerStream()
    pieces = []
    pieces.extend(stream.add_content(text))
    pieces.extend(stream._drain(True))
    visible = "".join(pieces).strip()
    if visible:
        return visible
    hidden = "".join(stream.hidden).strip()
    if hidden:
        return hidden
    if "<tool_call>" in (text or ""):
        return ""
    return (text or "").strip()


def ensure_user_first(log):
    """Qwen's prompt template rejects a transcript that starts with the assistant."""
    if not log or log[0].get("role") == "user":
        return log
    return [{"role": "user", "content": "Hello."}] + list(log)


def qwen_tool_calls(text):
    """LM Studio's Qwen template asks for tool calls as XML, not OpenAI chunks."""
    calls = []
    if not text or "<tool_call>" not in text:
        return calls
    chunks = text.split("<tool_call>")
    index = 0
    for chunk in chunks[1:]:
        body = chunk.split("</tool_call>")[0]
        name_at = body.find("<function=")
        if name_at < 0:
            continue
        name_end = body.find(">", name_at)
        if name_end < 0:
            continue
        name = body[name_at + len("<function="):name_end].strip()
        if not name:
            continue
        params = {}
        rest = body[name_end + 1:]
        while True:
            mark = rest.find("<parameter=")
            if mark < 0:
                break
            end = rest.find(">", mark)
            if end < 0:
                break
            key = rest[mark + len("<parameter="):end].strip()
            close = rest.find("</parameter>", end)
            if close < 0:
                params[key] = rest[end + 1:].strip()
                break
            params[key] = rest[end + 1:close].strip()
            rest = rest[close + len("</parameter>"):]
        index += 1
        calls.append({
            "id": "%s-%d" % (name, index),
            "name": name,
            "arguments": json.dumps(params),
        })
    return calls


def _stream_failure(item):
    if not isinstance(item, dict) or item.get("choices"):
        return ""
    err = item.get("error")
    message = ""
    if isinstance(err, dict):
        message = err.get("message") or ""
    elif isinstance(err, str):
        message = err
    if not message:
        alt = item.get("message") or ""
        message = alt if isinstance(alt, str) else ""
    message = message.strip().split("\n")[0].strip()
    return message[:400]


def stream_openai_compatible(url, key, model, system, log, tools, holder, ssl_context, api_error_text):
    payload = {
        "model": model,
        "stream": True,
        "messages": openai_messages(system, log),
    }
    if tools:
        payload["tools"] = openai_tools(tools)
        payload["tool_choice"] = "auto"
        effort = OPENAI_EFFORT.get(model)
        if effort and url == OPENAI_URL:
            payload["reasoning_effort"] = effort
    if url in (OPENAI_URL, MISTRAL_URL) or url.endswith("/chat/completions") and url not in (MUSE_URL,):
        # Ask for the token counts the cost estimate uses. Services that do
        # not know the option ignore it or reject it; see the retry below.
        payload["stream_options"] = {"include_usage": True}
    headers = {
        "Content-Type": "application/json",
        "User-Agent": "TigerBuild-relay/1.4",
    }
    if key:
        headers["Authorization"] = "Bearer " + key
    thinking = show_thinking() and not holder.get("probe")
    # Magistral and other Mistral reasoning models only return thinking
    # chunks when asked. They accept "none" or "high"; models without
    # reasoning reject the field, so remember those and stop asking.
    ask_mistral = thinking and url == MISTRAL_URL and model not in MISTRAL_NO_REASONING
    if ask_mistral:
        payload["reasoning_effort"] = "high"
    try:
        response = _open(holder, url, payload, headers, ssl_context, api_error_text)
    except RuntimeError as exc:
        # Retry only for the "not enabled / not supported" reply, not a 429 or outage.
        text = str(exc)
        if "stream_options" in text and "stream_options" in payload:
            payload.pop("stream_options", None)
            response = _open(holder, url, payload, headers, ssl_context, api_error_text)
        elif ask_mistral and "reasoning_effort" in text:
            payload.pop("reasoning_effort", None)
            response = _open(holder, url, payload, headers, ssl_context, api_error_text)
            MISTRAL_NO_REASONING.add(model)
        else:
            raise
    slots = {}
    finished = False
    answer = AnswerStream()
    try:
        raw_sock = getattr(getattr(getattr(response, "fp", None), "raw", None), "_sock", None)
        if raw_sock is not None:
            raw_sock.settimeout(180)
    except OSError:
        pass
    try:
        for _event, item in iter_sse(response):
            failure = _stream_failure(item)
            if failure:
                raise RuntimeError(failure)
            if isinstance(item.get("usage"), dict):
                _openai_usage(holder, item["usage"])
            choices = item.get("choices") or []
            if not choices:
                continue
            choice = choices[0]
            delta = choice.get("delta") or {}
            if not isinstance(delta, dict):
                delta = {}
            sources = [(delta, choice.get("reasoning_content"))]
            message = choice.get("message") or {}
            if isinstance(message, dict):
                sources.append((message, None))
            for source, extra in sources:
                content = source.get("content")
                reasoning = "".join([
                    _piece_text(
                        source.get("reasoning_content")
                        or source.get("reasoning")
                        or source.get("reasoning_details")
                    ),
                    _piece_text(extra),
                    _chunk_thinking(content),
                ])
                answer.add_reasoning(reasoning)
                if thinking and reasoning:
                    yield {"thinking": reasoning}
                pieces = answer.add_content(_piece_text(content))
                if thinking:
                    for thought in answer.take_thoughts():
                        yield {"thinking": thought}
                for piece in pieces:
                    yield piece
            for call in delta.get("tool_calls") or []:
                index = call.get("index", 0)
                slot = slots.setdefault(index, {"id": "", "name": "", "arguments": ""})
                if call.get("id"):
                    slot["id"] = call["id"]
                function = call.get("function") or {}
                if function.get("name"):
                    slot["name"] = function["name"]
                if function.get("arguments"):
                    slot["arguments"] += function["arguments"]
            if choice.get("finish_reason"):
                if choice.get("finish_reason") == "length":
                    holder["truncated"] = True
                finished = True
                # Keep reading: the usage chunk follows the finish reason.
                continue
            if finished and not choices:
                break
    except socket.timeout:
        pass
    finally:
        _release(holder, response)
    calls = [slot for slot in (slots[index] for index in sorted(slots)) if slot.get("name")]
    # Text held back as a possible tag start (for example "a<b" at the end).
    tail = answer.flush()
    if thinking:
        for thought in answer.take_thoughts():
            yield {"thinking": thought}
    for piece in tail:
        yield piece
    fallback = answer.finish()
    if not calls:
        markup = "\n".join(answer.tool_markup + answer.reasoning)
        calls = qwen_tool_calls(markup)
    if fallback and "<tool_call>" in fallback:
        fallback = ""
    if fallback and not calls:
        yield fallback
    holder["calls"] = calls


def openai_responses_input(log):
    items = []
    for item in log:
        role = item.get("role")
        if role == "tool":
            items.append({
                "type": "function_call_output",
                "call_id": item.get("id") or "",
                "output": item.get("content") or "",
            })
            continue
        if role == "assistant":
            if item.get("content"):
                items.append({"role": "assistant", "content": item["content"]})
            for call in item.get("calls") or []:
                arguments = call.get("arguments")
                if not isinstance(arguments, str):
                    arguments = json.dumps(arguments or {})
                items.append({
                    "type": "function_call",
                    "call_id": call.get("id") or "",
                    "name": call.get("name") or "",
                    "arguments": arguments,
                })
            continue
        images = image_parts(item) if role == "user" else []
        if images:
            parts = [{"type": "input_text", "text": item.get("content") or "(screenshot)"}]
            for image in images:
                parts.append({"type": "input_image", "image_url": "data:%s;base64,%s" % (
                    image.get("mime") or "image/jpeg", image["data"])})
            items.append({"role": "user", "content": parts})
            continue
        if role in ("user", "assistant"):
            items.append({"role": role, "content": item.get("content") or ""})
    return items


def _response_calls(response):
    calls = []
    for item in response.get("output") or []:
        if not isinstance(item, dict) or item.get("type") != "function_call":
            continue
        arguments = item.get("arguments") or "{}"
        if not isinstance(arguments, str):
            arguments = json.dumps(arguments)
        calls.append({
            "id": item.get("call_id") or item.get("id") or item.get("name") or "",
            "name": item.get("name") or "",
            "arguments": arguments,
        })
    return calls


def stream_openai_responses(key, model, system, log, tools, holder, ssl_context, api_error_text):
    payload = {
        "model": model,
        "stream": True,
        "store": False,
        "instructions": system,
        "input": openai_responses_input(log),
    }
    if tools:
        payload["tools"] = [{
            "type": "function",
            "name": tool["name"],
            "description": tool.get("description") or tool["name"],
            "parameters": tool.get("parameters") or {"type": "object", "properties": {}},
        } for tool in tools]
        payload["tool_choice"] = "auto"
    headers = {
        "Content-Type": "application/json",
        "Authorization": "Bearer " + key,
        "User-Agent": "TigerBuild-relay/1.4",
    }
    thinking = show_thinking() and not holder.get("probe")
    if thinking:
        payload["reasoning"] = {"summary": "auto"}
    try:
        response = _open(holder, OPENAI_RESPONSES_URL, payload, headers, ssl_context, api_error_text)
    except RuntimeError:
        if not thinking:
            raise
        # Summaries need a reasoning model and, for some accounts, a verified
        # organization. Answer without them instead of failing the turn.
        payload.pop("reasoning", None)
        thinking = False
        response = _open(holder, OPENAI_RESPONSES_URL, payload, headers, ssl_context, api_error_text)
    completed = None
    try:
        for _event, item in iter_sse(response):
            kind = item.get("type")
            if kind == "response.output_text.delta" and item.get("delta"):
                yield item["delta"]
            elif kind == "response.reasoning_summary_text.delta" and item.get("delta"):
                if thinking:
                    yield {"thinking": item["delta"]}
            elif kind == "response.reasoning_summary_part.done" and thinking:
                yield {"thinking": "\n\n"}
            elif kind in ("response.completed", "response.incomplete") and isinstance(item.get("response"), dict):
                completed = item["response"]
                if kind == "response.incomplete":
                    holder["truncated"] = True
            elif kind in ("error", "response.failed"):
                raise RuntimeError(str((item.get("error") or (item.get("response") or {}).get("error") or {}).get("message")
                                       or "The model failed."))
    finally:
        _release(holder, response)
    _openai_usage(holder, (completed or {}).get("usage"))
    holder["calls"] = _response_calls(completed or {})


# Output cap for Claude. Thinking counts against it, and Opus 5.x thinks
# even when not asked, so a small cap cut long answers off mid-sentence.
# The Models API reports each model's own max_tokens and thinking type;
# discovery.py stores them and we use them. Without that list (first start,
# listing failed) 64000 is used, the highest every current model accepts.
# A model that allows less says so, and we retry with its number.
CLAUDE_MAX_TOKENS = 64000
CLAUDE_LIMITS = {}
CLAUDE_CUT_NOTE = "\n\n[The reply stopped here because it reached Claude's length limit. Ask it to continue.]"


def claude_max_tokens(model, info=None):
    """Learned limit, else the model list's max_tokens, else the fallback."""
    if model in CLAUDE_LIMITS:
        return CLAUDE_LIMITS[model]
    listed = int((info or {}).get("max_output") or 0)
    return listed if listed > 0 else CLAUDE_MAX_TOKENS


def claude_thinking_type(model, info=None):
    """"adaptive", "enabled", or "" (no thinking). Uses the model list when
    it has the answer; otherwise the family names known when this shipped."""
    info = info or {}
    if "thinking" in info:
        return info.get("thinking") or ""
    adaptive = ("opus-4-6", "opus-4-7", "opus-4-8", "opus-5", "sonnet-4-6", "sonnet-5", "fable-5")
    return "adaptive" if any(x in model for x in adaptive) else "enabled"


def _claude_limit(message):
    found = re.search(r"max_tokens:\s*\d+\s*>\s*(\d+)", message or "")
    return int(found.group(1)) if found else 0


def claude_cache_marks(system, messages):
    """Mark where Claude may reuse what it has already read: the system prompt and tools, and
    everything up to the last message. The attached files and earlier turns of a long chat are then
    charged at the cache rate on the next turn instead of in full. Prompts too short to cache are
    ignored by the service."""
    marked = [{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}] if system else system
    if messages:
        last = messages[-1]
        content = last.get("content")
        if isinstance(content, str) and content.strip():
            content = last["content"] = [{"type": "text", "text": content}]
        if isinstance(content, list) and content and isinstance(content[-1], dict):
            block = content[-1]
            empty = block.get("type") == "text" and not (block.get("text") or "").strip()
            if block.get("type") in ("text", "image", "tool_result", "tool_use") and not empty:
                block["cache_control"] = {"type": "ephemeral"}
    return marked


def _without_cache_marks(payload):
    payload["system"] = payload["system"][0]["text"] if isinstance(payload.get("system"), list) else payload.get("system")
    for message in payload.get("messages") or []:
        if isinstance(message.get("content"), list):
            for block in message["content"]:
                if isinstance(block, dict):
                    block.pop("cache_control", None)


def stream_claude(key, model, system, log, tools, holder, ssl_context, api_error_text):
    info=live_info("claude",model)
    messages=anthropic_messages(log)
    payload = {"model":model,"max_tokens":claude_max_tokens(model,info),"stream":True,"system":claude_cache_marks(system,messages),"messages":messages}
    if tools: payload["tools"]=anthropic_tools(tools)
    kind=claude_thinking_type(model,info)
    if kind and show_thinking() and not holder.get("probe"):
        # Adaptive thinking text is omitted unless display is "summarized".
        # Older models take a bounded enabled budget instead.
        payload["thinking"]={"type":"adaptive","display":"summarized"} if kind=="adaptive" else {"type":"enabled","budget_tokens":2048}
    headers={"Content-Type":"application/json","x-api-key":key,"anthropic-version":"2023-06-01","User-Agent":"TigerBuild-relay/1.4"}
    workspace=os.environ.get("ANTHROPIC_WORKSPACE_ID","").strip()
    if workspace:headers["anthropic-workspace-id"]=workspace
    try:
        response=_open(holder,ANTHROPIC_URL,payload,headers,ssl_context,api_error_text)
    except RuntimeError as exc:
        if "cache_control" in str(exc):
            # A model that does not take cache marks still answers without them.
            _without_cache_marks(payload)
            response=_open(holder,ANTHROPIC_URL,payload,headers,ssl_context,api_error_text)
        else:
            limit=_claude_limit(str(exc))
            if not limit or limit>=payload["max_tokens"]:raise
            CLAUDE_LIMITS[model]=limit;payload["max_tokens"]=limit
            response=_open(holder,ANTHROPIC_URL,payload,headers,ssl_context,api_error_text)
    blocks={};arguments={};complete=set();stop="";started={};ended={}
    try:
        for _event,item in iter_sse(response):
            kind=item.get("type");index=item.get("index",0)
            if kind=="error":raise RuntimeError(str((item.get("error") or {}).get("message") or "Claude stream error"))
            if kind=="message_start":
                u=(item.get("message") or {}).get("usage") or {}
                started=u
            if kind=="content_block_start":
                block=dict(item.get("content_block") or {})
                blocks[index]=block
                if block.get("type")=="tool_use":arguments[index]=""
            elif kind=="content_block_delta":
                delta=item.get("delta") or {};block=blocks.get(index)
                if block is None:raise RuntimeError("Claude delta without content block")
                dt=delta.get("type")
                if dt=="text_delta":
                    text=delta.get("text") or "";block["text"]=block.get("text","")+text
                    if text:yield text
                elif dt=="thinking_delta":
                    text=delta.get("thinking") or "";block["thinking"]=block.get("thinking","")+text
                    if text:yield {"thinking":text}
                elif dt=="signature_delta":
                    block["signature"]=block.get("signature","")+(delta.get("signature") or "")
                elif dt=="input_json_delta":arguments[index]=arguments.get(index,"")+(delta.get("partial_json") or "")
            elif kind=="message_delta":
                stop=(item.get("delta") or {}).get("stop_reason") or stop
                ended=item.get("usage") or ended
            elif kind=="content_block_stop":
                block=blocks.get(index,{})
                if block.get("type")=="tool_use" and arguments.get(index):
                    try:block["input"]=json.loads(arguments[index])
                    except ValueError:block["cut"]=True  # arguments ended at the length limit
                complete.add(index)
    finally:_release(holder,response)
    _note_usage(holder,started.get("input_tokens"),started.get("cache_read_input_tokens"),
                started.get("cache_creation_input_tokens"),ended.get("output_tokens") or started.get("output_tokens"))
    if stop in ("max_tokens","model_context_window_exceeded"):
        holder["truncated"]=True
    if stop=="max_tokens":
        # A tool call cut off mid-arguments must not run or be replayed.
        # Drop it, tell the user, and end the turn cleanly.
        for index in sorted(blocks):
            if blocks[index].get("type")=="tool_use" and (blocks[index].get("cut") or index not in complete):
                for later in [i for i in blocks if i>=index]:blocks.pop(later,None)
                break
        holder["claude_blocks"]=[];holder["calls"]=[]
        return
    ordered=[];calls=[]
    for index in sorted(blocks):
        block=blocks[index]
        if index not in complete:raise RuntimeError("Claude returned an incomplete content block; refusing to replay it")
        if block.get("type")=="thinking" and not block.get("signature"):
            raise RuntimeError("Claude thinking block missing its signature; refusing to replay it")
        ordered.append(block)
        if block.get("type")=="tool_use":
            calls.append({"id":block.get("id"),"name":block.get("name"),"type":"tool_use","arguments":json.dumps(block.get("input") or {})})
    holder["claude_blocks"]=ordered
    holder["calls"]=calls


def stream_gemini(key, model, system, log, tools, holder, ssl_context, api_error_text):
    payload = {
        "systemInstruction": {"parts": [{"text": system}]},
        "contents": gemini_contents(log),
    }
    declared = gemini_tools(tools)
    if declared:
        payload["tools"] = declared
    headers = {
        "Content-Type": "application/json",
        "x-goog-api-key": key,
        "User-Agent": "TigerBuild-relay/1.4",
    }
    thinking = show_thinking() and not holder.get("probe")
    if thinking:
        payload["generationConfig"] = {"thinkingConfig": {"includeThoughts": True}}
    try:
        response = _open(holder, GEMINI_URL % model, payload, headers, ssl_context, api_error_text)
    except RuntimeError:
        if not thinking:
            raise
        # Models without thinking reject thinkingConfig; answer without it.
        payload.pop("generationConfig", None)
        thinking = False
        response = _open(holder, GEMINI_URL % model, payload, headers, ssl_context, api_error_text)
    calls = []
    seen = {}
    loose_signature = ""
    meta = {}
    try:
        for _event, item in iter_sse(response):
            if isinstance(item.get("usageMetadata"), dict):
                meta = item["usageMetadata"]
            for candidate in item.get("candidates") or []:
                if candidate.get("finishReason") == "MAX_TOKENS":
                    holder["truncated"] = True
                content = candidate.get("content") or {}
                for part in content.get("parts") or []:
                    signature = part.get("thoughtSignature") or ""
                    if isinstance(signature, str) and signature:
                        loose_signature = signature
                    if part.get("thought"):
                        if thinking and part.get("text"):
                            yield {"thinking": part["text"]}
                        continue
                    text = part.get("text") or ""
                    if text:
                        yield text
                    call = part.get("functionCall")
                    if isinstance(call, dict) and call.get("name"):
                        marker = call.get("id") or json.dumps(call, sort_keys=True)
                        if marker in seen:
                            slot = seen[marker]
                            if signature and not slot.get("thought_signature"):
                                slot["thought_signature"] = signature
                            continue
                        record = {
                            "id": call.get("id") or call["name"],
                            "name": call["name"],
                            "arguments": json.dumps(call.get("args") or {}),
                        }
                        if signature:
                            record["thought_signature"] = signature
                        seen[marker] = record
                        calls.append(record)
    finally:
        _release(holder, response)
    cached = int(meta.get("cachedContentTokenCount") or 0)
    _note_usage(holder, max(int(meta.get("promptTokenCount") or 0) - cached, 0), cached, 0,
                int(meta.get("candidatesTokenCount") or 0) + int(meta.get("thoughtsTokenCount") or 0))
    if loose_signature:
        for record in calls:
            if not record.get("thought_signature"):
                record["thought_signature"] = loose_signature
                break
    holder["calls"] = calls


def stream_round(provider, system, log, tools, holder, ssl_context, api_error_text,
                 model=None, endpoint=None, probing=False):
    """One model call. probing=True is the model check in discovery.py: it
    uses the model as given (it is not on the allowlist yet) and the given
    endpoint ("chat" or "responses" for ChatGPT)."""
    if probing:
        if not isinstance(model, str) or not re.match(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,180}$", model) or ".." in model:
            raise RuntimeError("bad model id")
    else:
        model = resolve_model(provider, model)
        if provider == "chatgpt" and endpoint is None and LIVE["endpoint"]:
            endpoint = LIVE["endpoint"](provider, model) or None
    holder["calls"] = []
    holder["probe"] = probing
    if provider == "local":
        from app_config import local_base, local_key
        if not model:
            raise RuntimeError("Choose a local model in the version menu.")
        yield from stream_openai_compatible(
            local_base() + "/chat/completions",
            local_key(),
            model,
            system,
            ensure_user_first(log),
            tools,
            holder,
            ssl_context,
            api_error_text,
        )
        return
    key = require_key(provider)
    wants_summary = (
        provider == "chatgpt" and not probing and endpoint != "responses" and openai_reasoning_model(model)
        and show_thinking()
    )
    if provider == "chatgpt" and (endpoint == "responses" or (endpoint is None and model in OPENAI_RESPONSES)):
        yield from stream_openai_responses(
            key, model, system, log, tools, holder, ssl_context, api_error_text
        )
        return
    if wants_summary:
        # Chat completions never return reasoning, so a reasoning model is
        # asked through the Responses API, which returns summaries. If that
        # API refuses before anything was said, fall back to chat completions.
        spoke = False
        try:
            for piece in stream_openai_responses(
                key, model, system, log, tools, holder, ssl_context, api_error_text
            ):
                spoke = True
                yield piece
            return
        except RuntimeError:
            if spoke:
                raise
            holder["calls"] = []
    if provider in ("chatgpt", "muse", "mistral"):
        if provider == "chatgpt":
            url = OPENAI_URL
        elif provider == "mistral":
            url = MISTRAL_URL
        else:
            url = MUSE_URL
        yield from stream_openai_compatible(
            url, key, model, system, log, tools, holder, ssl_context, api_error_text
        )
        return
    if provider == "claude":
        yield from stream_claude(key, model, system, log, tools, holder, ssl_context, api_error_text)
        return
    if provider == "gemini":
        yield from stream_gemini(key, model, system, log, tools, holder, ssl_context, api_error_text)
        return
    raise RuntimeError("Unknown model.")
