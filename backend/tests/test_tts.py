from __future__ import annotations

from pathlib import Path

import httpx
import pytest

from app.config import Settings
from app.schemas import QuestionView
from app.services.storage import LocalStorage
from app.services.tts import ElevenLabsQuestionTtsGateway


def question() -> QuestionView:
    return QuestionView(
        question_id="sleep-01",
        text="어젯밤에는 푹 주무셨어요?",
        condition_code="HYPERTENSION",
        tts_asset_url=None,
        duration_ms=None,
    )


def settings(tmp_path: Path) -> Settings:
    return Settings(
        app_env="test",
        database_url=f"sqlite+aiosqlite:///{tmp_path / 'test.db'}",
        local_storage_path=tmp_path / "audio",
        public_base_url="http://testserver",
        jwt_secret="test-secret-with-more-than-thirty-two-characters",
        mock_external_services=False,
        storage_backend="local",
        question_tts_provider="elevenlabs",
        elevenlabs_api_key="sk_test-elevenlabs-key",
        elevenlabs_voice_id="test-korean-voice",
        elevenlabs_model="eleven_flash_v2_5",
    )


@pytest.mark.asyncio
async def test_elevenlabs_generates_caches_and_signs_question_audio(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    captured: list[dict] = []

    async def fake_request(client, method, url, **kwargs):
        del client
        captured.append({"method": method, "url": url, **kwargs})
        return httpx.Response(200, content=b"ID3-test-audio")

    monkeypatch.setattr("app.services.tts.request_with_retry", fake_request)
    config = settings(tmp_path)
    storage = LocalStorage(config)
    gateway = ElevenLabsQuestionTtsGateway(config, storage)

    first = (await gateway.attach_audio([question()]))[0]
    second = (await gateway.attach_audio([question()]))[0]

    assert len(captured) == 1
    assert captured[0]["method"] == "POST"
    assert captured[0]["url"].endswith("/v1/text-to-speech/test-korean-voice")
    assert captured[0]["params"] == {"output_format": "mp3_44100_128"}
    assert captured[0]["headers"]["xi-api-key"] == "sk_test-elevenlabs-key"
    assert captured[0]["json"] == {
        "text": "어젯밤에는 푹 주무셨어요?",
        "model_id": "eleven_flash_v2_5",
        "language_code": "ko",
    }
    assert first.tts_mode == "REMOTE_ASSET"
    assert first.tts_asset_url is not None
    assert first.tts_asset_url.startswith("http://testserver/v1/tts-assets/tts/questions/")
    assert "signature=" in first.tts_asset_url
    assert second.tts_mode == "REMOTE_ASSET"
    assert len(list((tmp_path / "audio" / "tts" / "questions").glob("*.mp3"))) == 1


@pytest.mark.asyncio
async def test_elevenlabs_failure_falls_back_without_blocking_call_creation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    async def fail_request(client, method, url, **kwargs):
        del client, method, kwargs
        request = httpx.Request("POST", url)
        raise httpx.ConnectError("offline", request=request)

    monkeypatch.setattr("app.services.tts.request_with_retry", fail_request)
    config = settings(tmp_path)
    gateway = ElevenLabsQuestionTtsGateway(config, LocalStorage(config))

    result = (await gateway.attach_audio([question()]))[0]

    assert result.tts_mode == "IOS_LOCAL"
    assert result.tts_asset_url is None


@pytest.mark.asyncio
async def test_local_tts_download_signature_rejects_tampering(tmp_path: Path) -> None:
    config = settings(tmp_path)
    storage = LocalStorage(config)
    key = "tts/questions/example.mp3"
    await storage.write(key, b"audio", "audio/mpeg")

    url = httpx.URL(await storage.create_download_url(storage.object_uri(key)))
    expires = int(url.params["expires"])
    signature = url.params["signature"]

    assert storage.verify_download(key, expires, signature)
    assert not storage.verify_download("tts/questions/other.mp3", expires, signature)
