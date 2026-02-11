from __future__ import annotations

from datetime import timedelta
from typing import Sequence

from .models import ScreenshotRecord, TimelineCard


def build_timeline_cards(
    records: Sequence[ScreenshotRecord],
    fallback_interval_seconds: float = 10.0,
) -> list[TimelineCard]:
    if not records:
        return []

    ordered = sorted(records, key=lambda row: row.captured_at)
    fallback = max(1, int(round(fallback_interval_seconds)))
    max_gap = max(30, fallback * 2)
    merge_tolerance = timedelta(seconds=5)

    grouped: list[dict[str, object]] = []
    for index, record in enumerate(ordered):
        start = record.captured_at
        next_timestamp = ordered[index + 1].captured_at if index + 1 < len(ordered) else None
        segment_seconds = _segment_duration_seconds(start, next_timestamp, fallback, max_gap)
        end = start + timedelta(seconds=segment_seconds)

        process_name = (record.process_name or "").strip() or "unknown"
        window_title = (record.window_title or "").strip() or "Unknown Window"
        key = (_normalize(process_name), _normalize(window_title))

        if grouped and grouped[-1]["key"] == key and start <= grouped[-1]["end"] + merge_tolerance:
            grouped[-1]["end"] = max(grouped[-1]["end"], end)
            grouped[-1]["screenshot_count"] = int(grouped[-1]["screenshot_count"]) + 1
            continue

        grouped.append(
            {
                "key": key,
                "start": start,
                "end": end,
                "process_name": process_name,
                "window_title": window_title,
                "screenshot_count": 1,
            }
        )

    cards: list[TimelineCard] = []
    for group in grouped:
        start = group["start"]
        end = group["end"]
        duration_seconds = max(1, int(round((end - start).total_seconds())))
        cards.append(
            TimelineCard(
                start=start,
                end=end,
                duration_seconds=duration_seconds,
                process_name=str(group["process_name"]),
                window_title=str(group["window_title"]),
                screenshot_count=int(group["screenshot_count"]),
            )
        )

    return cards


def format_duration(total_seconds: int) -> str:
    seconds = max(0, int(total_seconds))
    hours, remainder = divmod(seconds, 3600)
    minutes, secs = divmod(remainder, 60)

    if hours:
        return f"{hours}h {minutes:02d}m"
    if minutes:
        return f"{minutes}m {secs:02d}s"
    return f"{secs}s"


def _segment_duration_seconds(
    start,
    next_timestamp,
    fallback: int,
    max_gap: int,
) -> int:
    if next_timestamp is None:
        return fallback

    raw_seconds = int((next_timestamp - start).total_seconds())
    if raw_seconds <= 0:
        return fallback
    return min(raw_seconds, max_gap)


def _normalize(value: str) -> str:
    return " ".join(value.lower().split())
