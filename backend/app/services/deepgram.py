from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Literal

import httpx

from app.config import Settings
from app.services.http import request_with_retry


class SttError(RuntimeError):
    pass


@dataclass(slots=True)
class SttSegment:
    start_ms: int
    end_ms: int
    text: str


@dataclass(slots=True)
class SttResult:
    provider: str
    speech_seconds: float
    segments: list[SttSegment]


class SttGateway:
    async def transcribe(
        self, audio: bytes, content_type: str, speaker: Literal["PARENT", "CHILD"]
    ) -> SttResult:
        raise NotImplementedError


class MockSttGateway(SttGateway):
    async def transcribe(
        self, audio: bytes, content_type: str, speaker: Literal["PARENT", "CHILD"]
    ) -> SttResult:
        del content_type
        text = audio.decode("utf-8", errors="ignore").strip()
        duration = max(0.0, len(text) / 4.0)
        return SttResult(
            provider="mock-nova-3",
            speech_seconds=duration,
            segments=[SttSegment(0, int(duration * 1000), text)] if text else [],
        )


class DeepgramSttGateway(SttGateway):
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        if not settings.deepgram_api_key:
            raise SttError("DEEPGRAM_API_KEY가 필요합니다")

    async def transcribe(
        self, audio: bytes, content_type: str, speaker: Literal["PARENT", "CHILD"]
    ) -> SttResult:
        del speaker  # tracks are already separated before this provider boundary
        params: dict[str, str | bool] = {
            "model": self.settings.deepgram_model,
            "language": self.settings.deepgram_language,
            "smart_format": True,
            "punctuate": True,
            "utterances": True,
            "filler_words": True,
        }
        headers = {
            "Authorization": f"Token {self.settings.deepgram_api_key}",
            "Content-Type": content_type,
        }
        try:
            async with httpx.AsyncClient(timeout=120) as client:
                response = await request_with_retry(
                    client,
                    "POST",
                    f"{self.settings.deepgram_base_url.rstrip('/')}/v1/listen",
                    params=params,
                    headers=headers,
                    content=audio,
                )
                payload = response.json()
        except (httpx.HTTPError, ValueError) as exc:
            raise SttError(f"Deepgram STT 요청 실패: {exc}") from exc
        return self._parse(payload)

    def _parse(self, payload: dict[str, Any]) -> SttResult:
        try:
            alternative = payload["results"]["channels"][0]["alternatives"][0]
        except (KeyError, IndexError, TypeError) as exc:
            raise SttError("Deepgram 응답에 전사 결과가 없습니다") from exc

        utterances = payload.get("results", {}).get("utterances", [])
        segments = [
            SttSegment(
                start_ms=round(float(item.get("start", 0)) * 1000),
                end_ms=round(float(item.get("end", 0)) * 1000),
                text=str(item.get("transcript", "")).strip(),
            )
            for item in utterances
            if str(item.get("transcript", "")).strip()
        ]
        if not segments and alternative.get("transcript"):
            duration = float(payload.get("metadata", {}).get("duration", 0))
            segments = [
                SttSegment(0, round(duration * 1000), str(alternative["transcript"]).strip())
            ]

        words = alternative.get("words", [])
        speech_seconds = sum(
            max(0.0, float(word.get("end", 0)) - float(word.get("start", 0))) for word in words
        )
        if not words:
            speech_seconds = sum(max(0, part.end_ms - part.start_ms) for part in segments) / 1000
        return SttResult(
            provider=f"deepgram-{self.settings.deepgram_model}",
            speech_seconds=speech_seconds,
            segments=segments,
        )


def create_stt_gateway(settings: Settings) -> SttGateway:
    if settings.mock_external_services:
        return MockSttGateway()
    return DeepgramSttGateway(settings)
