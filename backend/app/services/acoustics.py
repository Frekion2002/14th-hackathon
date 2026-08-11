from __future__ import annotations

from dataclasses import dataclass

from app.models import Metric


@dataclass(slots=True)
class AcousticMeasurement:
    metric: Metric
    value: float | None
    unit: str
    status: str
    unmeasurable_reason: str | None


class AcousticAnalyzer:
    async def analyze(self, audio: bytes, sample_rate: int | None) -> list[AcousticMeasurement]:
        raise NotImplementedError


class UnconfiguredAcousticAnalyzer(AcousticAnalyzer):
    """Honest placeholder until a validated cough/F0 pipeline is selected.

    Returning fabricated measurements would immediately contaminate each parent's fixed anchor.
    The API therefore records explicit UNMEASURABLE values and still purges the raw audio.
    """

    async def analyze(self, audio: bytes, sample_rate: int | None) -> list[AcousticMeasurement]:
        del audio, sample_rate
        units = {
            Metric.COUGH_EVENTS: "회",
            Metric.SPEECH_RATE: "음절/초",
            Metric.PAUSE_RATIO: "%",
            Metric.F0_VARIATION: "%",
        }
        return [
            AcousticMeasurement(
                metric=metric,
                value=None,
                unit=units[metric],
                status="UNMEASURABLE",
                unmeasurable_reason="EXTRACTION_ERROR",
            )
            for metric in Metric
        ]
