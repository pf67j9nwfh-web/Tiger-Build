import os, unittest
from unittest.mock import patch
import transcribe as T

WAV = b"RIFF" + b"\x24\x00\x00\x00" + b"WAVE" + b"fmt " + b"\x00" * 200


class TranscribeTests(unittest.TestCase):
    def test_multipart_shape(self):
        body, kind = T.multipart([("model", "m"), ("language", "en")], "speech.wav", b"DATA", "audio/wav")
        boundary = kind.split("boundary=")[1].encode()
        self.assertIn(b'name="model"\r\n\r\nm\r\n', body)
        self.assertIn(b'filename="speech.wav"', body)
        self.assertIn(b"DATA\r\n--" + boundary + b"--", body)

    def test_bad_clips_and_no_keys(self):
        with patch.dict(os.environ, {"OPENAI_API_KEY": "", "MISTRAL_API_KEY": "", "GEMINI_API_KEY": "", "GOOGLE_API_KEY": ""}):
            self.assertEqual(T.available(), [])
            with self.assertRaises(T.NoService):
                T.transcribe(WAV, None)
        with self.assertRaises(ValueError):
            T.transcribe(b"not audio at all", None)
        with self.assertRaises(ValueError):
            T.transcribe(b"RIFF" + b"\0" * 4 + b"WAVE" + b"x" * (T.MAX_BYTES + 1), None)

    def test_service_order_and_fallback(self):
        env = {"OPENAI_API_KEY": "a", "MISTRAL_API_KEY": "b", "GEMINI_API_KEY": "c"}
        with patch.dict(os.environ, env):
            self.assertEqual(T.available(), ["openai", "mistral", "gemini"])
            calls = []

            def fake(url, key, models, data, context, language):
                calls.append(url)
                if url == T.OPENAI_URL:
                    raise RuntimeError("HTTP 429: busy")
                return " hello there "
            with patch.object(T, "_multipart_service", fake):
                text, service = T.transcribe(WAV, None)
            self.assertEqual((text, service), (" hello there ", "Mistral"))
            self.assertEqual(calls, [T.OPENAI_URL, T.MISTRAL_URL])

    def test_model_ids_tried_in_turn(self):
        seen = []

        def fake_post(url, body, headers, context, timeout=120):
            seen.append(body)
            if len(seen) == 1:
                raise RuntimeError("HTTP 404: no such model")
            return {"text": " words "}
        with patch.object(T, "_post", fake_post):
            self.assertEqual(T._multipart_service(T.OPENAI_URL, "k", ("one", "two"), WAV, None, ""), "words")
        self.assertIn(b"two", seen[1])


if __name__ == "__main__":
    unittest.main()
