import os, tempfile, time, unittest
import providers as P
import media


class CachingTests(unittest.TestCase):
    def test_marks_system_and_last_block(self):
        messages = [{"role": "user", "content": "first"}, {"role": "assistant", "content": "ok"}, {"role": "user", "content": "second"}]
        system = P.claude_cache_marks("be nice", messages)
        self.assertEqual(system[0]["cache_control"], {"type": "ephemeral"})
        self.assertEqual(messages[-1]["content"][-1]["cache_control"], {"type": "ephemeral"})
        self.assertEqual(messages[0]["content"], "first")

    def test_big_prompts_get_the_one_hour_cache(self):
        big = [{"role": "user", "content": "x" * 70000}]
        small = [{"role": "user", "content": "hi"}]
        self.assertEqual(P.claude_cache_marks("s", big)[0]["cache_control"], {"type": "ephemeral", "ttl": "1h"})
        self.assertEqual(big[-1]["content"][-1]["cache_control"]["ttl"], "1h")
        self.assertEqual(P.claude_cache_marks("s", small)[0]["cache_control"], {"type": "ephemeral"})

    def test_tool_result_and_empty_messages(self):
        blocks = [{"type": "tool_result", "tool_use_id": "x", "content": "out"}]
        P.claude_cache_marks("s", [{"role": "user", "content": blocks}])
        self.assertIn("cache_control", blocks[-1])
        empty = [{"type": "text", "text": "  "}]
        P.claude_cache_marks("s", [{"role": "user", "content": empty}])
        self.assertNotIn("cache_control", empty[-1])
        self.assertEqual(P.claude_cache_marks("", []), "")

    def test_marks_can_be_removed(self):
        messages = [{"role": "user", "content": "hi"}]
        payload = {"system": P.claude_cache_marks("sys", messages), "messages": messages}
        P._without_cache_marks(payload)
        self.assertEqual(payload["system"], "sys")
        self.assertNotIn("cache_control", payload["messages"][0]["content"][0])

    def test_media_pruning_keeps_new_files(self):
        with tempfile.TemporaryDirectory() as folder:
            old = media.media_dir
            media.media_dir = lambda: folder
            try:
                for name, age in (("old.jpg", 5), ("new.jpg", 0)):
                    path = os.path.join(folder, name)
                    open(path, "w").write("x")
                    stamp = time.time() - age * 86400
                    os.utime(path, (stamp, stamp))
                self.assertEqual(media.prune_media(3), 1)
                self.assertEqual(os.listdir(folder), ["new.jpg"])
            finally:
                media.media_dir = old


if __name__ == "__main__":
    unittest.main()
