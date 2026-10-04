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
        self.fakebin = os.path.join(self.home, "bin")
        os.mkdir(self.fakebin)
        sample = {"nearest_area": [{"areaName": [{"value": "Chicago"}], "region": [{"value": "Illinois"}], "country": [{"value": "United States"}]}],
                  "current_condition": [{"temp_F": "70", "temp_C": "21", "FeelsLikeF": "65", "FeelsLikeC": "18", "humidity": "48", "windspeedMiles": "9",
                                         "windspeedKmph": "14", "winddir16Point": "N", "uvIndex": "4", "precipInches": "0.0", "weatherDesc": [{"value": "Sunny"}]}],
                  "weather": [{"date": "2026-10-04", "maxtempF": "70", "maxtempC": "21", "mintempF": "58", "mintempC": "14",
                               "astronomy": [{"sunrise": "06:51 AM", "sunset": "06:27 PM"}],
                               "hourly": [{"chanceofrain": "2", "weatherDesc": [{"value": "Clear"}]}] * 4 + [{"chanceofrain": "30", "weatherDesc": [{"value": "Partly cloudy"}]}]}]}
        with open(os.path.join(self.home, "weather.json"), "w") as handle:
            json.dump(sample, handle)
        with open(os.path.join(self.fakebin, "curl"), "w") as handle:
            handle.write('#!/bin/sh\ncase "$*" in *Nowhere*) echo "Unknown location" >&2; exit 22;; esac\ncat "%s"\n' % os.path.join(self.home, "weather.json"))
        os.chmod(os.path.join(self.fakebin, "curl"), 0o755)
        servers = [
            {"id": "calc", "title": "Calculator", "command": sys.executable, "args": [os.path.join(EXAMPLES, "mcp_calc.py")], "env": {}, "enabled": True},
            {"id": "notes", "title": "Notebook", "command": sys.executable, "args": [os.path.join(EXAMPLES, "mcp_notes.py")],
             "env": {"MCP_NOTES_FILE": os.path.join(self.home, "notes.json")}, "enabled": True, "approval": True},
            {"id": "sysinfo", "title": "System info", "command": sys.executable, "args": [os.path.join(EXAMPLES, "mcp_sysinfo.py")], "env": {}, "enabled": True},
            {"id": "weather", "title": "Weather", "command": sys.executable, "args": [os.path.join(EXAMPLES, "mcp_weather.py")],
             "env": {"PATH": self.fakebin + os.pathsep + os.environ.get("PATH", "")}, "enabled": True},
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

    @unittest.skipIf(sys.platform == "win32", "the stand-in curl is a shell script")
    def test_weather_through_curl(self):
        text = self.conn.call("mcp_weather_current_weather", {"place": "Chicago"})
        self.assertIn("Chicago, Illinois, United States: Sunny, 70\u00b0F (21\u00b0C)", text)
        plan = self.conn.call("mcp_weather_forecast", {"place": "Chicago", "days": 1})
        self.assertIn("2026-10-04: Partly cloudy, high 70\u00b0F (21\u00b0C), low 58\u00b0F (14\u00b0C), rain chance up to 30%", plan)
        with self.assertRaises(RuntimeError) as failed:
            self.conn.call("mcp_weather_forecast", {"place": "Nowhere"})
        self.assertIn("Unknown location", str(failed.exception))

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


class ExampleInstallTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.home, True)
        env = patch.dict(os.environ, {"TIGERBUILD_RELAY_HOME": self.home})
        env.start()
        self.addCleanup(env.stop)

    def test_added_once_and_removal_sticks(self):
        self.assertTrue(I.install_examples(EXAMPLES, sys.executable))
        servers = I.read()["servers"]
        self.assertEqual([s["id"] for s in servers], ["calc", "notes", "sysinfo", "weather"])
        self.assertTrue(all(s["enabled"] for s in servers))
        self.assertTrue(servers[1]["approval"])
        config = I.read()
        config["servers"] = [s for s in config["servers"] if s["id"] != "weather"]
        I.write(config)
        self.assertFalse(I.install_examples(EXAMPLES, sys.executable))
        self.assertEqual([s["id"] for s in I.read()["servers"]], ["calc", "notes", "sysinfo"])

    def test_saving_settings_without_the_flag_keeps_it(self):
        I.install_examples(EXAMPLES, sys.executable)
        config = I.read()
        del config["examples_installed"]
        I.write(config)
        self.assertTrue(I.read()["examples_installed"])
