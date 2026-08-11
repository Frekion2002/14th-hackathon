from __future__ import annotations

import calendar
from datetime import UTC, date, datetime, timedelta
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import (
    AcousticFeature,
    Baseline,
    CallRecord,
    ChangeSignal,
    HealthExtraction,
    Report,
)
from app.services.signals import signal_to_dict

DISCLAIMER = "이 리포트는 의료 진단이 아니며 건강 변화 참고용입니다."
ADVISORY = "변화가 지속되거나 불편함이 있으면 의료진과 상담해보세요."


def period_bounds(period: str, target: date | None) -> tuple[date, date]:
    target = target or date.today()
    if period == "WEEKLY":
        start = target - timedelta(days=target.weekday())
        return start, start + timedelta(days=6)
    last_day = calendar.monthrange(target.year, target.month)[1]
    return target.replace(day=1), target.replace(day=last_day)


class ReportService:
    async def get_or_issue(
        self, session: AsyncSession, parent_id: str, period: str, target: date | None
    ) -> dict[str, Any]:
        from_date, to_date = period_bounds(period, target)
        start_dt = datetime.combine(from_date, datetime.min.time(), tzinfo=UTC)
        end_dt = datetime.combine(to_date + timedelta(days=1), datetime.min.time(), tzinfo=UTC)
        calls = (
            await session.scalars(
                select(CallRecord).where(
                    CallRecord.parent_id == parent_id,
                    CallRecord.ended_at >= start_dt,
                    CallRecord.ended_at < end_dt,
                    CallRecord.state.in_(["ANALYZED", "ANALYSIS_EXCLUDED"]),
                )
            )
        ).all()
        existing = await session.scalar(
            select(Report)
            .where(
                Report.parent_id == parent_id,
                Report.period == period,
                Report.from_date == from_date,
                Report.to_date == to_date,
            )
            .order_by(Report.issued_at.desc())
            .limit(1)
        )
        latest_call_at = max(
            (aware_datetime(call.ended_at) for call in calls if call.ended_at), default=None
        )
        if existing and (
            to_date < date.today()
            or latest_call_at is None
            or latest_call_at <= aware_datetime(existing.issued_at)
        ):
            return {**existing.snapshot, "issuedAt": existing.issued_at}
        analyzed_ids = [call.id for call in calls if call.state == "ANALYZED"]
        extractions = []
        features = []
        signals = []
        if analyzed_ids:
            extractions = list(
                await session.scalars(
                    select(HealthExtraction).where(HealthExtraction.call_id.in_(analyzed_ids))
                )
            )
            features = list(
                await session.scalars(
                    select(AcousticFeature).where(
                        AcousticFeature.call_id.in_(analyzed_ids), AcousticFeature.status == "OK"
                    )
                )
            )
            signals = list(
                await session.scalars(
                    select(ChangeSignal).where(ChangeSignal.call_id.in_(analyzed_ids))
                )
            )
        collecting = await session.scalar(
            select(Baseline)
            .where(Baseline.parent_id == parent_id, Baseline.status == "COLLECTING")
            .limit(1)
        )
        state = "EMPTY" if not calls else "BASELINE_COLLECTING" if collecting else "READY"
        conversation_items = {
            field: [value for row in extractions if (value := getattr(row, field))]
            for field in ("symptom", "medication", "activity", "sleep")
        }
        trends: dict[str, list[dict[str, Any]]] = {}
        for feature in features:
            trends.setdefault(feature.metric, []).append(
                {"date": feature.observed_at.date().isoformat(), "value": feature.value}
            )
        promoted = [signal_to_dict(item) for item in signals if item.promoted]
        acute = [signal_to_dict(item) for item in signals if item.acute]
        issued_at = datetime.now(UTC)
        snapshot = {
            "parentId": parent_id,
            "period": period,
            "from": from_date.isoformat(),
            "to": to_date.isoformat(),
            "state": state,
            "emptyMessage": "이번 기간에 분석된 통화가 없어요" if state == "EMPTY" else None,
            "disclaimer": DISCLAIMER,
            "advisory": ADVISORY if promoted else None,
            "promotedSignals": promoted,
            "acuteSignals": acute,
            "conversationItems": conversation_items,
            "acousticTrends": [
                {"metric": metric, "points": points} for metric, points in trends.items()
            ],
            "analyzedCallCount": len(analyzed_ids),
        }
        session.add(
            Report(
                parent_id=parent_id,
                period=period,
                from_date=from_date,
                to_date=to_date,
                state=state,
                snapshot=snapshot,
                issued_at=issued_at,
            )
        )
        await session.commit()
        return {**snapshot, "issuedAt": issued_at}


def aware_datetime(value: datetime) -> datetime:
    return value if value.tzinfo else value.replace(tzinfo=UTC)
