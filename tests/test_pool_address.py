#!/usr/bin/env python3
"""CPU-only regression for the HiveOS bare pool address startup failure."""
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("proxy", Path(__file__).resolve().parents[1] / "hiveos/stratum-replay-proxy.py")
proxy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proxy)

class PoolAddressTests(unittest.TestCase):
    def test_supported_addresses(self):
        cases = [
            ("stratum-eu.pepepow.foztor.net:13232", ("stratum-eu.pepepow.foztor.net", 13232)),
            ("stratum+tcp://example.invalid:1234", ("example.invalid", 1234)),
            ("  example.invalid:1234  ", ("example.invalid", 1234)),
            ("127.0.0.1:49333", ("127.0.0.1", 49333)),
            ("[::1]:1234", ("::1", 1234)),
            ("stratum+tcp://[::1]:1234/", ("::1", 1234)),
        ]
        for value, expected in cases:
            with self.subTest(value=value):
                self.assertEqual(proxy.parse_pool(value), expected)

    def test_invalid_addresses(self):
        cases = ["", "host", "host:0", "host:65536", "host:abc",
                 "https://host:1234", "stratum+ssl://host:1234",
                 "host:1234/path", "host:1234?x=y", "host:1234#x",
                 "user:secret@host:1234", "ho st:1234", "[::1:1234"]
        for value in cases:
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    proxy.parse_pool(value)

if __name__ == "__main__":
    unittest.main()
