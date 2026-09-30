"""Parser edge cases for the release gate; real old/new binaries are checked separately."""

import runpy
import unittest
from pathlib import Path

gate = runpy.run_path(str(Path(__file__).with_name("verify-apple-compatibility.py")))


class AppleCompatibilityTests(unittest.TestCase):
    def commands(self, platform=2, minimum="14.0"):
        return f"cmd LC_BUILD_VERSION\n cmdsize 24\n platform {platform}\n minos {minimum}\n"

    def disassembly(self, instruction="ldar", omit=None):
        return "\n".join(
            f"0000000000000000 <{symbol}>:\n 0: c8dffc08     {instruction} x8, [x0]\n"
            for symbol in gate["ATOMIC_SYMBOLS"] if symbol != omit
        )

    def test_compatible_metadata(self):
        gate["verify_load_commands"](self.commands(), 2, "14.0", "object")

    def test_newer_os_wrong_platform_and_missing_metadata_fail(self):
        for text in (self.commands(minimum="26.5"), self.commands(platform=7), ""):
            with self.subTest(text=text), self.assertRaises(ValueError):
                gate["verify_load_commands"](text, 2, "14.0", "object")

    def test_every_universal_architecture_is_checked(self):
        with self.assertRaises(ValueError):
            gate["verify_load_commands"](
                self.commands(6) + self.commands(6, "26.5"), 6, "14.0", "universal", 2)

    def test_compatible_atomic_instructions(self):
        for mnemonic in ("ldar", "ldaxr", "stlxr", "stlr"):
            gate["verify_atomic_disassembly"](self.disassembly(mnemonic), "binary")

    def test_rcpc_and_lse_instructions_fail(self):
        for mnemonic in ("ldapr", "ldaprb", "ldapur", "ldaddal", "ldsetal", "casal", "swpal", "<unknown>"):
            with self.subTest(mnemonic=mnemonic), self.assertRaises(ValueError):
                gate["verify_atomic_disassembly"](self.disassembly(mnemonic), "binary")

    def test_missing_symbol_or_empty_disassembly_fails(self):
        for text in (self.disassembly(omit="_CRYPTO_atomic_load"), ""):
            with self.subTest(text=text), self.assertRaises(ValueError):
                gate["verify_atomic_disassembly"](text, "binary")


if __name__ == "__main__":
    unittest.main()
