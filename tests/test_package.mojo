"""The package parses and imports on both toolchains — the baseline every
module-level suite builds on."""
from std.testing import TestSuite, assert_true
import postgres


def test_package_imports() raises:
    assert_true(True)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
