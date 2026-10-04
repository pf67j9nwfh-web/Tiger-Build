"""Speech to text for Tiger Build's dictation. The Mac records a short WAV clip and the relay turns it into text with
whichever speech service has a key: OpenAI, Mistral (Voxtral) or Google (Gemini), tried in that order. Standard library only."""
import base64
import json
import os
import urllib.error
import urllib.request
import uuid

MAX_BYTES = 30 * 1024 * 1024
OPENAI_URL = "https://api.openai.com/v1/audio/transcriptions"
MISTRAL_URL = "https://api.mistral.ai/v1/audio/transcriptions"
GEMINI_URL = "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent"
# Ids tried in turn; the first the service accepts is used.
OPENAI_MODELS = ("gpt-4o-mini-transcribe", "gpt-4o-transcribe", "whisper-1")
MISTRAL_MODELS = ("voxtral-mini-latest",)
GEMINI_MODELS = ("gemini-3.8-flash", "gemini-2.5-flash")


class NoService(Exception):
    pass


def _key(*names):
    for name in names:
        value = os.environ.get(name, "").strip()
        if value:
            return value
    return ""


def available():
    """The services that have a key, in the order they are tried."""
    found = []
    if _key("OPENAI_API_KEY"):
        found.append("openai")
    if _key("MISTRAL_API_KEY"):
        found.append("mistral")
    if _key("GEMINI_API_KEY", "GOOGLE_API_KEY"):
        found.append("gemini")
    return found


def multipart(fields, filename, data, mime):
    boundary = "----tigerbuild" + uuid.uuid4().hex
    parts = []
    for name, value in fields:
        parts.append(('--%s\r\nContent-Disposition: form-data; name="%s"\r\n\r\n%s\r\n' % (boundary, name, value)).encode())
    parts.append(('--%s\r\nContent-Disposition: form-data; name="file"; filename="%s"\r\nContent-Type: %s\r\n\r\n' % (boundary, filename, mime)).encode())
    parts.append(data)
    parts.append(("\r\n--%s--\r\n" % boundary).encode())
    return b"".join(parts), "multipart/form-data; boundary=" + boundary


def _post(url, body, headers, context, timeout=120):
    request = urllib.request.Request(url, data=body, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout, context=context) as response:
            return json.loads(response.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:300]
        raise RuntimeError("HTTP %d: %s" % (exc.code, detail))


def _multipart_service(url, key, models, data, context, language):
    last = None
    for model in models:
        fields = [("model", model), ("response_format", "json")]
        if language:
            fields.append(("language", language))
        body, kind = multipart(fields, "speech.wav", data, "audio/wav")
        try:
            result = _post(url, body, {"Authorization": "Bearer " + key, "Content-Type": kind}, context)
        except RuntimeError as exc:
            last = exc
            if "HTTP 400" in str(exc) or "HTTP 404" in str(exc):
                continue
            raise
        text = result.get("text")
        if isinstance(text, str):
            return text.strip()
    raise last or RuntimeError("no answer")


def _gemini(key, data, context):
    last = None
    for model in GEMINI_MODELS:
        payload = {"contents": [{"parts": [
            {"text": "Transcribe this speech exactly as spoken. Reply with only the words, no commentary."},
            {"inline_data": {"mime_type": "audio/wav", "data": base64.b64encode(data).decode()}}]}]}
        try:
            result = _post(GEMINI_URL % model, json.dumps(payload).encode(),
                           {"Content-Type": "application/json", "x-goog-api-key": key}, context)
        except RuntimeError as exc:
            last = exc
            if "HTTP 404" in str(exc) or "HTTP 400" in str(exc):
                continue
            raise
        try:
            return "".join(part.get("text", "") for part in result["candidates"][0]["content"]["parts"]).strip()
        except (KeyError, IndexError, TypeError):
            last = RuntimeError("Gemini returned no text")
    raise last or RuntimeError("no answer")


def transcribe(data, context, language=""):
    """(text, service name). Raises NoService when no key is set, ValueError for a bad clip, RuntimeError for a service failure."""
    if not data or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("The recording is not a WAV file.")
    if len(data) > MAX_BYTES:
        raise ValueError("The recording is longer than the relay accepts.")
    services = available()
    if not services:
        raise NoService("Speech to text needs an OpenAI, Mistral or Google key. Add one in the relay's settings.")
    problems = []
    for service in services:
        try:
            if service == "openai":
                return _multipart_service(OPENAI_URL, _key("OPENAI_API_KEY"), OPENAI_MODELS, data, context, language), "OpenAI"
            if service == "mistral":
                return _multipart_service(MISTRAL_URL, _key("MISTRAL_API_KEY"), MISTRAL_MODELS, data, context, language), "Mistral"
            return _gemini(_key("GEMINI_API_KEY", "GOOGLE_API_KEY"), data, context), "Google"
        except (RuntimeError, urllib.error.URLError, OSError) as exc:
            problems.append("%s: %s" % (service, exc))
    raise RuntimeError("; ".join(problems))
