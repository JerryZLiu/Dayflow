from __future__ import annotations

import unittest
from datetime import date

from dayflow_windows.ai import _normalize_cards, _parse_ai_json, _timeline_context
from dayflow_windows.models import AITimelineCard


class AITests(unittest.TestCase):
    def test_parse_ai_json_with_wrapped_text(self) -> None:
        raw = "Here is result:\n{\"cards\": [], \"daily_summary\": \"ok\"}\n"
        parsed = _parse_ai_json(raw)
        self.assertEqual(parsed["daily_summary"], "ok")

    def test_normalize_cards_filters_invalid(self) -> None:
        cards = _normalize_cards(
            [
                {"start": "09:00", "end": "09:30", "title": "Work", "summary": "x", "category": "Coding"},
                {"start": "bad", "end": "09:30", "title": "Bad", "summary": "", "category": "Other"},
            ]
        )
        self.assertEqual(len(cards), 1)
        self.assertEqual(cards[0]["title"], "Work")

    def test_timeline_context_includes_captured_evidence(self) -> None:
        card = AITimelineCard(
            id=1,
            day="2026-02-11",
            start="09:00",
            end="09:30",
            title="Coding",
            summary="Implemented API handling",
            category="Coding",
        )
        ctx = _timeline_context(
            day=date(2026, 2, 11),
            cards=[card],
            daily_summary="Strong morning focus.",
            captured_timeline=["2026-02-11 9:00 AM-9:30 AM [Code] dayflow_windows/app.py"],
            range_label="2026-02-11 to 2026-02-11",
        )
        self.assertIn("Date range: 2026-02-11 to 2026-02-11", ctx)
        self.assertIn("Timeline cards:", ctx)
        self.assertIn("Captured timeline evidence:", ctx)
        self.assertIn("Strong morning focus.", ctx)

    def test_timeline_context_reports_missing_sources(self) -> None:
        ctx = _timeline_context(
            day=date(2026, 2, 11),
            cards=[],
            daily_summary="",
            captured_timeline=[],
            range_label="2026-02-11",
        )
        self.assertIn("No AI cards are available yet.", ctx)
        self.assertIn("No captured timeline evidence was provided.", ctx)


if __name__ == "__main__":
    unittest.main()
