from __future__ import annotations

import json
from datetime import UTC, datetime
from pathlib import Path

import pytest
from sqlalchemy import func, select

from app.config import Settings
from app.database import Database
from app.models import (
    AcousticFeature,
    Baseline,
    BaselineKind,
    CallRecord,
    ChangeSignal,
    Metric,
    Report,
    User,
)
from app.services.demo_seed import DEMO_ROOM_PREFIX, load_spec, replace_demo_history


async def test_demo_history_builds_distinct_anchor_and_rolling_baselines(tmp_path: Path) -> None:
    settings = Settings(
        app_env="test",
        database_url=f"sqlite+aiosqlite:///{tmp_path / 'demo.db'}",
        mock_external_services=True,
    )
    database = Database(settings.database_url)
    await database.ensure_schema(auto_reset=True)
    try:
        async with database.sessions() as session:
            session.add_all(
                [
                    User(id="child-id", role="CHILD", name="자녀", phone="01000000101"),
                    User(id="parent-id", role="PARENT", name="어머니", phone="01000000102"),
                ]
            )
            await session.commit()

            result = await replace_demo_history(
                session,
                parent_id="parent-id",
                child_id="child-id",
                settings=settings,
                now=datetime.now(UTC),
            )

            assert result.calls_created == 8
            assert result.report_state == "READY"
            assert result.promoted_signal_count == 1

            spec = load_spec()
            slot = spec[0]["timeSlot"]
            assert slot == "AFTERNOON_EVENING"

            baselines = list(
                await session.scalars(
                    select(Baseline).where(
                        Baseline.parent_id == "parent-id",
                        Baseline.metric == Metric.SPEECH_RATE.value,
                        Baseline.time_slot == slot,
                    )
                )
            )
            by_kind = {item.kind: item for item in baselines}
            anchor = by_kind[BaselineKind.ANCHOR.value]
            rolling = by_kind[BaselineKind.ROLLING.value]
            assert anchor.status == "READY"
            assert rolling.status == "READY"
            assert anchor.sample_count == 4
            assert rolling.sample_count == 4
            # A demo must show a drop, and MAD must stay non-zero or the baseline is UNSCORABLE.
            assert rolling.median < anchor.median
            assert anchor.mad > 0 and rolling.mad > 0

            # Calls carry the spec's slot and question ids, not hardcoded defaults.
            calls = list(
                await session.scalars(
                    select(CallRecord).where(CallRecord.parent_id == "parent-id")
                )
            )
            assert {call.time_slot for call in calls} == {slot}
            assert all(call.asked_question_ids for call in calls)

            promoted = list(
                await session.scalars(
                    select(ChangeSignal).where(ChangeSignal.promoted.is_(True))
                )
            )
            assert len(promoted) == 1
            assert promoted[0].consecutive_weeks == 4
            assert promoted[0].vs_anchor["direction"] == "DOWN"
            assert "발화 속도" in promoted[0].summary_text

            report = await session.scalar(
                select(Report).where(Report.parent_id == "parent-id")
            )
            assert report is not None
            assert report.snapshot["containsDemoData"] is True
            history = next(
                item
                for item in report.snapshot["recentAcousticHistory"]
                if item["metric"] == Metric.SPEECH_RATE.value
            )
            assert len(history["points"]) == 5
            assert {
                item.metric
                for item in await session.scalars(select(AcousticFeature))
            } == {Metric.SPEECH_RATE.value}

            # Re-running replaces the synthetic calls rather than accumulating duplicates.
            await replace_demo_history(
                session,
                parent_id="parent-id",
                child_id="child-id",
                settings=settings,
                now=datetime.now(UTC),
            )
            call_count = await session.scalar(
                select(func.count())
                .select_from(CallRecord)
                .where(CallRecord.room_name.like(f"{DEMO_ROOM_PREFIX}%"))
            )
            assert call_count == 8
    finally:
        await database.close()


def test_bundled_spec_covers_eight_weeks_including_the_current_one() -> None:
    spec = load_spec()
    offsets = [item["weekOffset"] for item in spec]
    assert offsets == [-7, -6, -5, -4, -3, -2, -1, 0]
    assert all(item["timeSlot"] == "AFTERNOON_EVENING" for item in spec)
    # No fabricated cough/pause/F0 values may leak into the spec.
    assert all(set(item) <= {
        "weekOffset",
        "timeSlot",
        "askedQuestionIds",
        "speechRate",
        "repeatCount",
        "selfReport",
    } for item in spec)


@pytest.mark.parametrize(
    ("mutate", "message"),
    [
        (lambda spec: [dict(item, speechRate=250) for item in spec], "MAD=0"),
        (
            lambda spec: [dict(item, askedQuestionIds=["does-not-exist"]) for item in spec],
            "질문 pool에 없는",
        ),
        (lambda spec: [item for item in spec if item["weekOffset"] != 0], "이번 주"),
        (lambda spec: [dict(item, timeSlot="NIGHT") for item in spec], "timeSlot이 잘못"),
    ],
)
def test_load_spec_rejects_specs_that_would_break_the_baseline(
    tmp_path: Path, mutate, message: str
) -> None:
    broken = mutate(load_spec())
    path = tmp_path / "broken.json"
    path.write_text(json.dumps(broken, ensure_ascii=False), encoding="utf-8")
    with pytest.raises(ValueError, match=message):
        load_spec(path)
