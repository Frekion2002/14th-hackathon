from __future__ import annotations

import statistics
from datetime import UTC, date, datetime, timedelta
from typing import Any

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings
from app.models import AcousticFeature, Baseline, BaselineKind, CallRecord, ChangeSignal, Metric

METRIC_LABELS = {
    Metric.COUGH_EVENTS.value: "기침 횟수",
    Metric.SPEECH_RATE.value: "발화 속도",
    Metric.PAUSE_RATIO.value: "휴지 비율",
    Metric.F0_VARIATION.value: "기본주파수 변동",
}


def median_and_mad(values: list[float]) -> tuple[float, float]:
    center = float(statistics.median(values))
    raw_mad = float(statistics.median(abs(value - center) for value in values))
    floor = max(abs(center) * 0.01, 1e-6)
    return center, max(raw_mad, floor)


def compare(value: float, center: float, mad: float, threshold: float) -> dict[str, Any]:
    if center == 0:
        delta_pct = 0.0 if value == 0 else value * 100.0
    else:
        delta_pct = ((value - center) / abs(center)) * 100
    robust_z = 0.6745 * (value - center) / mad
    significant = abs(robust_z) > threshold
    direction = "STABLE"
    if significant:
        direction = "UP" if value > center else "DOWN"
    return {
        "deltaPct": round(delta_pct, 1),
        "direction": direction,
        "robustZ": round(robust_z, 2),
        "significant": significant,
    }


class SignalService:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings

    async def rebuild_baselines(
        self, session: AsyncSession, parent_id: str, exclude_call_id: str | None = None
    ) -> None:
        await session.execute(delete(Baseline).where(Baseline.parent_id == parent_id))
        today = datetime.now(UTC).date()
        rolling_from = today - timedelta(weeks=self.settings.baseline_window_weeks)
        for metric in Metric:
            for time_slot in ("MORNING", "AFTERNOON_EVENING"):
                statement = (
                    select(AcousticFeature.value, AcousticFeature.observed_at)
                    .join(CallRecord, CallRecord.id == AcousticFeature.call_id)
                    .where(
                        CallRecord.parent_id == parent_id,
                        CallRecord.time_slot == time_slot,
                        AcousticFeature.metric == metric.value,
                        AcousticFeature.status == "OK",
                        AcousticFeature.value.is_not(None),
                    )
                    .order_by(AcousticFeature.observed_at)
                )
                if exclude_call_id:
                    statement = statement.where(CallRecord.id != exclude_call_id)
                records = (await session.execute(statement)).all()
                for kind in BaselineKind:
                    selected = records
                    if kind == BaselineKind.ANCHOR and records:
                        first = records[0].observed_at.date()
                        selected = [
                            row
                            for row in records
                            if row.observed_at.date() <= first + timedelta(weeks=4)
                        ]
                        window_from = first
                        window_to = first + timedelta(weeks=4)
                    elif kind == BaselineKind.ROLLING:
                        selected = [
                            row for row in records if row.observed_at.date() >= rolling_from
                        ]
                        window_from = rolling_from
                        window_to = today
                    else:
                        window_from = today
                        window_to = today
                    values = [float(row.value) for row in selected]
                    ready = len(values) >= self.settings.baseline_required_samples
                    center, mad = median_and_mad(values) if ready else (None, None)
                    session.add(
                        Baseline(
                            parent_id=parent_id,
                            metric=metric.value,
                            time_slot=time_slot,
                            kind=kind.value,
                            status="READY" if ready else "COLLECTING",
                            sample_count=len(values),
                            required_count=self.settings.baseline_required_samples,
                            median=center,
                            mad=mad,
                            window_from=window_from,
                            window_to=window_to,
                            anchor_set_at=datetime.now(UTC)
                            if ready and kind == BaselineKind.ANCHOR
                            else None,
                        )
                    )
        await session.flush()

    async def process_call(self, session: AsyncSession, call: CallRecord) -> None:
        # The current measurement must never be part of the baseline it is compared with.
        await self.rebuild_baselines(session, call.parent_id, exclude_call_id=call.id)
        features = (
            await session.scalars(
                select(AcousticFeature).where(
                    AcousticFeature.call_id == call.id,
                    AcousticFeature.status == "OK",
                    AcousticFeature.value.is_not(None),
                )
            )
        ).all()
        if not features or not call.time_slot:
            return
        for feature in features:
            baselines = (
                await session.scalars(
                    select(Baseline).where(
                        Baseline.parent_id == call.parent_id,
                        Baseline.metric == feature.metric,
                        Baseline.time_slot == call.time_slot,
                    )
                )
            ).all()
            by_kind = {item.kind: item for item in baselines}
            anchor = by_kind.get(BaselineKind.ANCHOR.value)
            rolling = by_kind.get(BaselineKind.ROLLING.value)
            vs_anchor = (
                compare(
                    float(feature.value),
                    float(anchor.median),
                    float(anchor.mad),
                    self.settings.robust_z_threshold,
                )
                if anchor and anchor.status == "READY"
                else None
            )
            vs_rolling = (
                compare(
                    float(feature.value),
                    float(rolling.median),
                    float(rolling.mad),
                    self.settings.robust_z_threshold,
                )
                if rolling and rolling.status == "READY"
                else None
            )
            consecutive = await self._consecutive_count(
                session,
                call.parent_id,
                feature.metric,
                call.time_slot,
                vs_anchor,
            )
            promoted = consecutive >= self.settings.promoted_consecutive_weeks
            acute = bool(vs_rolling and vs_rolling["significant"])
            label = METRIC_LABELS[feature.metric]
            session.add(
                ChangeSignal(
                    parent_id=call.parent_id,
                    call_id=call.id,
                    metric=feature.metric,
                    time_slot=call.time_slot,
                    vs_anchor=vs_anchor,
                    vs_rolling=vs_rolling,
                    consecutive_weeks=consecutive,
                    promoted=promoted,
                    acute=acute,
                    summary_text=(
                        f"{label} {consecutive}주 연속 변화, 처음 대비 "
                        f"{vs_anchor['deltaPct']:+.0f}%"
                        if promoted and vs_anchor
                        else None
                    ),
                    acute_text=(
                        f"{label}, 지난달 대비 {vs_rolling['deltaPct']:+.0f}%"
                        if acute and vs_rolling
                        else None
                    ),
                    observed_at=feature.observed_at,
                )
            )
        await session.flush()
        # Persist the new measurement into the baseline only after its signal was computed.
        await self.rebuild_baselines(session, call.parent_id)

    async def _consecutive_count(
        self,
        session: AsyncSession,
        parent_id: str,
        metric: str,
        time_slot: str,
        comparison: dict[str, Any] | None,
    ) -> int:
        if not comparison or not comparison["significant"]:
            return 0
        previous = await session.scalar(
            select(ChangeSignal)
            .where(
                ChangeSignal.parent_id == parent_id,
                ChangeSignal.metric == metric,
                ChangeSignal.time_slot == time_slot,
                ChangeSignal.vs_anchor.is_not(None),
            )
            .order_by(ChangeSignal.observed_at.desc())
            .limit(1)
        )
        if not previous or previous.vs_anchor.get("direction") != comparison["direction"]:
            return 1
        return previous.consecutive_weeks + 1


def baseline_to_dict(item: Baseline) -> dict[str, Any]:
    now = date.today()
    anchor_age = None
    if item.anchor_set_at:
        anchor_age = max(0, (now - item.anchor_set_at.date()).days // 7)
    return {
        "parentId": item.parent_id,
        "metric": item.metric,
        "timeSlot": item.time_slot,
        "kind": item.kind,
        "status": item.status,
        "sampleCount": item.sample_count,
        "requiredCount": item.required_count,
        "remainingCalls": max(0, item.required_count - item.sample_count)
        if item.status == "COLLECTING"
        else None,
        "median": item.median,
        "mad": item.mad,
        "windowFrom": item.window_from,
        "windowTo": item.window_to,
        "anchorSetAt": item.anchor_set_at,
        "anchorAgeWeeks": anchor_age,
        "computedAt": item.computed_at,
    }


def signal_to_dict(item: ChangeSignal) -> dict[str, Any]:
    return {
        "signalId": item.id,
        "metric": item.metric,
        "timeSlot": item.time_slot,
        "vsAnchor": item.vs_anchor,
        "vsRolling": item.vs_rolling,
        "consecutiveWeeks": item.consecutive_weeks,
        "promoted": item.promoted,
        "acute": item.acute,
        "summaryText": item.summary_text,
        "acuteText": item.acute_text,
        "observedAt": item.observed_at,
    }
