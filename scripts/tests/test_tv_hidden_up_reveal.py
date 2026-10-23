"""Source-order contract, not rendered UI or physical remote-latency evidence."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
PLAYER = ROOT / "app/SourcesTV/TVPlayerView.swift"
START = "    private func handlePress(_ type: UIPress.PressType) {"
END = '    /// True for an IMDb tt####### title'
FAST = """            if type == .upArrow {
                showControls()
                return
            }
"""


def contract(source):
    if source.count(START) != 1 or source.count(END) != 1:
        raise ValueError("Remote handler anchors changed")
    body = source.split(START, 1)[1].split(END, 1)[0]
    # These are fixed source anchors, not a general Swift parser. Comments are
    # ignored only inside this source-contract boundary, never executed as code.
    code = re.sub(r"//[^\n]*", "", body)
    hidden = "        if controlsHidden {"
    if code.count(hidden) != 1:
        raise ValueError("Expected one hidden-controls input branch")
    before, after = code.split(hidden, 1)
    guards = ["if stillWatching {", "if showStreamQR {", "if refinding {",
              "if loadFailed {", "if showOptions {"]
    indices = [before.index(guard) for guard in guards]
    if indices != sorted(indices):
        raise ValueError("Original modal/failure/panel ordering changed")
    if "if type == .upArrow {" in before:
        raise ValueError("Up may not bypass original input owners")
    immediate = re.match(r"\s*if type == \.upArrow\s*\{\s*showControls\(\)\s*return\s*\}", after)
    if immediate is None:
        raise ValueError("Hidden Up must reveal and return before prompt getters")
    remainder = after[immediate.end():]
    if "if upNextRemaining != nil || isCreditsUpNext {" not in remainder:
        raise ValueError("Original Up Next prompt input owner missing")
    if "if let seg = skipPillSegment, autoSkipRemaining(for: seg) != nil {" not in remainder:
        raise ValueError("Original skip prompt input owner missing")
    if "case .upArrow: vertical(-1)" not in remainder:
        raise ValueError("Visible Up navigation missing")


class HiddenUpRevealContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = PLAYER.read_text()
        if cls.source.count(FAST) != 1:
            raise ValueError("Expected exact single fast path in actual source")

    def test_actual_hidden_up_precedes_prompt_episode_inventory(self):
        contract(self.source)

    def test_rejects_original_expensive_fallthrough(self):
        with self.assertRaises(ValueError):
            contract(self.source.replace(FAST, "", 1))

    def test_rejects_moving_fast_path_after_up_next_lookup(self):
        mutant = self.source.replace(FAST, "", 1).replace(
            "            if upNextRemaining != nil || isCreditsUpNext {",
            "            if upNextRemaining != nil || isCreditsUpNext {\n" + FAST, 1)
        with self.assertRaises(ValueError):
            contract(mutant)

    def test_rejects_consuming_down_instead_of_up(self):
        with self.assertRaises(ValueError):
            contract(self.source.replace(FAST, FAST.replace(".upArrow", ".downArrow"), 1))

    def test_rejects_reveal_without_return(self):
        with self.assertRaises(ValueError):
            contract(self.source.replace(FAST, FAST.replace("                return\n", ""), 1))

    def test_rejects_fast_path_before_original_input_owners(self):
        mutant = self.source.replace(FAST, "", 1).replace(START, START + "\n" + FAST, 1)
        with self.assertRaises(ValueError):
            contract(mutant)


if __name__ == "__main__":
    unittest.main()
