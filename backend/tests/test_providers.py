from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from app.config import Settings
from app.services.deepgram import DeepgramSttGateway
from app.services.gemini import (
    SYSTEM_INSTRUCTION,
    ExtractionError,
    GeminiExtractionGateway,
    MockExtractionGateway,
)
from app.services.livekit import RealLiveKitGateway
from app.services.notifications import ApnsVoipPushGateway, IncomingCallPush


def test_deepgram_nova3_response_is_normalized() -> None:
    gateway = DeepgramSttGateway(
        Settings(mock_external_services=False, deepgram_api_key="test", gemini_api_key="test")
    )
    result = gateway._parse(
        {
            "metadata": {"duration": 3.0},
            "results": {
                "channels": [
                    {
                        "alternatives": [
                            {
                                "transcript": "어젯밤에 기침했어",
                                "words": [
                                    {"word": "어젯밤에", "start": 0.0, "end": 0.8},
                                    {"word": "기침했어", "start": 1.0, "end": 2.0},
                                ],
                            }
                        ]
                    }
                ],
                "utterances": [{"start": 0.0, "end": 2.0, "transcript": "어젯밤에 기침했어"}],
            },
        }
    )
    assert result.provider == "deepgram-nova-3"
    assert result.speech_seconds == 1.8
    assert result.segments[0].text == "어젯밤에 기침했어"


def test_livekit_ogg_egress_uses_track_passthrough() -> None:
    gateway = RealLiveKitGateway(
        Settings(
            mock_external_services=False,
            livekit_api_key="test-key",
            livekit_api_secret="test-secret",
            storage_backend="s3",
            s3_bucket="audio",
            s3_access_key_id="access",
            s3_secret_access_key="secret",
        )
    )

    request = gateway._track_egress_request("room", "TR_audio", "calls/1/parent.ogg")

    assert request.track_id == "TR_audio"
    assert request.file.filepath.endswith("parent.ogg")
    assert request.file.s3.bucket == "audio"


async def test_mock_extractor_does_not_infer_diagnosis() -> None:
    result = await MockExtractionGateway().extract(
        "PARENT: 잠을 못 자서 오늘은 졸려. CHILD: 병 이름을 맞혀봐."
    )
    assert result.sleep is not None
    assert result.symptom is None
    assert "질환명" in SYSTEM_INSTRUCTION
    assert "치료 지시" in SYSTEM_INSTRUCTION


async def test_gemini_uses_safe_output_budget(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict = {}

    async def fake_request(client: httpx.AsyncClient, method: str, url: str, **kwargs):
        del client, method, url
        captured["body"] = kwargs["json"]
        captured["headers"] = kwargs["headers"]
        captured["params"] = kwargs.get("params")
        return httpx.Response(
            200,
            json={
                "candidates": [
                    {
                        "finishReason": "STOP",
                        "content": {
                            "parts": [
                                {
                                    "text": json.dumps(
                                        {
                                            "facts": [
                                                {
                                                    "category": "symptom",
                                                    "summary": "기침함",
                                                    "polarity": "PRESENT",
                                                    "evidenceSegmentIds": ["s0000"],
                                                }
                                            ]
                                        }
                                    )
                                }
                            ]
                        },
                    }
                ]
            },
        )

    monkeypatch.setattr("app.services.gemini.request_with_retry", fake_request)
    gateway = GeminiExtractionGateway(
        Settings(
            mock_external_services=False,
            gemini_api_key="test",
            gemini_max_output_tokens=2048,
        )
    )

    result = await gateway.extract("기침했어")

    assert result.symptom == "기침함"
    assert result.facts[0].evidence_segment_ids == ["s0000"]
    assert captured["body"]["generationConfig"]["maxOutputTokens"] == 2048
    assert "segments" in captured["body"]["contents"][0]["parts"][0]["text"]
    assert captured["headers"] == {"x-goog-api-key": "test"}
    assert captured["params"] is None


async def test_gemini_reports_truncated_response(monkeypatch: pytest.MonkeyPatch) -> None:
    async def fake_request(client: httpx.AsyncClient, method: str, url: str, **kwargs):
        del client, method, url, kwargs
        return httpx.Response(
            200,
            json={
                "candidates": [
                    {
                        "finishReason": "MAX_TOKENS",
                        "content": {"parts": [{"text": '{"symptom": "'}]},
                    }
                ]
            },
        )

    monkeypatch.setattr("app.services.gemini.request_with_retry", fake_request)
    gateway = GeminiExtractionGateway(Settings(mock_external_services=False, gemini_api_key="test"))

    with pytest.raises(ExtractionError, match="finishReason=MAX_TOKENS"):
        await gateway.extract("기침했어")


async def test_apns_voip_request_uses_required_headers_and_minimal_payload() -> None:
    private_key = ec.generate_private_key(ec.SECP256R1())
    private_pem = private_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()
    captured: dict = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        captured["headers"] = request.headers
        captured["payload"] = json.loads(request.content)
        return httpx.Response(200, json={}, headers={"apns-id": "test-id"})

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler), http2=True)
    settings = Settings(
        mock_external_services=False,
        apns_voip_enabled=True,
        apns_environment="sandbox",
        apns_team_id="TEAM123456",
        apns_key_id="KEY1234567",
        apns_bundle_id="com.example.Collog",
    )
    gateway = ApnsVoipPushGateway(settings, client=client, private_key=private_pem)
    push = IncomingCallPush(
        call_id="2f5d8c0d-2bb9-4485-91c2-51aab8bf4e43",
        caller_id="child-id",
        caller_name="김철수",
        expires_at=datetime.now(UTC) + timedelta(seconds=45),
    )

    await gateway.send_incoming_call("ab" * 32, push)

    assert captured["url"].endswith("/3/device/" + "ab" * 32)
    headers = captured["headers"]
    assert headers["apns-topic"] == "com.example.Collog.voip"
    assert headers["apns-push-type"] == "voip"
    assert headers["apns-priority"] == "10"
    assert headers["apns-expiration"] == "0"
    provider_token = headers["authorization"].removeprefix("bearer ")
    claims = jwt.decode(
        provider_token,
        private_key.public_key(),
        algorithms=["ES256"],
        options={"verify_aud": False},
    )
    assert claims["iss"] == "TEAM123456"
    payload = captured["payload"]
    assert payload["call"]["callUUID"] == push.call_id
    assert "accessToken" not in payload["call"]
    assert "roomName" not in payload["call"]

    await gateway.close()
