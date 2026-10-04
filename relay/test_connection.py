"""Tiger Mac connection settings, SSH key handling and error diagnosis."""
import os
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import connection
import security


class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.home, True)
        self.config = os.path.join(self.home, "config.sh")
        with open(self.config, "w") as handle:
            handle.write('# comment\nTIGER_HOST=""\nTIGER_USER=""\nLISTEN_PORT="8765"\nREMOTE_COMMANDER=\'$HOME/ppc-commander/ppc_commander.py\'\n')
        env = patch.dict(os.environ, {"TIGERBUILD_RELAY_HOME": self.home, "TIGERBUILD_RELAY_CONFIG": self.config})
        env.start()
        self.addCleanup(env.stop)

    def test_update_keeps_other_lines(self):
        config = connection.update_config({"TIGER_HOST": "10.0.1.23", "TIGER_USER": "jr"})
        self.assertEqual(config["TIGER_HOST"], "10.0.1.23")
        self.assertEqual(config["TIGER_USER"], "jr")
        text = open(self.config).read()
        self.assertIn("LISTEN_PORT=", text)
        self.assertIn("# comment", text)
        self.assertIn("$HOME/ppc-commander", text)
        if sys.platform != "win32":  # Windows has no POSIX file modes
            self.assertEqual(oct(os.stat(self.config).st_mode & 0o777), "0o600")

    def test_update_adds_missing_home(self):
        config = connection.update_config({"TIGER_HOME": "/Users/jr/"})
        self.assertEqual(config["TIGER_HOME"], "/Users/jr")

    def test_rejects_bad_values(self):
        for name, value in (("TIGER_HOST", "bad host"), ("TIGER_HOST", "a;b"), ("TIGER_USER", "j r"),
                            ("TIGER_HOME", "relative"), ("TIGER_HOME", "/a/../b")):
            with self.assertRaises(ValueError):
                connection.update_config({name: value})
        with self.assertRaises(ValueError):
            connection.update_config({"LISTEN_PORT": "1"})

    def test_blank_removes_value(self):
        connection.update_config({"TIGER_HOST": "h1"})
        self.assertEqual(connection.update_config({"TIGER_HOST": ""})["TIGER_HOST"], "")

    def test_listen_and_allowed_without_tiger_mac(self):
        config = connection.load_shell_config()
        allowed = security.allowed_clients(config)
        self.assertTrue(security.client_allowed("192.168.1.50", allowed))
        self.assertTrue(security.client_allowed("10.0.1.23", allowed))
        self.assertFalse(security.client_allowed("8.8.8.8", allowed))
        connection.update_config({"TIGER_HOST": "10.0.1.23"})
        allowed = security.allowed_clients(connection.load_shell_config())
        self.assertTrue(security.client_allowed("10.0.1.23", allowed))
        self.assertFalse(security.client_allowed("10.0.1.99", allowed))


class PerClientTests(SettingsTests):
    """Commander runs on the Mac that is chatting, never on another one."""

    def test_registered_client_uses_its_own_account(self):
        connection.update_config({"TIGER_HOST": "10.0.1.23", "TIGER_USER": "jr"})
        connection.register_client("10.0.1.129", "alice", "/Users/alice")
        base = connection.load_shell_config()
        mine = connection.target_config(base, "10.0.1.129")
        self.assertEqual((mine["TIGER_HOST"], mine["TIGER_USER"], mine["TIGER_HOME"]), ("10.0.1.129", "alice", "/Users/alice"))
        default = connection.target_config(base, "10.0.1.23")
        self.assertEqual((default["TIGER_HOST"], default["TIGER_USER"]), ("10.0.1.23", "jr"))

    def test_unconnected_client_gets_nothing(self):
        connection.update_config({"TIGER_HOST": "10.0.1.23", "TIGER_USER": "jr"})
        self.assertIsNone(connection.target_config(connection.load_shell_config(), "10.0.1.77"))

    def test_relay_computer_itself_uses_the_default(self):
        connection.update_config({"TIGER_HOST": "10.0.1.23", "TIGER_USER": "jr"})
        self.assertEqual(connection.target_config(connection.load_shell_config(), "127.0.0.1")["TIGER_HOST"], "10.0.1.23")

    def test_client_can_aim_its_tools_at_another_host(self):
        connection.register_client("10.0.1.129", "alice", "", host="10.0.1.200")
        self.assertEqual(connection.target_config(connection.load_shell_config(), "10.0.1.129")["TIGER_HOST"], "10.0.1.200")

    def test_bad_registration_rejected(self):
        with self.assertRaises(ValueError):
            connection.register_client("10.0.1.129", "bad user")
        with self.assertRaises(ValueError):
            connection.register_client("", "alice")

    def test_session_for_unconnected_client_is_offline_and_never_runs_tools(self):
        import chat_proxy as C
        connection.update_config({"TIGER_HOST": "10.0.1.23", "TIGER_USER": "jr"})
        calls = []
        with patch.object(C, "McpClient", lambda command: calls.append(command)):
            session = C.ToolSession(None, None, "10.0.1.77")
            self.assertEqual(session.definitions(), [])
            self.assertEqual(session.offline_code, "unlinked")
            self.assertIn("Connect Commander over SSH", session.offline)
        self.assertEqual(calls, [])

    def test_connected_clients_stay_allowed(self):
        import chat_proxy as C
        connection.update_config({"TIGER_HOST": "10.0.1.23", "TIGER_USER": "jr"})
        connection.register_client("10.0.1.129", "alice")
        self.assertIn("10.0.1.129", C.reload_allowed(connection.load_shell_config()))


class DiagnoseTests(unittest.TestCase):
    CONFIG = {"TIGER_HOST": "h", "TIGER_USER": "u", "REMOTE_COMMANDER": "x"}

    def code(self, text, exc=None, config=None):
        return connection.diagnose(text, exc, config or self.CONFIG)[0]

    def test_known_failures(self):
        cases = {
            "jr@h: Permission denied (publickey,password).": "auth",
            "ssh: connect to host h port 22: Connection refused": "refused",
            "ssh: connect to host h port 22: No route to host": "unreachable",
            "ssh: connect to host h port 22: Operation timed out": "timeout",
            "ssh: Could not resolve hostname h": "dns",
            "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@": "host_key_changed",
            "Host key verification failed.": "host_key_changed",
            "Unable to negotiate with h: no matching key exchange method found": "kex",
            "Warning: Identity file /x not accessible: No such file or directory.": "key_missing",
            "Commander is stopped. Choose Commander > Start in Tiger Build.": "stopped",
        }
        for text, code in cases.items():
            self.assertEqual(self.code(text), code, text)

    def test_unset(self):
        self.assertEqual(self.code("", None, {"TIGER_HOST": "", "TIGER_USER": ""}), "unset")

    def test_unknown_keeps_last_line(self):
        code, message = connection.diagnose("odd\nlast words", None, self.CONFIG)
        self.assertEqual((code, message), ("", "last words"))

    def test_closed_without_output(self):
        code, message = connection.diagnose("", Exception("the Tiger Mac closed the connection"), self.CONFIG)
        self.assertEqual(code, "closed")
        self.assertIn("ppc-commander", message)

    def test_messages_say_how_to_fix(self):
        self.assertIn("Connect Commander over SSH", connection.diagnose("Permission denied", None, self.CONFIG)[1])
        self.assertIn("Remote Login", connection.diagnose("Connection refused", None, self.CONFIG)[1])


if __name__ == "__main__":
    unittest.main()
