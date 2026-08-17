from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime, time, timedelta

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings
from app.models import (
    AcousticAnalysisRun,
    AcousticFeature,
    AudioAsset,
    Baseline,
    CallRecord,
    CallState,
    ChangeSignal,
    ExtractionEvidence,
    HealthExtraction,
    Metric,
    RepeatEvent,
    Report,
    TimeSlot,
    Transcript,
)
from app.services.reports import ReportService
from app.services.signals import SignalService, week_start

DEMO_ROOM_PREFIX = "demo-history-"
DEFAULT_SPEECH_RATE_SERIES = (230.0, 228.0, 232.0, 229.0, 224.0, 220.0, 214.0, 208.0)


@dataclass(frozen=True)
class DemoHistoryResult:
    parent_id: str
    calls_created: int
    first_observed_at: datetime
    last_observed_at: datetime
    report_state: str
    promoted_signal_count: int


async def replace_demo_history(
    session: AsyncSession,
    *,
    parent_id: str,
    child_id: str,
    settings: Settings,
    now: datetime | None = None,
) -> DemoHistoryResult:
    """Replace only Collog's synthetic history for one demo family.

    Eight distinct ISO weeks are intentional: the first four form the anchor and the
    latest four form the rolling baseline. Only the already-working speech-rate metric
    is seeded. Cough, pause and F0 values are never fabricated for a demo.
    """

    if settings.app_env == "production":
        raise RuntimeError("시연용 더미 데이터는 production 환경에 넣을 수 없습니다")

    now = now or datetime.now(UTC)
    if now.tzinfo is None:
        now = now.replace(tzinfo=UTC)
    else:
        now = now.astimezone(UTC)

    await _delete_previous_demo_history(session, parent_id=parent_id, child_id=child_id)
    signal_service = SignalService(settings)
    observed_times: list[datetime] = []

    current_week = week_start(now.date())
    for index, speech_rate in enumerate(DEFAULT_SPEECH_RATE_SERIES):
        weeks_ago = len(DEFAULT_SPEECH_RATE_SERIES) - index - 1
        observed_date = current_week - timedelta(weeks=weeks_ago) + timedelta(days=3)
        observed_at = datetime.combine(observed_date, time(1, 30), tzinfo=UTC)
        if weeks_ago == 0 or observed_at >= now:
            observed_at = now - timedelta(minutes=10)
        observed_times.append(observed_at)

        call = CallRecord(
            parent_id=parent_id,
            child_id=child_id,
            state=CallState.ANALYZED.value,
            room_name=f"{DEMO_ROOM_PREFIX}{parent_id[:8]}-{weeks_ago}",
            recording_enabled=True,
            started_at=observed_at - timedelta(minutes=12),
            accepted_at=observed_at - timedelta(minutes=11, seconds=45),
            ended_at=observed_at,
            time_slot=TimeSlot.MORNING.value,
            duration_sec=720,
            parent_speech_sec=360,
            asked_question_ids=[],
            raw_audio_purged_at=observed_at + timedelta(seconds=30),
            created_at=observed_at - timedelta(minutes=12),
        )
        session.add(call)
        await session.flush()

        session.add(
            AcousticFeature(
                call_id=call.id,
                audio_source="DEMO_DERIVED",
                metric=Metric.SPEECH_RATE.value,
                value=speech_rate,
                unit="음절/분",
                status="OK",
                observed_at=observed_at,
            )
        )
        session.add(
            AcousticAnalysisRun(
                call_id=call.id,
                analyzer_version="demo-seed-v1",
                cough_detector_version="NOT_RUN",
                created_at=observed_at,
            )
        )

        extraction = _extraction_for_week(weeks_ago)
        session.add(
            HealthExtraction(
                call_id=call.id,
                parse_status="OK",
                symptom=extraction["symptom"],
                medication=extraction["medication"],
                activity=extraction["activity"],
                sleep=extraction["sleep"],
                raw_transcript=None,
                created_at=observed_at,
            )
        )
        facts = [
            {
                "category": category,
                "summary": summary,
                "polarity": "PRESENT",
                "evidenceSegmentIds": [f"demo-{weeks_ago}-{category}"],
            }
            for category, summary in extraction.items()
            if summary
        ]
        session.add(
            ExtractionEvidence(
                call_id=call.id,
                facts=facts,
                schema_version="demo-v1",
                created_at=observed_at,
            )
        )

        if weeks_ago in {1, 0}:
            repeat_count = 1 if weeks_ago == 1 else 2
            for event_index in range(repeat_count):
                session.add(
                    RepeatEvent(
                        call_id=call.id,
                        speaker="PARENT",
                        start_ms=180_000 + event_index * 90_000,
                        end_ms=181_200 + event_index * 90_000,
                        category="REPEAT_REQUEST",
                        matched_text="다시 한 번 말해줄래?",
                        rule_id="demo.repeat.again",
                        confidence=0.98,
                        rule_version="demo-seed-v1",
                        created_at=observed_at,
                    )
                )

        await session.flush()
        await signal_service.process_call(session, call)
        await session.commit()

    report = await ReportService().get_or_issue(
        session, parent_id, "WEEKLY", now.astimezone().date()
    )
    return DemoHistoryResult(
        parent_id=parent_id,
        calls_created=len(observed_times),
        first_observed_at=observed_times[0],
        last_observed_at=observed_times[-1],
        report_state=str(report["state"]),
        promoted_signal_count=len(report["promotedSignals"]),
    )


async def _delete_previous_demo_history(
    session: AsyncSession, *, parent_id: str, child_id: str
) -> None:
    demo_call_ids = list(
        await session.scalars(
            select(CallRecord.id).where(
                CallRecord.parent_id == parent_id,
                CallRecord.child_id == child_id,
                CallRecord.room_name.like(f"{DEMO_ROOM_PREFIX}%"),
            )
        )
    )
    if demo_call_ids:
        for model in (
            RepeatEvent,
            ExtractionEvidence,
            HealthExtraction,
            AcousticAnalysisRun,
            AcousticFeature,
            Transcript,
            AudioAsset,
            ChangeSignal,
        ):
            await session.execute(delete(model).where(model.call_id.in_(demo_call_ids)))
        await session.execute(delete(CallRecord).where(CallRecord.id.in_(demo_call_ids)))

    # Baselines and report snapshots are derived data. Recreate them after replacing the seed.
    await session.execute(delete(Baseline).where(Baseline.parent_id == parent_id))
    await session.execute(delete(Report).where(Report.parent_id == parent_id))
    await session.commit()


def _extraction_for_week(weeks_ago: int) -> dict[str, str | None]:
    if weeks_ago == 0:
        return {
            "symptom": "허리가 조금 불편하다고 말씀하셨어요.",
            "medication": "혈압약은 꾸준히 복용 중이라고 말씀하셨어요.",
            "activity": None,
            "sleep": "밤에 자주 깬다고 말씀하셨어요.",
        }
    if weeks_ago == 1:
        return {
            "symptom": None,
            "medication": "혈압약을 챙겨 먹었다고 말씀하셨어요.",
            "activity": "공원에서 산책했다고 말씀하셨어요.",
            "sleep": "잠을 한 번 깼다고 말씀하셨어요.",
        }
    return {
        "symptom": None,
        "medication": "혈압약을 복용했다고 말씀하셨어요.",
        "activity": "가볍게 산책했다고 말씀하셨어요.",
        "sleep": None,
    }
