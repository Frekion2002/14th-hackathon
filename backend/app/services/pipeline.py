from __future__ import annotations

import asyncio
import logging
from datetime import UTC, datetime, timedelta

from sqlalchemy import select

from app.config import Settings
from app.database import Database
from app.models import (
    AcousticFeature,
    AssetKind,
    AssetStatus,
    AudioAsset,
    CallRecord,
    CallState,
    HealthExtraction,
    Transcript,
)
from app.services.acoustics import AcousticAnalyzer
from app.services.deepgram import SttGateway
from app.services.gemini import ExtractionGateway
from app.services.signals import SignalService
from app.services.storage import StorageGateway

logger = logging.getLogger(__name__)


class ProcessingPipeline:
    def __init__(
        self,
        settings: Settings,
        database: Database,
        storage: StorageGateway,
        stt: SttGateway,
        extraction: ExtractionGateway,
        acoustics: AcousticAnalyzer,
        signals: SignalService,
    ) -> None:
        self.settings = settings
        self.database = database
        self.storage = storage
        self.stt = stt
        self.extraction = extraction
        self.acoustics = acoustics
        self.signals = signals
        self._locks: dict[str, asyncio.Lock] = {}

    async def process(self, call_id: str) -> None:
        lock = self._locks.setdefault(call_id, asyncio.Lock())
        async with lock:
            try:
                await self._process(call_id)
            except Exception as exc:
                logger.exception("call processing failed", extra={"call_id": call_id})
                async with self.database.sessions() as session:
                    call = await session.get(CallRecord, call_id)
                    if call:
                        call.state = CallState.ANALYSIS_FAILED.value
                        call.processing_error = str(exc)[:2000]
                        await session.commit()
                await self.purge_call_audio(call_id)
            finally:
                self._locks.pop(call_id, None)

    async def _process(self, call_id: str) -> None:
        async with self.database.sessions() as session:
            call = await session.get(CallRecord, call_id)
            if call is None or call.state in {
                CallState.ANALYZED.value,
                CallState.ANALYSIS_EXCLUDED.value,
            }:
                return
            if not call.recording_enabled or call.ended_at is None:
                return
            assets = (
                await session.scalars(select(AudioAsset).where(AudioAsset.call_id == call_id))
            ).all()
            egress_assets = [
                item
                for item in assets
                if item.kind
                in {
                    AssetKind.WEBRTC_EGRESS_PARENT.value,
                    AssetKind.WEBRTC_EGRESS_CHILD.value,
                }
            ]
            if any(item.status == AssetStatus.PENDING.value for item in egress_assets):
                return
            parent_egress = next(
                (
                    item
                    for item in assets
                    if item.kind == AssetKind.WEBRTC_EGRESS_PARENT.value
                    and item.status == AssetStatus.UPLOADED.value
                ),
                None,
            )
            if parent_egress is None:
                if egress_assets:
                    call.state = CallState.ANALYSIS_FAILED.value
                    call.processing_error = "부모 Egress 녹음이 완료되지 않았습니다"
                    await session.commit()
                    await self.purge_call_audio(call_id)
                return
            child_egress = next(
                (
                    item
                    for item in assets
                    if item.kind == AssetKind.WEBRTC_EGRESS_CHILD.value
                    and item.status == AssetStatus.UPLOADED.value
                ),
                None,
            )
            raw_asset = next(
                (
                    item
                    for item in assets
                    if item.kind == AssetKind.DEVICE_RAW.value
                    and item.status == AssetStatus.UPLOADED.value
                ),
                None,
            )
            pending_raw = any(
                item.kind == AssetKind.DEVICE_RAW.value and item.status == AssetStatus.PENDING.value
                for item in assets
            )
            if pending_raw:
                return
            if raw_asset is None:
                elapsed = datetime.now(UTC) - aware_datetime(call.ended_at)
                if elapsed.total_seconds() < self.settings.raw_audio_wait_seconds:
                    return
            call.state = CallState.PROCESSING.value
            await session.commit()

        parent_audio = await self.storage.read(parent_egress.uri)
        parent_stt = await self.stt.transcribe(parent_audio, parent_egress.content_type, "PARENT")
        stt_results = [("PARENT", parent_stt)]
        if child_egress:
            child_audio = await self.storage.read(child_egress.uri)
            child_stt = await self.stt.transcribe(child_audio, child_egress.content_type, "CHILD")
            stt_results.append(("CHILD", child_stt))

        segments = sorted(
            [
                {
                    "speaker": speaker,
                    "startMs": segment.start_ms,
                    "endMs": segment.end_ms,
                    "text": segment.text,
                }
                for speaker, result in stt_results
                for segment in result.segments
            ],
            key=lambda item: (item["startMs"], item["speaker"]),
        )
        parent_speech_sec = round(parent_stt.speech_seconds)
        provider = parent_stt.provider
        excluded = parent_speech_sec < self.settings.parent_min_speech_seconds

        async with self.database.sessions() as session:
            call = await session.get(CallRecord, call_id)
            if call is None:
                return
            call.parent_speech_sec = parent_speech_sec
            transcript = await session.scalar(
                select(Transcript).where(Transcript.call_id == call_id)
            )
            if transcript is None:
                transcript = Transcript(call_id=call_id, provider=provider)
                session.add(transcript)
            transcript.provider = provider
            transcript.excluded = excluded
            transcript.exclusion_reason = "INSUFFICIENT_PARENT_SPEECH" if excluded else None
            transcript.parent_speech_sec = parent_speech_sec
            transcript.segments = segments
            await session.commit()

        if excluded:
            async with self.database.sessions() as session:
                call = await session.get(CallRecord, call_id)
                if call:
                    call.state = CallState.ANALYSIS_EXCLUDED.value
                    await session.commit()
            await self.purge_call_audio(call_id)
            return

        transcript_text = "\n".join(f"{item['speaker']}: {item['text']}" for item in segments)
        try:
            extracted = await self.extraction.extract(transcript_text)
            extraction_values = extracted.model_dump()
            parse_status = "OK"
            raw_transcript = None
        except Exception:
            logger.exception("health extraction failed", extra={"call_id": call_id})
            extraction_values = {
                key: None for key in ("symptom", "medication", "activity", "sleep")
            }
            parse_status = "FAILED"
            raw_transcript = transcript_text

        acoustic_asset = raw_asset or parent_egress
        acoustic_audio = await self.storage.read(acoustic_asset.uri)
        measurements = await self.acoustics.analyze(acoustic_audio, acoustic_asset.sample_rate)

        async with self.database.sessions() as session:
            extraction = await session.scalar(
                select(HealthExtraction).where(HealthExtraction.call_id == call_id)
            )
            if extraction is None:
                extraction = HealthExtraction(call_id=call_id, parse_status=parse_status)
                session.add(extraction)
            extraction.parse_status = parse_status
            extraction.symptom = extraction_values["symptom"]
            extraction.medication = extraction_values["medication"]
            extraction.activity = extraction_values["activity"]
            extraction.sleep = extraction_values["sleep"]
            extraction.raw_transcript = raw_transcript
            existing_metrics = set(
                await session.scalars(
                    select(AcousticFeature.metric).where(AcousticFeature.call_id == call_id)
                )
            )
            for item in measurements:
                if item.metric.value in existing_metrics:
                    continue
                session.add(
                    AcousticFeature(
                        call_id=call_id,
                        audio_source=(
                            "DEVICE_RAW"
                            if acoustic_asset.kind == AssetKind.DEVICE_RAW.value
                            else "WEBRTC_EGRESS"
                        ),
                        metric=item.metric.value,
                        value=item.value,
                        unit=item.unit,
                        status=item.status,
                        unmeasurable_reason=item.unmeasurable_reason,
                        observed_at=call.ended_at or datetime.now(UTC),
                    )
                )
            await session.flush()
            call = await session.get(CallRecord, call_id)
            if call:
                await self.signals.process_call(session, call)
                call.state = CallState.ANALYZED.value
            await session.commit()

        await self.purge_call_audio(call_id)

    async def purge_call_audio(self, call_id: str) -> None:
        async with self.database.sessions() as session:
            assets = (
                await session.scalars(select(AudioAsset).where(AudioAsset.call_id == call_id))
            ).all()
            for asset in assets:
                if asset.status == AssetStatus.PURGED.value:
                    continue
                try:
                    await self.storage.delete(asset.uri)
                except Exception:
                    logger.exception("audio purge failed", extra={"asset_id": asset.id})
                    continue
                asset.status = AssetStatus.PURGED.value
                asset.purged_at = datetime.now(UTC)
            call = await session.get(CallRecord, call_id)
            if call and all(asset.status == AssetStatus.PURGED.value for asset in assets):
                call.raw_audio_purged_at = datetime.now(UTC)
            await session.commit()

    async def purge_expired_audio(self) -> int:
        cutoff = datetime.now(UTC) - timedelta(hours=24)
        async with self.database.sessions() as session:
            call_ids = list(
                await session.scalars(
                    select(CallRecord.id).where(
                        CallRecord.ended_at.is_not(None),
                        CallRecord.ended_at < cutoff,
                        CallRecord.raw_audio_purged_at.is_(None),
                    )
                )
            )
        for call_id in call_ids:
            await self.purge_call_audio(call_id)
        return len(call_ids)

    async def process_pending(self) -> int:
        async with self.database.sessions() as session:
            call_ids = list(
                await session.scalars(
                    select(CallRecord.id).where(
                        CallRecord.state.in_([CallState.ENDED.value, CallState.PROCESSING.value])
                    )
                )
            )
        for call_id in call_ids:
            await self.process(call_id)
        return len(call_ids)


def aware_datetime(value: datetime) -> datetime:
    return value if value.tzinfo else value.replace(tzinfo=UTC)
