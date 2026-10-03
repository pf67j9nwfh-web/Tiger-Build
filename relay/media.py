"""Image and video generation for providers that offer it.

The chat model calls generate_image or generate_video. This module calls
that provider's own media API and stores the file for Tiger Build to fetch.
"""

import base64
import json
import os
import time
import urllib.error
import urllib.request
import uuid

IMAGE_TOOL = {
    "type": "function",
    "name": "generate_image",
    "description": (
        "Generate a picture with this provider's image service. "
        "Use when the person asks for an image, drawing, or illustration."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "prompt": {"type": "string", "description": "What the picture should show."},
        },
        "required": ["prompt"],
    },
}

VIDEO_TOOL = {
    "type": "function",
    "name": "generate_video",
    "description": (
        "Generate a short video with this provider's video service. "
        "Use when the person asks for a video, clip, or animation."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "prompt": {"type": "string", "description": "What the video should show."},
        },
        "required": ["prompt"],
    },
}


def media_tools(provider):
    tools = []
    if provider in ("grok", "chatgpt", "gemini", "muse"):
        tools.append(IMAGE_TOOL)
    if provider in ("grok", "chatgpt", "gemini"):
        tools.append(VIDEO_TOOL)
    return tools


def media_dir():
    from paths import support_dir
    folder = os.path.join(support_dir(), "media")
    if not os.path.isdir(folder):
        os.makedirs(folder)
    return folder


def safe_name(name):
    if not name or "/" in name or "\\" in name or ".." in name:
        return ""
    allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    if any(ch not in allowed for ch in name):
        return ""
    return name


def save_bytes(data, ext):
    name = "%s.%s" % (uuid.uuid4().hex[:16], ext)
    path = os.path.join(media_dir(), name)
    handle = open(path, "wb")
    try:
        handle.write(data)
    finally:
        handle.close()
    return name


def _key(name):
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError("Add %s before generating media." % name)
    return value


def _request(url, payload, headers, ssl_context, timeout=120):
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=body, headers=headers, method="POST" if payload is not None else "GET")
    try:
        response = urllib.request.urlopen(request, timeout=timeout, context=ssl_context)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        message = detail
        try:
            parsed = json.loads(detail)
            err = parsed.get("error")
            if isinstance(err, dict) and err.get("message"):
                message = err["message"]
            elif isinstance(err, str):
                message = err
        except ValueError:
            pass
        raise RuntimeError(message[:500])
    try:
        return response.read(), response.headers.get("Content-Type") or ""
    finally:
        response.close()


def _json_request(url, payload, headers, ssl_context, timeout=120):
    raw, _kind = _request(url, payload, headers, ssl_context, timeout)
    try:
        return json.loads(raw.decode("utf-8", "replace"))
    except ValueError:
        raise RuntimeError("The media service returned an unreadable response.")


def _download(url, ssl_context, headers=None):
    hdrs = {"User-Agent": "TigerBuild-relay/1.0"}
    if headers:
        hdrs.update(headers)
    request = urllib.request.Request(url, headers=hdrs)
    response = urllib.request.urlopen(request, timeout=120, context=ssl_context)
    try:
        return response.read()
    finally:
        response.close()


def _multipart(fields):
    boundary = "----TigerBuildMedia"
    lines = []
    for name, value in fields:
        lines.append("--" + boundary)
        lines.append('Content-Disposition: form-data; name="%s"' % name)
        lines.append("")
        lines.append(value)
    lines.append("--" + boundary + "--")
    lines.append("")
    body = "\r\n".join(lines).encode("utf-8")
    return boundary, body


def _grok_image(prompt, ssl_context):
    payload = _json_request(
        "https://api.x.ai/v1/images/generations",
        {
            "model": "grok-imagine-image-2.0",
            "prompt": prompt,
            "response_format": "b64_json",
            "n": 1,
        },
        {
            "Content-Type": "application/json",
            "Authorization": "Bearer " + _key("XAI_API_KEY"),
            "User-Agent": "TigerBuild-relay/1.0",
        },
        ssl_context,
    )
    data = (payload.get("data") or [{}])[0]
    if data.get("b64_json"):
        return base64.b64decode(data["b64_json"]), "jpg"
    if data.get("url"):
        return _download(data["url"], ssl_context), "jpg"
    raise RuntimeError("Grok did not return an image.")


def _grok_video(prompt, ssl_context):
    started = _json_request(
        "https://api.x.ai/v1/videos/generations",
        {
            "model": "grok-imagine-video-1.5",
            "prompt": prompt,
            "duration": 5,
            "aspect_ratio": "16:9",
            "resolution": "480p",
        },
        {
            "Content-Type": "application/json",
            "Authorization": "Bearer " + _key("XAI_API_KEY"),
            "User-Agent": "TigerBuild-relay/1.0",
        },
        ssl_context,
    )
    request_id = started.get("request_id") or ""
    if not request_id:
        raise RuntimeError("Grok did not start a video.")
    deadline = time.time() + 180
    while time.time() < deadline:
        time.sleep(4)
        status = _json_request(
            "https://api.x.ai/v1/videos/" + request_id,
            None,
            {
                "Authorization": "Bearer " + _key("XAI_API_KEY"),
                "User-Agent": "TigerBuild-relay/1.0",
            },
            ssl_context,
            timeout=30,
        )
        state = status.get("status") or ""
        if state == "done":
            url = ((status.get("video") or {}).get("url")) or ""
            if not url:
                raise RuntimeError("Grok finished the video without a file.")
            return _download(url, ssl_context), "mp4"
        if state in ("failed", "expired"):
            err = status.get("error") or {}
            message = err.get("message") if isinstance(err, dict) else str(err)
            raise RuntimeError(message or "Grok could not make the video.")
    raise RuntimeError("The video was still rendering after three minutes.")


def _openai_image(prompt, ssl_context):
    payload = _json_request(
        "https://api.openai.com/v1/images/generations",
        {"model": "gpt-image-1.5", "prompt": prompt, "n": 1, "size": "1024x1024"},
        {
            "Content-Type": "application/json",
            "Authorization": "Bearer " + _key("OPENAI_API_KEY"),
            "User-Agent": "TigerBuild-relay/1.0",
        },
        ssl_context,
    )
    data = (payload.get("data") or [{}])[0]
    if data.get("b64_json"):
        return base64.b64decode(data["b64_json"]), "png"
    if data.get("url"):
        return _download(data["url"], ssl_context), "png"
    raise RuntimeError("ChatGPT did not return an image.")


def _openai_video(prompt, ssl_context):
    boundary, body = _multipart([
        ("model", "sora-2"),
        ("prompt", prompt),
        ("seconds", "4"),
        ("size", "1280x720"),
    ])
    request = urllib.request.Request(
        "https://api.openai.com/v1/videos",
        data=body,
        headers={
            "Content-Type": "multipart/form-data; boundary=" + boundary,
            "Authorization": "Bearer " + _key("OPENAI_API_KEY"),
            "User-Agent": "TigerBuild-relay/1.0",
        },
        method="POST",
    )
    try:
        response = urllib.request.urlopen(request, timeout=60, context=ssl_context)
        started = json.loads(response.read().decode("utf-8", "replace"))
        response.close()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:400]
        raise RuntimeError(detail or "ChatGPT could not start a video.")
    video_id = started.get("id") or ""
    if not video_id:
        raise RuntimeError("ChatGPT did not start a video.")
    deadline = time.time() + 180
    while time.time() < deadline:
        time.sleep(4)
        status = _json_request(
            "https://api.openai.com/v1/videos/" + video_id,
            None,
            {
                "Authorization": "Bearer " + _key("OPENAI_API_KEY"),
                "User-Agent": "TigerBuild-relay/1.0",
            },
            ssl_context,
            timeout=30,
        )
        state = status.get("status") or ""
        if state == "completed":
            raw, _kind = _request(
                "https://api.openai.com/v1/videos/%s/content" % video_id,
                None,
                {
                    "Authorization": "Bearer " + _key("OPENAI_API_KEY"),
                    "User-Agent": "TigerBuild-relay/1.0",
                },
                ssl_context,
                timeout=120,
            )
            return raw, "mp4"
        if state in ("failed", "cancelled"):
            err = status.get("error") or {}
            message = err.get("message") if isinstance(err, dict) else "ChatGPT could not make the video."
            raise RuntimeError(message)
    raise RuntimeError("The video was still rendering after three minutes.")


_gemini_cache = {"image": "", "video": ""}


def _gemini_media_models(ssl_context):
    if _gemini_cache["image"] or _gemini_cache["video"]:
        return _gemini_cache["image"], _gemini_cache["video"]
    raw, _kind = _request(
        "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200",
        None,
        {"x-goog-api-key": _key("GEMINI_API_KEY"), "User-Agent": "TigerBuild-relay/1.0"},
        ssl_context,
        timeout=30,
    )
    payload = json.loads(raw.decode("utf-8", "replace"))
    image = ""
    video = ""
    for item in payload.get("models") or []:
        name = (item.get("name") or "").replace("models/", "")
        methods = item.get("supportedGenerationMethods") or []
        lower = name.lower()
        if "image" in lower and "tts" not in lower and "generateContent" in methods and not image:
            image = name
        if "veo" in lower and not video:
            video = name
    _gemini_cache["image"] = image
    _gemini_cache["video"] = video
    return image, video


def _gemini_image(prompt, ssl_context):
    model, _video = _gemini_media_models(ssl_context)
    if not model:
        raise RuntimeError("This Gemini key has no image model.")
    payload = _json_request(
        "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent" % model,
        {
            "contents": [{"role": "user", "parts": [{"text": prompt}]}],
            "generationConfig": {"responseModalities": ["TEXT", "IMAGE"]},
        },
        {
            "Content-Type": "application/json",
            "x-goog-api-key": _key("GEMINI_API_KEY"),
            "User-Agent": "TigerBuild-relay/1.0",
        },
        ssl_context,
    )
    parts = (((payload.get("candidates") or [{}])[0].get("content") or {}).get("parts")) or []
    for part in parts:
        inline = part.get("inlineData") or part.get("inline_data") or {}
        encoded = inline.get("data") or ""
        if encoded:
            mime = inline.get("mimeType") or inline.get("mime_type") or "image/png"
            ext = "jpg" if "jpeg" in mime or "jpg" in mime else "png"
            return base64.b64decode(encoded), ext
    raise RuntimeError("Gemini did not return an image.")


def _gemini_video(prompt, ssl_context):
    _image, model = _gemini_media_models(ssl_context)
    if not model:
        raise RuntimeError("This Gemini key has no video model.")
    started = _json_request(
        "https://generativelanguage.googleapis.com/v1beta/models/%s:predictLongRunning" % model,
        {"instances": [{"prompt": prompt}]},
        {
            "Content-Type": "application/json",
            "x-goog-api-key": _key("GEMINI_API_KEY"),
            "User-Agent": "TigerBuild-relay/1.0",
        },
        ssl_context,
    )
    name = started.get("name") or ""
    if not name:
        raise RuntimeError("Gemini did not start a video.")
    deadline = time.time() + 180
    while time.time() < deadline:
        time.sleep(5)
        status = _json_request(
            "https://generativelanguage.googleapis.com/v1beta/" + name,
            None,
            {"x-goog-api-key": _key("GEMINI_API_KEY"), "User-Agent": "TigerBuild-relay/1.0"},
            ssl_context,
            timeout=30,
        )
        if not status.get("done"):
            continue
        if status.get("error"):
            err = status["error"]
            message = err.get("message") if isinstance(err, dict) else str(err)
            raise RuntimeError(message or "Gemini could not make the video.")
        response = status.get("response") or {}
        videos = response.get("generateVideoResponse", {}).get("generatedSamples") or response.get("videos") or []
        if videos:
            sample = videos[0]
            video = sample.get("video") or sample
            encoded = video.get("bytesBase64Encoded") or ""
            if encoded:
                return base64.b64decode(encoded), "mp4"
            uri = video.get("uri") or ""
            if uri:
                return _download(
                    uri, ssl_context, {"x-goog-api-key": _key("GEMINI_API_KEY")}
                ), "mp4"
        raise RuntimeError("Gemini finished the video without a file.")
    raise RuntimeError("The video was still rendering after three minutes.")


def _muse_image(prompt, ssl_context):
    payload = _json_request(
        "https://api.meta.ai/v1/images/generations",
        {"model": "muse-image-1.0", "prompt": prompt, "n": 1},
        {
            "Content-Type": "application/json",
            "Authorization": "Bearer " + _key("MUSE_API_KEY"),
            "User-Agent": "TigerBuild-relay/1.0",
        },
        ssl_context,
    )
    data = (payload.get("data") or [{}])[0]
    if data.get("b64_json"):
        return base64.b64decode(data["b64_json"]), "png"
    if data.get("url"):
        return _download(data["url"], ssl_context), "png"
    raise RuntimeError("Muse did not return an image.")


def create_media(provider, name, prompt, ssl_context):
    prompt = (prompt or "").strip()
    if not prompt:
        raise RuntimeError("Say what the picture or video should show.")
    if name == "generate_image":
        if provider == "grok":
            data, ext = _grok_image(prompt, ssl_context)
        elif provider == "chatgpt":
            data, ext = _openai_image(prompt, ssl_context)
        elif provider == "gemini":
            data, ext = _gemini_image(prompt, ssl_context)
        elif provider == "muse":
            data, ext = _muse_image(prompt, ssl_context)
        else:
            raise RuntimeError("This model cannot generate images.")
        kind = "image"
    elif name == "generate_video":
        if provider == "grok":
            data, ext = _grok_video(prompt, ssl_context)
        elif provider == "chatgpt":
            data, ext = _openai_video(prompt, ssl_context)
        elif provider == "gemini":
            data, ext = _gemini_video(prompt, ssl_context)
        else:
            raise RuntimeError("This model cannot generate videos.")
        kind = "video"
    else:
        raise RuntimeError("Unknown media tool.")
    if not data:
        raise RuntimeError("The media service returned an empty file.")
    filename = save_bytes(data, ext)
    return {"kind": kind, "filename": filename}


def prune_media(days=3):
    """Delete files in the media folder older than this many days. The client downloads a
    picture or file as soon as it is made, so the relay's copy is only a hand-off."""
    import time
    folder = media_dir()
    cutoff = time.time() - days * 86400
    removed = 0
    for name in os.listdir(folder):
        path = os.path.join(folder, name)
        try:
            if os.path.isfile(path) and os.path.getmtime(path) < cutoff:
                os.remove(path)
                removed += 1
        except OSError:
            pass
    return removed
