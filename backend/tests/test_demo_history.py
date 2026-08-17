from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path

from sqlalchemy import func, select

from app.config import Settings
from app.database import Database
from app.models import AcousticFeature, Baseline, BaselineKind, CallRecord, Metric, Report, User
from app.services.demo_seed import DEMO_ROOM_PREFIX, replace_demo_history


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

            baselines = list(
                await session.scalars(
                    select(Baseline).where(
                        Baseline.parent_id == "parent-id",
                        Baseline.metric == Metric.SPEECH_RATE.value,
                        Baseline.time_slot == "MORNING",
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
            assert anchor.median != rolling.median

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
