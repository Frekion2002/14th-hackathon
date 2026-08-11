from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from typing import Any

RULE_VERSION = "repeat-ko-v1"
MERGE_GAP_MS = 3_000


@dataclass(frozen=True, slots=True)
class RepeatMatch:
    start_ms: int
    end_ms: int
    category: str
    matched_text: str
    rule_id: str
    confidence: float
    rule_version: str = RULE_VERSION


@dataclass(frozen=True, slots=True)
class _Rule:
    rule_id: str
    category: str
    pattern: re.Pattern[str]
    confidence: float
    standalone_only: bool = False


def _compile(pattern: str) -> re.Pattern[str]:
    return re.compile(pattern)


RULES = (
    _Rule("repeat.what", "REPEAT_REQUEST", _compile(r"뭐\s*라고"), 0.98),
    _Rule("repeat.again", "REPEAT_REQUEST", _compile(r"다시\s*(?:한\s*번\s*)?말(?:해|씀해)"), 0.98),
    _Rule("repeat.one-more", "REPEAT_REQUEST", _compile(r"한\s*번\s*더"), 0.96),
    _Rule(
        "hearing.cannot-hear", "HEARING_DIFFICULTY", _compile(r"잘\s*안\s*들(?:려|린다|리네)"), 0.99
    ),
    _Rule(
        "hearing.did-not-hear",
        "HEARING_DIFFICULTY",
        _compile(r"못\s*들(?:었어|었다|었네|었어요)"),
        0.98,
    ),
    _Rule("hearing.louder", "HEARING_DIFFICULTY", _compile(r"크게\s*말(?:해|씀해)"), 0.98),
    _Rule(
        "clarify.meaning", "CLARIFICATION", _compile(r"무슨\s*말(?:이야|이에요|이오)"), 0.82, True
    ),
    _Rule("clarify.how", "CLARIFICATION", _compile(r"어떻게"), 0.72, True),
    _Rule("clarify.huh-eung", "CLARIFICATION", _compile(r"응"), 0.65, True),
    _Rule("clarify.huh-eo", "CLARIFICATION", _compile(r"어"), 0.62, True),
)

EXCLUSIONS = (
    _compile(r"내가\s*다시\s*말"),
    _compile(r"다시\s*(?:갔|왔|했|먹|잤|걸|보)"),
    _compile(r"응\s*(?:맞아|그래|알았어|괜찮아)"),
    _compile(r"한\s*번\s*더\s*(?:갔|했|먹|보)"),
)


def normalize_korean_utterance(text: str) -> str:
    normalized = unicodedata.normalize("NFC", text).lower()
    normalized = re.sub(r"[^0-9a-z가-힣\s]", " ", normalized)
    return re.sub(r"\s+", " ", normalized).strip()


def _is_short_standalone(text: str) -> bool:
    return len(text.split()) <= 2 and len(text.replace(" ", "")) <= 7


def detect_repeat_events(segments: list[dict[str, Any]]) -> list[RepeatMatch]:
    raw_matches: list[RepeatMatch] = []
    for segment in segments:
        if segment.get("speaker") != "PARENT":
            continue
        original = str(segment.get("text", "")).strip()
        normalized = normalize_korean_utterance(original)
        if not normalized or any(pattern.search(normalized) for pattern in EXCLUSIONS):
            continue
        for rule in RULES:
            match = rule.pattern.search(normalized)
            if not match or (rule.standalone_only and not _is_short_standalone(normalized)):
                continue
            raw_matches.append(
                RepeatMatch(
                    start_ms=int(segment.get("startMs", 0)),
                    end_ms=int(segment.get("endMs", segment.get("startMs", 0))),
                    category=rule.category,
                    matched_text=original,
                    rule_id=rule.rule_id,
                    confidence=rule.confidence,
                )
            )
            break

    merged: list[RepeatMatch] = []
    for event in sorted(raw_matches, key=lambda item: (item.start_ms, item.end_ms)):
        if merged and event.start_ms - merged[-1].end_ms <= MERGE_GAP_MS:
            previous = merged[-1]
            strongest = event if event.confidence > previous.confidence else previous
            merged[-1] = RepeatMatch(
                start_ms=previous.start_ms,
                end_ms=max(previous.end_ms, event.end_ms),
                category=strongest.category,
                matched_text=" / ".join(dict.fromkeys([previous.matched_text, event.matched_text])),
                rule_id=strongest.rule_id,
                confidence=max(previous.confidence, event.confidence),
            )
        else:
            merged.append(event)
    return merged


def repeat_rate_per_minute(event_count: int, parent_speech_seconds: float) -> float:
    if event_count <= 0 or parent_speech_seconds <= 0:
        return 0.0
    return round(event_count * 60 / parent_speech_seconds, 2)
