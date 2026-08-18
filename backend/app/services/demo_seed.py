from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime, time, timedelta
from pathlib import Path
from typing import Any

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
from app.services.questions import DEFAULT_POOL, QUESTION_POOL
from app.services.reports import ReportService
from app.services.signals import SignalService, week_start

DEMO_ROOM_PREFIX = "demo-history-"
DEFAULT_SPEC_PATH = Path(__file__).resolve().parent.parent / "data" / "demo_history.json"
SELF_REPORT_FIELDS = ("symptom", "medication", "activity", "sleep")
KNOWN_QUESTION_IDS = frozenset(
    question_id
    for pool in (*QUESTION_POOL.values(), DEFAULT_POOL)
    for question_id, _ in pool
)


def load_spec(path: Path | str | None = None) -> list[dict[str, Any]]:
    """Read and validate the demo history spec.

    Validation is strict on purpose. A silently wrong time slot or question id produces a
    report that looks fine but has no baseline, which is worse than a hard failure.
    """

    spec = json.loads(Path(path or DEFAULT_SPEC_PATH).read_text(encoding="utf-8"))
    if not isinstance(spec, list) or not spec:
        raise ValueError("데모 seed spec은 비어 있지 않은 JSON 배열이어야 합니다")

    offsets = [item["weekOffset"] for item in spec]
    if len(set(offsets)) != len(offsets):
        raise ValueError(f"weekOffset이 중복됐습니다: {offsets}")
    if any(offset > 0 for offset in offsets):
        raise ValueError("weekOffset은 0 이하여야 합니다. 미래 주는 기준선에 들어가지 않습니다")
    if 0 not in offsets:
        raise ValueError(
            "weekOffset 0(이번 주)이 없습니다. 없으면 데모 당일 ROLLING이 표본 부족으로 떨어집니다"
        )

    slots = {TimeSlot.MORNING.value, TimeSlot.AFTERNOON_EVENING.value}
    rates: list[float] = []
    for item in spec:
        if item["timeSlot"] not in slots:
            raise ValueError(
                f"timeSlot이 잘못됐습니다: {item['timeSlot']}. 가능한 값 {sorted(slots)}"
            )
        unknown = set(item.get("askedQuestionIds", [])) - KNOWN_QUESTION_IDS
        if unknown:
            raise ValueError(f"질문 pool에 없는 questionId입니다: {sorted(unknown)}")
        missing = set(SELF_REPORT_FIELDS) - set(item.get("selfReport", {}))
        if missing:
            raise ValueError(
                f"selfReport에 {sorted(missing)}가 없습니다 (weekOffset {item['weekOffset']})"
            )
        rates.append(float(item["speechRate"]))

    if len(set(item["timeSlot"] for item in spec)) != 1:
        raise ValueError("기준선은 time slot별로 따로 쌓이므로 spec의 timeSlot은 하나여야 합니다")
    if len(set(rates)) == 1:
        raise ValueError("speechRate가 전부 같으면 MAD=0으로 기준선이 UNSCORABLE이 됩니다")

    return sorted(spec, key=lambda item: item["weekOffset"])


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
    spec_path: Path | str | None = None,
) -> DemoHistoryResult:
    """Replace only Collog's synthetic history for one demo family.

    The week-by-week content lives in `app/data/demo_history.json`, not here. Eight distinct
    ISO weeks are intentional: the earliest four form the anchor and the latest four form the
    rolling baseline. Only the already-working speech-rate metric is seeded. Cough, pause and
    F0 values are never fabricated for a demo.
    """

    if settings.app_env == "production":
        raise RuntimeError("시연용 더미 데이터는 production 환경에 넣을 수 없습니다")

    spec = load_spec(spec_path)

    now = now or datetime.now(UTC)
    if now.tzinfo is None:
        now = now.replace(tzinfo=UTC)
    else:
        now = now.astimezone(UTC)

    await _delete_previous_demo_history(session, parent_id=parent_id, child_id=child_id)
    signal_service = SignalService(settings)
    observed_times: list[datetime] = []

    current_week = week_start(now.date())
    for entry in spec:
        weeks_ago = -int(entry["weekOffset"])
        speech_rate = float(entry["speechRate"])
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
            time_slot=entry["timeSlot"],
            duration_sec=720,
            parent_speech_sec=360,
            asked_question_ids=list(entry.get("askedQuestionIds", [])),
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

        extraction = {field: entry["selfReport"].get(field) for field in SELF_REPORT_FIELDS}
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

        for event_index in range(int(entry.get("repeatCount", 0))):
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
