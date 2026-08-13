from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path
from urllib.parse import quote

import httpx

from app.config import Settings
from app.services.http import request_with_retry


class ElevenLabsCheckError(RuntimeError):
    pass


async def list_voices(client: httpx.AsyncClient, settings: Settings) -> list[dict]:
    response = await request_with_retry(
        client,
        "GET",
        f"{settings.elevenlabs_base_url.rstrip('/')}/v2/voices",
        params={"page_size": 100},
        headers={"xi-api-key": settings.elevenlabs_api_key},
    )
    voices = response.json().get("voices", [])
    return [
        {
            "voiceId": voice.get("voice_id"),
            "name": voice.get("name"),
            "category": voice.get("category"),
            "labels": voice.get("labels", {}),
            "previewUrl": voice.get("preview_url"),
        }
        for voice in voices
    ]


async def preview(
    client: httpx.AsyncClient,
    settings: Settings,
    voice_id: str,
    text: str,
    output: Path,
) -> dict:
    body: dict[str, object] = {"text": text, "model_id": settings.elevenlabs_model}
    if settings.elevenlabs_model != "eleven_multilingual_v2":
        body["language_code"] = "ko"
    response = await request_with_retry(
        client,
        "POST",
        (
            f"{settings.elevenlabs_base_url.rstrip('/')}/v1/text-to-speech/"
            f"{quote(voice_id, safe='')}"
        ),
        params={"output_format": settings.elevenlabs_output_format},
        headers={
            "xi-api-key": settings.elevenlabs_api_key,
            "Accept": "audio/mpeg",
            "Content-Type": "application/json",
        },
        json=body,
    )
    def write_audio() -> Path:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(response.content)
        return output.resolve()

    resolved_output = await asyncio.to_thread(write_audio)
    return {
        "voiceId": voice_id,
        "model": settings.elevenlabs_model,
        "output": str(resolved_output),
        "bytes": len(response.content),
    }


async def check(args: argparse.Namespace) -> int:
    settings = Settings()
    if not settings.elevenlabs_api_key:
        raise ElevenLabsCheckError("ELEVENLABS_API_KEY가 비어 있습니다")
    if not settings.elevenlabs_api_key.startswith("sk_"):
        raise ElevenLabsCheckError(
            "API key ID가 입력되었습니다. 생성/rotate 때 표시되는 sk_로 시작하는 "
            "실제 key가 필요합니다"
        )
    async with httpx.AsyncClient(timeout=30.0) as client:
        if args.preview:
            voice_id = args.voice_id or settings.elevenlabs_voice_id
            if not voice_id:
                raise ElevenLabsCheckError(
                    "--preview에는 ELEVENLABS_VOICE_ID 또는 --voice-id가 필요합니다"
                )
            result = await preview(client, settings, voice_id, args.text, args.output)
        else:
            result = {"voices": await list_voices(client, settings)}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(
        description="ElevenLabs key로 voice 목록을 조회하거나 한국어 질문 MP3를 미리 듣는다"
    )
    parser.add_argument("--preview", action="store_true", help="voice로 한국어 MP3 생성")
    parser.add_argument("--voice-id", help="환경변수보다 우선할 voice ID")
    parser.add_argument("--text", default="어젯밤에는 푹 주무셨어요?")
    parser.add_argument("--output", type=Path, default=Path("dist/elevenlabs-preview.mp3"))
    args = parser.parse_args()
    try:
        raise SystemExit(asyncio.run(check(args)))
    except (ElevenLabsCheckError, httpx.HTTPError) as exc:
        print(f"ElevenLabs 점검 실패: {exc}")
        raise SystemExit(1) from exc


if __name__ == "__main__":
    main()
