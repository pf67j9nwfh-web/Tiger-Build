"""Chat providers other than Grok.

The Tiger app speaks one framed stream. Each provider below turns that
provider's own event stream into text deltas and a list of tool calls.
"""

import json
import os
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
        raise RuntimeError("Add %s to the relay .env and start the relay again." % label)
    return key


# Ids are an allowlist. Gemini puts the id in a URL, so unknown names are rejected.
# Each id answered a streaming call that included a tool on the endpoint this
# relay uses. The first id is that provider's default. Gemini 2.5 is closed
# to new keys. Mistral Medium, Small, and Magistral report a zero per-minute
# limit. Grok's multi-agent model needs beta access.
CATALOG = {
    "grok": (
        "grok-4.7",
        "grok-4.6",
        "grok-4.5",
        "grok-4.3",
        "grok-4.20-0309-reasoning",
        "grok-4.20-0309-non-reasoning",
        "grok-build-0.1",
    ),
    "chatgpt": (
        "gpt-5.5",
        "gpt-6-astra",
        "gpt-6-luna",
        "gpt-6-sol",
        "gpt-5.6-luna",
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.5-pro",
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.4-nano",
        "gpt-5.4-pro",
        "gpt-5.2",
        "gpt-5.2-pro",
        "gpt-5.1",
        "gpt-5",
        "gpt-5-mini",
        "gpt-5-nano",
        "gpt-5-pro",
        "gpt-4.1",
        "gpt-4.1-mini",
        "gpt-4.1-nano",
        "gpt-4o",
        "gpt-4o-mini",
        "gpt-4-turbo",
        "gpt-4",
        "gpt-3.5-turbo",
        "o3",
        "o4-mini",
        "o3-mini",
        "o1",
        "o1-pro",
        "chat-latest",
    ),
    "claude": (
        "claude-sonnet-5",
        "claude-opus-5-5",
        "claude-opus-5",
        "claude-opus-4-8",
        "claude-opus-4-7",
        "claude-opus-4-6",
        "claude-opus-4-5-20251101",
        "claude-fable-5-1",
        "claude-fable-5",
        "claude-sonnet-4-6",
        "claude-sonnet-4-5-20250929",
        "claude-haiku-4-5-20251001",
    ),
    "mistral": (
        "ministral-14b-latest",
        "ministral-8b-latest",
        "ministral-3b-latest",
        "codestral-latest",
        "mistral-code-latest",
        "voxtral-small-latest",
    ),
    "muse": (
        "muse-spark-1.3",
        "muse-spark-1.3-contributor",
        "muse-spark-1.2",
        "muse-spark-1.2-contributor",
        "muse-spark-1.1",
    ),
    "gemini": (
        "gemini-3.8-flash",
        "gemini-3.7-flash",
        "gemini-3.6-flash",
        "gemini-3.5-flash",
        "gemini-3.5-flash-lite",
        "gemini-3.1-pro-preview",
        "gemini-3.1-pro-preview-customtools",
        "gemini-3.1-flash-lite",
        "gemini-3-flash-preview",
        "gemma-4-31b-it",
        "gemma-4-26b-a4b-it",
    ),
}

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


def resolve_model(provider, requested):
    if provider == "local":
        return local_model_name(requested)
    allowed = CATALOG.get(provider) or CATALOG["grok"]
    if isinstance(requested, str) and requested.strip() in allowed:
        return requested.strip()
    env_name = ENV_MODEL.get(provider)
    if env_name:
        env_value = os.environ.get(env_name, "").strip()
        if env_value in allowed:
            return env_value
    return allowed[0]


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
            contents.append({"role": "user", "parts": [{"text": item.get("content") or ""}]})
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


class AnswerStream(object):
    """Hide think blocks and Qwen tool-call markup. Keep a hidden answer if needed."""

    def __init__(self):
        self.visible = []
        self.hidden = []
        self.reasoning = []
        self.tool_markup = []
        self.hiding = ""
        self.buf = ""

    def add_reasoning(self, text):
        if text:
            self.reasoning.append(text)

    def add_content(self, text):
        if not text:
            return []
        self.buf += text
        return self._drain(False)

    def _close_tag(self, end_tag, sink, final):
        end = self.buf.find(end_tag)
        if end < 0:
            if final:
                sink.append(self.buf)
                self.buf = ""
                self.hiding = ""
            return False
        sink.append(self.buf[:end])
        self.buf = self.buf[end + len(end_tag):]
        self.hiding = ""
        return True

    def _drain(self, final):
        fresh = []
        while True:
            if self.hiding == "think":
                if self._close_tag("</think>", self.hidden, final):
                    continue
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
    headers = {
        "Content-Type": "application/json",
        "User-Agent": "TigerBuild-relay/1.0",
    }
    if key:
        headers["Authorization"] = "Bearer " + key
    response = _post_stream(
        url,
        payload,
        headers,
        ssl_context,
        api_error_text,
    )
    slots = {}
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
            choices = item.get("choices") or []
            if not choices:
                continue
            choice = choices[0]
            delta = choice.get("delta") or {}
            if not isinstance(delta, dict):
                delta = {}
            answer.add_reasoning(_piece_text(
                delta.get("reasoning_content")
                or delta.get("reasoning")
                or delta.get("reasoning_details")
            ))
            for piece in answer.add_content(_piece_text(delta.get("content"))):
                yield piece
            answer.add_reasoning(_piece_text(choice.get("reasoning_content")))
            message = choice.get("message") or {}
            if isinstance(message, dict):
                answer.add_reasoning(_piece_text(
                    message.get("reasoning_content")
                    or message.get("reasoning")
                    or message.get("reasoning_details")
                ))
                for piece in answer.add_content(_piece_text(message.get("content"))):
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
                break
    except socket.timeout:
        pass
    finally:
        response.close()
    calls = [slot for slot in (slots[index] for index in sorted(slots)) if slot.get("name")]
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
    response = _post_stream(
        OPENAI_RESPONSES_URL,
        payload,
        {
            "Content-Type": "application/json",
            "Authorization": "Bearer " + key,
            "User-Agent": "TigerBuild-relay/1.0",
        },
        ssl_context,
        api_error_text,
    )
    completed = None
    try:
        for _event, item in iter_sse(response):
            kind = item.get("type")
            if kind == "response.output_text.delta" and item.get("delta"):
                yield item["delta"]
            elif kind == "response.completed" and isinstance(item.get("response"), dict):
                completed = item["response"]
    finally:
        response.close()
    holder["calls"] = _response_calls(completed or {})


def stream_claude(key, model, system, log, tools, holder, ssl_context, api_error_text):
    payload = {
        "model": model,
        "max_tokens": 4096,
        "stream": True,
        "system": system,
        "messages": anthropic_messages(log),
    }
    if tools:
        payload["tools"] = anthropic_tools(tools)
    headers = {
        "Content-Type": "application/json",
        "x-api-key": key,
        "anthropic-version": "2023-06-01",
        "User-Agent": "TigerBuild-relay/1.0",
    }
    workspace = os.environ.get("ANTHROPIC_WORKSPACE_ID", "").strip()
    if workspace:
        headers["anthropic-workspace-id"] = workspace
    response = _post_stream(
        ANTHROPIC_URL,
        payload,
        headers,
        ssl_context,
        api_error_text,
    )
    blocks = {}
    try:
        for _event, item in iter_sse(response):
            kind = item.get("type")
            if kind == "content_block_start":
                block = item.get("content_block") or {}
                blocks[item.get("index", 0)] = {
                    "type": block.get("type"),
                    "id": block.get("id") or "",
                    "name": block.get("name") or "",
                    "arguments": "",
                }
            elif kind == "content_block_delta":
                delta = item.get("delta") or {}
                if delta.get("type") == "text_delta" and delta.get("text"):
                    yield delta["text"]
                elif delta.get("type") == "input_json_delta":
                    slot = blocks.get(item.get("index", 0))
                    if slot is not None:
                        slot["arguments"] += delta.get("partial_json") or ""
    finally:
        response.close()
    calls = []
    for index in sorted(blocks):
        slot = blocks[index]
        if slot.get("type") == "tool_use":
            calls.append(slot)
    holder["calls"] = calls


def stream_gemini(key, model, system, log, tools, holder, ssl_context, api_error_text):
    payload = {
        "systemInstruction": {"parts": [{"text": system}]},
        "contents": gemini_contents(log),
    }
    declared = gemini_tools(tools)
    if declared:
        payload["tools"] = declared
    response = _post_stream(
        GEMINI_URL % model,
        payload,
        {
            "Content-Type": "application/json",
            "x-goog-api-key": key,
            "User-Agent": "TigerBuild-relay/1.0",
        },
        ssl_context,
        api_error_text,
    )
    calls = []
    seen = {}
    loose_signature = ""
    try:
        for _event, item in iter_sse(response):
            for candidate in item.get("candidates") or []:
                content = candidate.get("content") or {}
                for part in content.get("parts") or []:
                    signature = part.get("thoughtSignature") or ""
                    if isinstance(signature, str) and signature:
                        loose_signature = signature
                    if part.get("thought"):
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
        response.close()
    if loose_signature:
        for record in calls:
            if not record.get("thought_signature"):
                record["thought_signature"] = loose_signature
                break
    holder["calls"] = calls


def stream_round(provider, system, log, tools, holder, ssl_context, api_error_text, model=None):
    model = resolve_model(provider, model)
    holder["calls"] = []
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
    if provider == "chatgpt" and model in OPENAI_RESPONSES:
        yield from stream_openai_responses(
            key, model, system, log, tools, holder, ssl_context, api_error_text
        )
        return
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
