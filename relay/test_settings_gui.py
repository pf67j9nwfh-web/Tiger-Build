"""The Tk settings window (Windows and Linux): it must build and fill its fields."""
import os
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


class SettingsWindowTests(unittest.TestCase):
    def setUp(self):
        try:
            import tkinter
            root = tkinter.Tk()
            root.destroy()
        except Exception:
            self.skipTest("no display for Tk")
        self.home = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.home, True)
        relay = os.path.join(self.home, "app", "relay")
        os.makedirs(relay)
        for name in os.listdir(os.path.dirname(os.path.abspath(__file__))):
            if name.endswith(".py") and not name.startswith("test_"):
                shutil.copy(os.path.join(os.path.dirname(os.path.abspath(__file__)), name), relay)
        env = patch.dict(os.environ, {"TIGERBUILD_RELAY_HOME": self.home})
        env.start()
        self.addCleanup(env.stop)

    def test_window_builds_and_shows_every_key_row_and_the_macs_tab(self):
        import tkinter
        import settings_gui
        seen = {}
        real = tkinter.Tk.mainloop

        def short_loop(root, n=0):
            for _ in range(60):
                root.update()
                import time
                time.sleep(0.05)
            labels = []

            def walk(widget):
                for child in widget.winfo_children():
                    try:
                        labels.append(str(child.cget("text")))
                    except Exception:
                        pass
                    walk(child)
            walk(root)
            seen["labels"] = labels
            root.destroy()

        with patch.object(tkinter.Tk, "mainloop", short_loop):
            self.assertEqual(settings_gui.main(), 0)
        text = "\n".join(seen["labels"])
        for expected in ("xAI / Grok", "Local LLM server URL", "Local API key (optional)", "Save and Test", "Remove"):
            self.assertIn(expected, text)


if __name__ == "__main__":
    unittest.main()
