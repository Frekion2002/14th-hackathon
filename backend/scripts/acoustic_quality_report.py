from __future__ import annotations

import argparse
import asyncio
import json
from collections import Counter, defaultdict

from sqlalchemy import select

from app.config import Settings
from app.database import Database
from app.models import AcousticFeature, CallRecord

# 음향 지표의 품질 게이트 상수는 아직 실측으로 보정되지 않았다. 게이트를 조정하려면 먼저
# "실기기에서 어떤 사유로 얼마나 자주 측정에 실패하는가"를 알아야 하므로, 저장된 값에서
# metric별 성공률과 실패 사유 분포를 뽑는다.


async def report(analyzer_version: str | None) -> int:
    settings = Settings()
    database = Database(settings.database_url)

    async with database.sessions() as session:
        features = list(await session.scalars(select(AcousticFeature)))
        call_states = dict(
            (row.id, row.state)
            for row in await session.scalars(select(CallRecord))
        )

    if analyzer_version:
        features = [item for item in features if item.analyzer_version == analyzer_version]

    by_metric: dict[str, Counter[str]] = defaultdict(Counter)
    reasons: dict[str, Counter[str]] = defaultdict(Counter)
    sources: Counter[str] = Counter()
    for item in features:
        by_metric[item.metric][item.status] += 1
        if item.status != "OK":
            reasons[item.metric][item.unmeasurable_reason or "UNKNOWN"] += 1
        sources[item.audio_source or "UNKNOWN"] += 1

    summary = {
        "totalFeatures": len(features),
        "callStates": dict(Counter(call_states.values())),
        "audioSources": dict(sources),
        "metrics": {
            metric: {
                "ok": counts.get("OK", 0),
                "unmeasurable": sum(value for key, value in counts.items() if key != "OK"),
                "okRate": (
                    round(counts.get("OK", 0) / sum(counts.values()), 4)
                    if sum(counts.values())
                    else None
                ),
                "reasons": dict(reasons.get(metric, {})),
            }
            for metric, counts in sorted(by_metric.items())
        },
        "gates": {
            "qualityMinDurationSec": settings.quality_min_duration_sec,
            "qualityMaxClippingRatio": settings.quality_max_clipping_ratio,
            "qualityActivePercentile": settings.quality_active_percentile,
            "qualityMinActiveDbfs": settings.quality_min_active_dbfs,
            "pauseGapMs": [settings.pause_min_gap_ms, settings.pause_max_gap_ms],
            "parentMinSpeechSeconds": settings.parent_min_speech_seconds,
            "coughScoreThreshold": settings.cough_score_threshold,
            "analyzerVersion": settings.acoustic_analyzer_version,
        },
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(
        description="저장된 음향 지표의 측정 성공률과 실패 사유 분포를 집계한다"
    )
    parser.add_argument("--analyzer-version", help="특정 analyzer version만 집계")
    args = parser.parse_args()
    raise SystemExit(asyncio.run(report(args.analyzer_version)))


if __name__ == "__main__":
    main()
