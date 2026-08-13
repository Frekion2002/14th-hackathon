from __future__ import annotations

import argparse
import asyncio
import json
import wave
from datetime import UTC, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import httpx
from sqlalchemy import select

from app.config import Settings
from app.container import AppContainer
from app.models import (
    AcousticFeature,
    AssetKind,
    AssetStatus,
    AudioAsset,
    CallRecord,
    CallState,
    ExtractionEvidence,
    HealthExtraction,
    RepeatEvent,
    TimeSlot,
    Transcript,
    User,
)

# Track Egress worker는 컨테이너 런타임이 있어야 돈다. 그것 없이 STT/LLM/음향/기준선
# 파이프라인을 검증하려고, Egress가 만들었을 audio asset을 로컬 파일로 대신 등록하고
# 실제 ProcessingPipeline을 그대로 호출한다. 개발 환경 전용이다.

CONTENT_TYPES = {".wav": "audio/wav", ".ogg": "audio/ogg", ".opus": "audio/ogg"}


class ReplayError(RuntimeError):
    pass


def audio_meta(path: Path) -> tuple[str, float | None, int | None]:
    content_type = CONTENT_TYPES.get(path.suffix.lower())
    if content_type is None:
        raise ReplayError(f"지원하지 않는 확장자입니다: {path.suffix}")
    if content_type != "audio/wav":
        return content_type, None, None
    with wave.open(str(path), "rb") as handle:
        if handle.getsampwidth() != 2:
            raise ReplayError(f"{path.name}은 16-bit PCM WAV가 아닙니다")
        frames = handle.getnframes()
        rate = handle.getframerate()
        return content_type, frames / rate if rate else None, rate


async def upload(container: AppContainer, key: str, body: bytes, content_type: str) -> str:
    url = await container.storage.create_upload_url(key, content_type)
    async with httpx.AsyncClient(timeout=60.0) as client:
        response = await client.put(url, content=body, headers={"Content-Type": content_type})
    if response.status_code >= 300:
        raise ReplayError(f"업로드 실패 {response.status_code}: {response.text[:200]}")
    return container.storage.object_uri(key)


async def replay(args: argparse.Namespace) -> int:
    settings = Settings()
    if settings.mock_external_services:
        print("경고: MOCK_EXTERNAL_SERVICES=true 입니다. 실제 Deepgram/Gemini를 호출하지 않습니다.")
    container = AppContainer(settings)
    await container.database.create_all()

    async with container.database.sessions() as session:
        child = await session.scalar(select(User).where(User.phone == args.child_phone))
        parent = await session.scalar(select(User).where(User.phone == args.parent_phone))
        if child is None or parent is None:
            raise ReplayError(
                "자녀 또는 부모 계정이 없습니다. seed_demo_family.py를 먼저 실행하세요"
            )

        started = datetime.now(UTC) - timedelta(minutes=args.minutes_ago)
        local_hour = started.astimezone(ZoneInfo("Asia/Seoul")).hour
        call = CallRecord(
            parent_id=parent.id,
            child_id=child.id,
            state=CallState.ENDED.value,
            room_name=f"replay-{started:%Y%m%d%H%M%S}",
            recording_enabled=True,
            asked_question_ids=[],
            started_at=started,
            accepted_at=started,
            ended_at=started + timedelta(minutes=3),
            duration_sec=180,
            time_slot=(
                TimeSlot.MORNING.value
                if 6 <= local_hour <= 11
                else TimeSlot.AFTERNOON_EVENING.value
            ),
        )
        session.add(call)
        await session.commit()
        call_id = call.id

    plan: list[tuple[str, Path]] = []
    if args.parent_audio:
        plan.append((AssetKind.WEBRTC_EGRESS_PARENT.value, Path(args.parent_audio)))
    if args.child_audio:
        plan.append((AssetKind.WEBRTC_EGRESS_CHILD.value, Path(args.child_audio)))
    if args.raw_audio:
        plan.append((AssetKind.DEVICE_RAW.value, Path(args.raw_audio)))

    for kind, path in plan:
        if not path.exists():
            raise ReplayError(f"파일이 없습니다: {path}")
        content_type, duration, sample_rate = audio_meta(path)
        uri = await upload(
            container,
            f"calls/{call_id}/{kind.lower()}{path.suffix}",
            path.read_bytes(),
            content_type,
        )
        async with container.database.sessions() as session:
            session.add(
                AudioAsset(
                    call_id=call_id,
                    kind=kind,
                    uri=uri,
                    content_type=content_type,
                    duration_sec=duration,
                    sample_rate=sample_rate,
                    status=AssetStatus.UPLOADED.value,
                    uploaded_at=datetime.now(UTC),
                )
            )
            await session.commit()
        print(f"등록: {kind} ← {path.name} ({content_type}, {duration or '?'}s)")

    print("파이프라인 실행 중… Deepgram STT → 되묻기 → Gemini → 음향 → 기준선")
    await container.pipeline.process(call_id)

    async with container.database.sessions() as session:
        call = await session.get(CallRecord, call_id)
        transcript = await session.scalar(select(Transcript).where(Transcript.call_id == call_id))
        repeats = list(
            await session.scalars(select(RepeatEvent).where(RepeatEvent.call_id == call_id))
        )
        extraction = await session.scalar(
            select(HealthExtraction).where(HealthExtraction.call_id == call_id)
        )
        evidence = await session.scalar(
            select(ExtractionEvidence).where(ExtractionEvidence.call_id == call_id)
        )
        features = list(
            await session.scalars(select(AcousticFeature).where(AcousticFeature.call_id == call_id))
        )
        report = {
            "callId": call_id,
            "state": call.state if call else None,
            "processingError": call.processing_error if call else None,
            "parentSpeechSec": transcript.parent_speech_sec if transcript else None,
            "sttProvider": transcript.provider if transcript else None,
            "excluded": transcript.excluded if transcript else None,
            "exclusionReason": transcript.exclusion_reason if transcript else None,
            "segments": [
                {"speaker": item["speaker"], "text": item["text"]}
                for item in (transcript.segments if transcript else [])
            ],
            "repeatEvents": [
                {"category": item.category, "text": item.matched_text} for item in repeats
            ],
            "extraction": (
                {
                    "parseStatus": extraction.parse_status,
                    "symptom": extraction.symptom,
                    "medication": extraction.medication,
                    "activity": extraction.activity,
                    "sleep": extraction.sleep,
                }
                if extraction
                else None
            ),
            "facts": evidence.facts if evidence else [],
            "acoustics": [
                {
                    "metric": item.metric,
                    "value": item.value,
                    "status": item.status,
                    "reason": item.unmeasurable_reason,
                    "source": item.audio_source,
                }
                for item in features
            ],
        }

    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["state"] == CallState.ANALYZED.value else 1


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Egress 없이 로컬 오디오로 STT/LLM/음향 파이프라인을 실행한다"
    )
    parser.add_argument("--parent-audio", help="부모 Egress 음성 파일 (wav 또는 ogg)")
    parser.add_argument("--child-audio", help="자녀 음성 파일")
    parser.add_argument("--raw-audio", help="분석용 16-bit PCM WAV. 없으면 부모 파일을 쓴다")
    parser.add_argument("--child-phone", default="01000000002")
    parser.add_argument("--parent-phone", default="01000000010")
    parser.add_argument(
        "--minutes-ago",
        type=int,
        default=5,
        help="통화 시작 시각을 과거로 밀어 raw audio 대기 시간을 건너뛴다",
    )
    args = parser.parse_args()
    if not args.parent_audio and not args.raw_audio:
        parser.error("--parent-audio 또는 --raw-audio 중 하나는 필요합니다")
    try:
        raise SystemExit(asyncio.run(replay(args)))
    except ReplayError as exc:
        print(f"실패: {exc}")
        raise SystemExit(2) from exc


if __name__ == "__main__":
    main()
