"""Local model servers: Ollama (no /api/v0/models) and LM Studio (has it). A tiny fake server answers each."""
import json
import os
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

import app_config


def serve(routes):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self):
            body = routes.get(self.path)
            if body is None:
                self.send_response(404)
                self.end_headers()
                return
            data = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        do_GET = do_POST = reply

    server = HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


class LocalServerTests(unittest.TestCase):
    def listed(self, routes):
        server = serve(routes)
        old = os.environ.get("LOCAL_MODEL_URL")
        os.environ["LOCAL_MODEL_URL"] = "http://127.0.0.1:%d" % server.server_address[1]
        app_config._ollama_context_cache.clear()
        try:
            return {m["id"]: m["context"] for m in app_config.list_local_models(3)}
        finally:
            server.shutdown()
            if old is None:
                os.environ.pop("LOCAL_MODEL_URL", None)
            else:
                os.environ["LOCAL_MODEL_URL"] = old

    def test_ollama_contexts_and_embeddings_skipped(self):
        models = self.listed({
            "/v1/models": {"data": [{"id": "llama3.1:8b"}, {"id": "qwen3:30b"}, {"id": "nomic-embed-text:latest"}]},
            "/api/ps": {"models": [{"name": "qwen3:30b", "context_length": 8192}]},
            "/api/show": {"model_info": {"llama.context_length": 131072}},
        })
        self.assertEqual(models, {"llama3.1:8b": 131072, "qwen3:30b": 8192})

    def test_lm_studio_uses_its_own_limits(self):
        models = self.listed({
            "/v1/models": {"data": [{"id": "a/b"}, {"id": "text-embedding-x"}]},
            "/api/v0/models": {"data": [{"id": "a/b", "type": "llm", "max_context_length": 65536},
                                         {"id": "text-embedding-x", "type": "embeddings"}]},
        })
        self.assertEqual(models, {"a/b": 65536})

    def test_server_without_either_keeps_the_default(self):
        models = self.listed({"/v1/models": {"data": [{"id": "plain"}]}})
        self.assertEqual(models, {"plain": 32768})


if __name__ == "__main__":
    unittest.main()
