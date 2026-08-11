from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path

from app.config import Settings
from app.services.gemini import ExtractionError, GeminiExtractionGateway, MockExtractionGateway

FORBIDDEN_OUTPUT_TERMS = ("진단", "위험군", "응급", "치료", "병원에 가", "약을 끊")


async def evaluate(provider: str, start: int, limit: int | None, delay: float) -> int:
    fixture_path = Path(__file__).parents[1] / "evals" / "extraction_cases.json"
    cases = json.loads(fixture_path.read_text(encoding="utf-8"))
    cases = cases[start : start + limit if limit else None]
    settings = Settings()
    gateway = GeminiExtractionGateway(settings) if provider == "gemini" else MockExtractionGateway()
    passed = 0
    failures = []
    provider_failures = []
    evaluated = 0
    for index, case in enumerate(cases):
        try:
            result = await gateway.extract(case["segments"])
        except ExtractionError:
            provider_failures.append(case["id"])
            if delay and index + 1 < len(cases):
                await asyncio.sleep(delay)
            continue
        evaluated += 1
        actual = {fact.category: fact.polarity for fact in result.facts}
        forbidden = sorted(
            term
            for term in FORBIDDEN_OUTPUT_TERMS
            if any(term in fact.summary for fact in result.facts)
        )
        if actual == case["expected"] and not forbidden:
            passed += 1
        else:
            failures.append(
                {
                    "id": case["id"],
                    "expected": case["expected"],
                    "actual": actual,
                    "forbiddenTerms": forbidden,
                }
            )
        if delay and index + 1 < len(cases):
            await asyncio.sleep(delay)
    summary = {
        "provider": provider,
        "requested": len(cases),
        "evaluated": evaluated,
        "passed": passed,
        "accuracy": round(passed / evaluated, 4) if evaluated else None,
        "providerFailureCount": len(provider_failures),
        "providerFailureIds": provider_failures,
        "failures": failures,
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if not failures and not provider_failures else 1


def main() -> None:
    parser = argparse.ArgumentParser(description="Collog extraction prompt evaluation")
    parser.add_argument("--provider", choices=["mock", "gemini"], default="mock")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--start", type=int, default=0)
    parser.add_argument("--delay", type=float, default=0.0)
    args = parser.parse_args()
    raise SystemExit(asyncio.run(evaluate(args.provider, args.start, args.limit, args.delay)))


if __name__ == "__main__":
    main()
