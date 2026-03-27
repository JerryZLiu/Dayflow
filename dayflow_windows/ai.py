from __future__ import annotations

import base64
import json
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Any

from .models import AITimelineCard, ScreenshotRecord


@dataclass(frozen=True)
class AIGenerationResult:
    cards: list[dict[str, str]]
    daily_summary: str
    model_used: str


class AITimelineGenerator:
    def generate(
        self,
        provider: str,
        api_key: str,
        model: str,
        day: date,
        screenshots: list[ScreenshotRecord],
        endpoint: str = "",
    ) -> AIGenerationResult:
        if not screenshots:
            raise ValueError("No screenshots available for selected date.")
        if not model.strip():
            raise ValueError("Model is required.")
        if provider in {"gemini", "openai"} and not api_key.strip():
            raise ValueError("API key is required for this provider.")

        sample = _sample_screenshots(screenshots, max_items=20)
        prompt = _build_timeline_prompt(day)

        if provider == "gemini":
            parsed = self._call_gemini_json(
                api_key=api_key.strip(),
                model=model.strip(),
                prompt=prompt,
                screenshots=sample,
            )
        elif provider in {"openai", "local"}:
            parsed = self._call_openai_style_json(
                endpoint=_resolve_openai_endpoint(provider, endpoint),
                api_key=api_key.strip(),
                model=model.strip(),
                prompt=prompt,
                screenshots=sample,
                include_images=(provider == "openai"),
            )
        else:
            raise ValueError(f"Unsupported provider: {provider}")

        return AIGenerationResult(
            cards=_normalize_cards(parsed.get("cards", [])),
            daily_summary=str(parsed.get("daily_summary", "")).strip(),
            model_used=model.strip(),
        )

    def answer_dashboard_question(
        self,
        provider: str,
        api_key: str,
        model: str,
        endpoint: str,
        day: date,
        question: str,
        timeline_cards: list[AITimelineCard],
        daily_summary: str,
        captured_timeline: list[str] | None = None,
        range_label: str | None = None,
    ) -> str:
        if not question.strip():
            raise ValueError("Question cannot be empty.")
        if not model.strip():
            raise ValueError("Model is required.")
        if provider in {"gemini", "openai"} and not api_key.strip():
            raise ValueError("API key is required for this provider.")

        context = _timeline_context(
            day=day,
            cards=timeline_cards,
            daily_summary=daily_summary,
            captured_timeline=captured_timeline,
            range_label=range_label,
        )
        prompt = (
            "You are Dayflow Dashboard.\n"
            f"{context}\n"
            f"User question: {question.strip()}\n"
            "Answer concisely with practical insights based on timeline evidence. "
            "If evidence is weak, say that clearly. "
            "Never invent apps, durations, or events that are not supported by the context."
        )

        if provider == "gemini":
            parsed = self._call_gemini_text(api_key.strip(), model.strip(), prompt)
            return parsed.strip()

        if provider in {"openai", "local"}:
            parsed = self._call_openai_style_text(
                endpoint=_resolve_openai_endpoint(provider, endpoint),
                api_key=api_key.strip(),
                model=model.strip(),
                prompt=prompt,
            )
            return parsed.strip()

        raise ValueError(f"Unsupported provider: {provider}")

    def generate_journal_summary(
        self,
        provider: str,
        api_key: str,
        model: str,
        endpoint: str,
        day: date,
        intentions: str,
        reflections: str,
        timeline_cards: list[AITimelineCard],
        daily_summary: str,
    ) -> str:
        if not model.strip():
            raise ValueError("Model is required.")
        if provider in {"gemini", "openai"} and not api_key.strip():
            raise ValueError("API key is required for this provider.")

        context = _timeline_context(day, timeline_cards, daily_summary)
        prompt = (
            "Generate a journal summary for the day in 4-8 sentences.\n"
            f"{context}\n"
            f"Intentions: {intentions.strip() or '(none)'}\n"
            f"Reflections: {reflections.strip() or '(none)'}\n"
            "Output plain text only. Mention wins, misses, and one concrete next-step."
        )

        if provider == "gemini":
            return self._call_gemini_text(api_key.strip(), model.strip(), prompt).strip()
        if provider in {"openai", "local"}:
            return self._call_openai_style_text(
                endpoint=_resolve_openai_endpoint(provider, endpoint),
                api_key=api_key.strip(),
                model=model.strip(),
                prompt=prompt,
            ).strip()
        raise ValueError(f"Unsupported provider: {provider}")

    def _call_gemini_json(
        self,
        api_key: str,
        model: str,
        prompt: str,
        screenshots: list[ScreenshotRecord],
    ) -> dict[str, Any]:
        endpoint = (
            f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
            f"?key={api_key}"
        )
        parts: list[dict[str, Any]] = [{"text": prompt}]
        for row in screenshots:
            image_part = _image_part_for_gemini(Path(row.file_path))
            if image_part:
                parts.append(image_part)
            parts.append({"text": _screenshot_context_line(row)})

        payload = {
            "contents": [{"role": "user", "parts": parts}],
            "generationConfig": {"temperature": 0.2, "responseMimeType": "application/json"},
        }
        data = _http_post_json(endpoint, payload, headers={})
        text = _extract_gemini_text(data)
        return _parse_ai_json(text)

    def _call_gemini_text(self, api_key: str, model: str, prompt: str) -> str:
        endpoint = (
            f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
            f"?key={api_key}"
        )
        payload = {
            "contents": [{"role": "user", "parts": [{"text": prompt}]}],
            "generationConfig": {"temperature": 0.2},
        }
        data = _http_post_json(endpoint, payload, headers={})
        return _extract_gemini_text(data)

    def _call_openai_style_json(
        self,
        endpoint: str,
        api_key: str,
        model: str,
        prompt: str,
        screenshots: list[ScreenshotRecord],
        include_images: bool,
    ) -> dict[str, Any]:
        content: list[dict[str, Any]] = [{"type": "text", "text": prompt}]
        for row in screenshots:
            if include_images:
                data_uri = _image_data_uri(Path(row.file_path))
                if data_uri:
                    content.append({"type": "image_url", "image_url": {"url": data_uri}})
            content.append({"type": "text", "text": _screenshot_context_line(row)})

        payload = {
            "model": model,
            "temperature": 0.2,
            "messages": [{"role": "user", "content": content}],
            "response_format": {"type": "json_object"},
        }
        data = _http_post_json(
            endpoint,
            payload,
            headers=_auth_headers(api_key),
        )
        text = _extract_openai_text(data)
        return _parse_ai_json(text)

    def _call_openai_style_text(
        self,
        endpoint: str,
        api_key: str,
        model: str,
        prompt: str,
    ) -> str:
        payload = {
            "model": model,
            "temperature": 0.2,
            "messages": [{"role": "user", "content": prompt}],
        }
        data = _http_post_json(endpoint, payload, headers=_auth_headers(api_key))
        return _extract_openai_text(data)


def _build_timeline_prompt(day: date) -> str:
    return (
        "You are generating a productivity timeline from screenshots and window context.\n"
        f"Date: {day.isoformat()}\n"
        "Return strict JSON with this shape only:\n"
        "{"
        "\"cards\": [{\"start\":\"HH:MM\",\"end\":\"HH:MM\",\"title\":\"...\",\"summary\":\"...\",\"category\":\"...\"}],"
        "\"daily_summary\":\"...\""
        "}\n"
        "Rules:\n"
        "- 4 to 16 cards depending on activity changes.\n"
        "- Times must be local day time in HH:MM 24h.\n"
        "- title <= 70 chars.\n"
        "- summary concise and concrete.\n"
        "- category one of: Coding, Meeting, Writing, Research, Browsing, Communication, Design, Admin, Other.\n"
        "- If uncertain, infer best effort from window titles and screenshot hints.\n"
        "- No markdown, no prose outside JSON."
    )


def _timeline_context(
    day: date,
    cards: list[AITimelineCard],
    daily_summary: str,
    captured_timeline: list[str] | None = None,
    range_label: str | None = None,
) -> str:
    label = (range_label or "").strip() or day.isoformat()
    lines = [f"Date range: {label}"]
    if daily_summary.strip():
        lines.append(f"Existing daily summary: {daily_summary.strip()}")
    if cards:
        lines.append("Timeline cards:")
        for card in cards[:40]:
            lines.append(
                f"- {card.day} {card.start}-{card.end} [{card.category}] {card.title}: {card.summary}"
            )
    else:
        lines.append("No AI cards are available yet.")
    captured = [line.strip() for line in (captured_timeline or []) if line.strip()]
    if captured:
        lines.append("Captured timeline evidence:")
        for line in captured[:120]:
            lines.append(f"- {line}")
    else:
        lines.append("No captured timeline evidence was provided.")
    return "\n".join(lines)


def _resolve_openai_endpoint(provider: str, endpoint: str) -> str:
    custom = endpoint.strip()
    if custom:
        return custom
    if provider == "local":
        return "http://localhost:1234/v1/chat/completions"
    return "https://api.openai.com/v1/chat/completions"


def _sample_screenshots(rows: list[ScreenshotRecord], max_items: int) -> list[ScreenshotRecord]:
    if len(rows) <= max_items:
        return rows
    step = max(1, len(rows) // max_items)
    sampled = rows[::step]
    if len(sampled) > max_items:
        sampled = sampled[:max_items]
    if sampled and sampled[-1].id != rows[-1].id:
        sampled[-1] = rows[-1]
    return sampled


def _screenshot_context_line(row: ScreenshotRecord) -> str:
    return (
        f"Timestamp={row.captured_at.astimezone().strftime('%H:%M:%S')}, "
        f"App={row.process_name or 'unknown'}, "
        f"Window={row.window_title or 'Unknown Window'}"
    )


def _image_part_for_gemini(path: Path) -> dict[str, Any] | None:
    try:
        raw = path.read_bytes()
    except OSError:
        return None
    return {
        "inline_data": {
            "mime_type": "image/jpeg",
            "data": base64.b64encode(raw).decode("ascii"),
        }
    }


def _image_data_uri(path: Path) -> str | None:
    try:
        raw = path.read_bytes()
    except OSError:
        return None
    encoded = base64.b64encode(raw).decode("ascii")
    return f"data:image/jpeg;base64,{encoded}"


def _auth_headers(api_key: str) -> dict[str, str]:
    if not api_key.strip():
        return {}
    return {"Authorization": f"Bearer {api_key.strip()}"}


def _http_post_json(url: str, payload: dict[str, Any], headers: dict[str, str]) -> dict[str, Any]:
    req = urllib.request.Request(
        url=url,
        data=json.dumps(payload).encode("utf-8"),
        method="POST",
        headers={"Content-Type": "application/json", **headers},
    )
    try:
        with urllib.request.urlopen(req, timeout=240) as response:
            raw = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"AI request failed ({exc.code}): {body}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"AI request failed: {exc.reason}") from exc

    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError("AI provider returned non-JSON response.") from exc


def _extract_gemini_text(data: dict[str, Any]) -> str:
    candidates = data.get("candidates")
    if not isinstance(candidates, list) or not candidates:
        raise RuntimeError("Gemini response missing candidates.")
    content = candidates[0].get("content", {})
    parts = content.get("parts", [])
    for part in parts:
        text = part.get("text")
        if isinstance(text, str) and text.strip():
            return text
    raise RuntimeError("Gemini response did not include text output.")


def _extract_openai_text(data: dict[str, Any]) -> str:
    choices = data.get("choices")
    if not isinstance(choices, list) or not choices:
        raise RuntimeError("OpenAI-style response missing choices.")
    message = choices[0].get("message", {})
    content = message.get("content")
    if isinstance(content, str) and content.strip():
        return content
    if isinstance(content, list):
        chunks: list[str] = []
        for entry in content:
            if isinstance(entry, dict):
                text = entry.get("text")
                if isinstance(text, str):
                    chunks.append(text)
        joined = "\n".join(chunks).strip()
        if joined:
            return joined
    raise RuntimeError("OpenAI-style response did not include text content.")


def _parse_ai_json(text: str) -> dict[str, Any]:
    trimmed = text.strip()
    if not trimmed:
        raise RuntimeError("AI response was empty.")
    try:
        return json.loads(trimmed)
    except json.JSONDecodeError:
        start = trimmed.find("{")
        end = trimmed.rfind("}")
        if start == -1 or end == -1 or start >= end:
            raise RuntimeError("AI response did not contain valid JSON.")
        try:
            return json.loads(trimmed[start : end + 1])
        except json.JSONDecodeError as exc:
            raise RuntimeError("AI response contained invalid JSON.") from exc


def _normalize_cards(raw_cards: Any) -> list[dict[str, str]]:
    if not isinstance(raw_cards, list):
        return []
    cards: list[dict[str, str]] = []
    for entry in raw_cards:
        if not isinstance(entry, dict):
            continue
        start = _norm_hhmm(str(entry.get("start", "")).strip())
        end = _norm_hhmm(str(entry.get("end", "")).strip())
        title = str(entry.get("title", "")).strip()
        summary = str(entry.get("summary", "")).strip()
        category = str(entry.get("category", "Other")).strip() or "Other"
        if not start or not end or not title:
            continue
        cards.append(
            {
                "start": start,
                "end": end,
                "title": title,
                "summary": summary,
                "category": category,
            }
        )
    return cards


def _norm_hhmm(value: str) -> str:
    value = value.strip()
    if len(value) == 5 and value[2] == ":" and value.replace(":", "").isdigit():
        hh = int(value[:2])
        mm = int(value[3:])
        if 0 <= hh <= 23 and 0 <= mm <= 59:
            return f"{hh:02d}:{mm:02d}"
    return ""
