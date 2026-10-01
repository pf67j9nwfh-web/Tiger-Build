"""Small checks for the 1.2 audit fixes. No network and no secrets."""
import os
import tempfile
import unittest

from app_config import targets_this_relay
from paths import config_sh


class LocalUrlTests(unittest.TestCase):
    def test_other_host_is_allowed(self):
        self.assertFalse(targets_this_relay(
            "http://10.0.1.105:1234/v1", "10.0.1.213", 8765
        ))

    def test_same_computer_other_port_is_allowed(self):
        self.assertFalse(targets_this_relay(
            "http://10.0.1.213:1234/v1", "10.0.1.213", 8765
        ))

    def test_loopback_other_port_is_allowed(self):
        self.assertFalse(targets_this_relay(
            "http://127.0.0.1:1234/v1", "10.0.1.213", 8765
        ))

    def test_relay_address_is_rejected(self):
        self.assertTrue(targets_this_relay(
            "http://10.0.1.213:8765/v1", "10.0.1.213", 8765
        ))

    def test_loopback_on_the_relay_port_is_rejected(self):
        self.assertTrue(targets_this_relay(
            "http://127.0.0.1:8765/v1", "10.0.1.213", 8765
        ))

    def test_wildcard_does_not_reject_another_host(self):
        self.assertFalse(targets_this_relay(
            "http://10.0.1.105:8765/v1", "0.0.0.0", 8765
        ))


class ConfigPathTests(unittest.TestCase):
    def test_explicit_config_wins(self):
        folder = tempfile.mkdtemp()
        chosen = os.path.join(folder, "chosen.sh")
        old = os.environ.get("TIGERBUILD_RELAY_CONFIG")
        os.environ["TIGERBUILD_RELAY_CONFIG"] = chosen
        try:
            self.assertEqual(config_sh(), chosen)
        finally:
            if old is None:
                os.environ.pop("TIGERBUILD_RELAY_CONFIG", None)
            else:
                os.environ["TIGERBUILD_RELAY_CONFIG"] = old


if __name__ == "__main__":
    unittest.main()
