from __future__ import annotations

import json

import httpx

from app.config import Settings
from app.schemas import ExtractionPayload
from app.services.http import request_with_retry


class ExtractionError(RuntimeError):
    pass


SYSTEM_INSTRUCTION = """
당신은 가족 통화 기록에서 건강 관련 언급을 사실 그대로 구조화하는 추출기다.
증상, 복약, 활동, 수면의 네 항목만 추출한다. 언급이 없으면 null로 둔다.
통화에서 말하지 않은 원인이나 인과관계를 추론하지 않는다.
질환명, 위험군 라벨, 응급도 판정, 치료 지시를 생성하지 않는다.
사용자가 직접 말한 표현을 짧고 중립적인 한국어 문장으로 요약한다.
""".strip()


class ExtractionGateway:
    async def extract(self, transcript: str) -> ExtractionPayload:
        raise NotImplementedError


class MockExtractionGateway(ExtractionGateway):
    async def extract(self, transcript: str) -> ExtractionPayload:
        categories = {
            "symptom": ["기침", "아프", "통증", "어지", "목이", "숨이"],
            "medication": ["약", "복용"],
            "activity": ["산책", "운동", "걸었", "외출"],
            "sleep": ["잠", "수면", "깨", "졸"],
        }
        values: dict[str, str | None] = {}
        sentences = [
            part.strip() for part in transcript.replace("?", ".").split(".") if part.strip()
        ]
        for category, keywords in categories.items():
            match = next((line for line in sentences if any(key in line for key in keywords)), None)
            values[category] = match
        return ExtractionPayload(**values)


class GeminiExtractionGateway(ExtractionGateway):
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        if not settings.gemini_api_key:
            raise ExtractionError("GEMINI_API_KEY가 필요합니다")

    async def extract(self, transcript: str) -> ExtractionPayload:
        schema = ExtractionPayload.model_json_schema()
        body = {
            "systemInstruction": {"parts": [{"text": SYSTEM_INSTRUCTION}]},
            "contents": [{"role": "user", "parts": [{"text": transcript}]}],
            "generationConfig": {
                "responseMimeType": "application/json",
                "responseJsonSchema": schema,
                "temperature": 0,
                "maxOutputTokens": 500,
            },
        }
        url = (
            f"{self.settings.gemini_base_url.rstrip('/')}/v1beta/models/"
            f"{self.settings.gemini_model}:generateContent"
        )
        try:
            async with httpx.AsyncClient(timeout=60) as client:
                response = await request_with_retry(
                    client,
                    "POST",
                    url,
                    params={"key": self.settings.gemini_api_key},
                    json=body,
                )
                payload = response.json()
            text = payload["candidates"][0]["content"]["parts"][0]["text"]
            return ExtractionPayload.model_validate(json.loads(text))
        except (httpx.HTTPError, KeyError, IndexError, TypeError, ValueError) as exc:
            raise ExtractionError(f"Gemini 구조화 추출 실패: {exc}") from exc


def create_extraction_gateway(settings: Settings) -> ExtractionGateway:
    if settings.mock_external_services:
        return MockExtractionGateway()
    return GeminiExtractionGateway(settings)
