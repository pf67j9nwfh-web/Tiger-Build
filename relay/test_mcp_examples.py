"""The example MCP servers in docs/mcp-examples, run through the relay's own
custom-server code (stdlib only, so no network is needed)."""
import json
import os
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import integrations as I

EXAMPLES = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "mcp-examples")


class ExampleServerTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.home, True)
        env = patch.dict(os.environ, {"TIGERBUILD_RELAY_HOME": self.home})
        env.start()
        self.addCleanup(env.stop)
        servers = [
            {"id": "calc", "title": "Calculator", "command": sys.executable, "args": [os.path.join(EXAMPLES, "mcp_calc.py")], "env": {}, "enabled": True},
            {"id": "notes", "title": "Notebook", "command": sys.executable, "args": [os.path.join(EXAMPLES, "mcp_notes.py")],
             "env": {"MCP_NOTES_FILE": os.path.join(self.home, "notes.json")}, "enabled": True, "approval": True},
            {"id": "sysinfo", "title": "System info", "command": sys.executable, "args": [os.path.join(EXAMPLES, "mcp_sysinfo.py")], "env": {}, "enabled": True},
            {"id": "off", "title": "Off", "command": sys.executable, "args": [os.path.join(EXAMPLES, "mcp_calc.py")], "env": {}, "enabled": False},
        ]
        I.write({"servers": servers, "ppc_enabled": False})
        self.conn = I.Connections()
        self.tools = self.conn.definitions("claude")
        self.addCleanup(self.conn.close)

    def test_tools_listed_and_owned(self):
        names = [tool["name"] for tool in self.tools]
        self.assertIn("mcp_calc_calculate", names)
        self.assertIn("mcp_notes_note_set", names)
        self.assertIn("mcp_sysinfo_host_info", names)
        self.assertFalse([n for n in names if n.startswith("mcp_off_")])
        self.assertEqual(self.conn.owners["mcp_calc_calculate"], "mcp_calc")
        self.assertEqual(self.conn.errors, [])

    def test_per_chat_skip(self):
        other = I.Connections()
        try:
            names = [tool["name"] for tool in other.definitions("claude", skip={"mcp_calc"})]
        finally:
            other.close()
        self.assertFalse([n for n in names if n.startswith("mcp_calc_")])
        self.assertIn("mcp_notes_note_get", names)

    def test_approval_defaults(self):
        self.assertTrue(self.conn.approval_default("mcp_notes"))
        self.assertFalse(self.conn.approval_default("mcp_calc"))

    def test_calculator(self):
        self.assertEqual(self.conn.call("mcp_calc_calculate", {"expression": "2**10+1"}), "2**10+1 = 1025")
        with self.assertRaises(RuntimeError):
            self.conn.call("mcp_calc_calculate", {"expression": "__import__('os').system('x')"})
        self.assertIn("212", self.conn.call("mcp_calc_convert_units", {"value": 100, "from": "C", "to": "F"}))

    def test_notebook_roundtrip(self):
        self.conn.call("mcp_notes_note_set", {"title": "a", "text": "milk"})
        self.assertEqual(self.conn.call("mcp_notes_note_get", {"title": "a"}), "milk")
        self.assertIn("a: milk", self.conn.call("mcp_notes_note_list", {}))
        self.conn.call("mcp_notes_note_delete", {"title": "a"})
        with self.assertRaises(RuntimeError):
            self.conn.call("mcp_notes_note_get", {"title": "a"})

    def test_failing_tool_reports_error(self):
        with self.assertRaises(RuntimeError) as caught:
            self.conn.call("mcp_sysinfo_always_fails", {})
        self.assertIn("always fails", str(caught.exception))

    def test_unlisted_tool_refused(self):
        with self.assertRaises(ValueError):
            self.conn.call("mcp_off_calculate", {"expression": "1"})


if __name__ == "__main__":
    unittest.main()
