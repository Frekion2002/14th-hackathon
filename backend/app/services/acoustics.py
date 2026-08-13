from __future__ import annotations

import asyncio
import io
import math
import re
import wave
from dataclasses import dataclass
from typing import Any, Literal

import numpy as np

from app.config import Settings
from app.models import Metric


@dataclass(slots=True)
class AcousticMeasurement:
    metric: Metric
    value: float | None
    unit: str
    status: str
    unmeasurable_reason: str | None


@dataclass(slots=True)
class AcousticAnalysisInput:
    audio: bytes
    content_type: str
    declared_sample_rate: int | None
    source: Literal["DEVICE_RAW", "WEBRTC_EGRESS"]
    parent_segments: list[dict[str, Any]]
    parent_speech_seconds: float


@dataclass(slots=True)
class Waveform:
    samples: np.ndarray
    sample_rate: int


class AudioDecodeError(ValueError):
    pass


class AcousticAnalyzer:
    async def analyze(self, item: AcousticAnalysisInput) -> list[AcousticMeasurement]:
        raise NotImplementedError


class CollogAcousticAnalyzer(AcousticAnalyzer):
    """Versioned, conservative prototype analyzer for the four hackathon metrics.

    Speech timing metrics come from Deepgram. F0 and cough-candidate metrics only use the
    consented iOS PCM WAV. Every failure is explicit; this class never fabricates a fallback value.
    """

    def __init__(self, settings: Settings) -> None:
        self.settings = settings

    async def analyze(self, item: AcousticAnalysisInput) -> list[AcousticMeasurement]:
        if item.parent_speech_seconds < self.settings.parent_min_speech_seconds:
            return [
                unmeasurable(metric, unit, "INSUFFICIENT_PARENT_SPEECH")
                for metric, unit in (
                    (Metric.SPEECH_RATE, "음절/분"),
                    (Metric.PAUSE_RATIO, "%"),
                    (Metric.F0_VARIATION, "semitone_mad"),
                    (Metric.COUGH_EVENTS, "회"),
                )
            ]
        timing = [self._speech_rate(item), self._pause_ratio(item)]
        if item.source != "DEVICE_RAW":
            return timing + [
                unmeasurable(Metric.F0_VARIATION, "semitone_mad", "SOURCE_NOT_RAW"),
                unmeasurable(Metric.COUGH_EVENTS, "회", "SOURCE_NOT_RAW"),
            ]
        if item.content_type.split(";", 1)[0].strip().lower() not in {
            "audio/wav",
            "audio/wave",
            "audio/x-wav",
        }:
            return timing + [
                unmeasurable(Metric.F0_VARIATION, "semitone_mad", "UNSUPPORTED_AUDIO_FORMAT"),
                unmeasurable(Metric.COUGH_EVENTS, "회", "UNSUPPORTED_AUDIO_FORMAT"),
            ]
        try:
            waveform = await asyncio.to_thread(
                decode_pcm_wav, item.audio, item.declared_sample_rate
            )
        except AudioDecodeError as exc:
            reason = str(exc) or "INVALID_AUDIO"
            return timing + [
                unmeasurable(Metric.F0_VARIATION, "semitone_mad", reason),
                unmeasurable(Metric.COUGH_EVENTS, "회", reason),
            ]

        quality_reason = waveform_quality_reason(waveform, self.settings)
        if quality_reason:
            return timing + [
                unmeasurable(Metric.F0_VARIATION, "semitone_mad", quality_reason),
                unmeasurable(Metric.COUGH_EVENTS, "회", quality_reason),
            ]
        f0, cough = await asyncio.to_thread(self._waveform_metrics, waveform)
        return timing + [f0, cough]

    def _speech_rate(self, item: AcousticAnalysisInput) -> AcousticMeasurement:
        words = valid_words(item.parent_segments)
        syllables = sum(len(re.findall(r"[가-힣]", str(word.get("text", "")))) for word in words)
        articulation_seconds = (
            sum(max(0, int(word.get("endMs", 0)) - int(word.get("startMs", 0))) for word in words)
            / 1000
        )
        if syllables < 10 or articulation_seconds < 5:
            return unmeasurable(Metric.SPEECH_RATE, "음절/분", "INSUFFICIENT_WORD_TIMING")
        return measured(Metric.SPEECH_RATE, 60 * syllables / articulation_seconds, "음절/분")

    def _pause_ratio(self, item: AcousticAnalysisInput) -> AcousticMeasurement:
        pause_ms = 0
        window_ms = 0
        usable_utterances = 0
        for segment in item.parent_segments:
            words = valid_words([segment])
            if len(words) < 2:
                continue
            words.sort(key=lambda word: int(word.get("startMs", 0)))
            current_window = int(words[-1].get("endMs", 0)) - int(words[0].get("startMs", 0))
            if current_window <= 0:
                continue
            usable_utterances += 1
            window_ms += current_window
            for previous, current in zip(words, words[1:], strict=False):
                gap = int(current.get("startMs", 0)) - int(previous.get("endMs", 0))
                if self.settings.pause_min_gap_ms <= gap <= self.settings.pause_max_gap_ms:
                    pause_ms += gap
        if usable_utterances < 1 or window_ms <= 0:
            return unmeasurable(Metric.PAUSE_RATIO, "%", "INSUFFICIENT_WORD_TIMING")
        return measured(Metric.PAUSE_RATIO, pause_ms / window_ms * 100, "%")

    def _waveform_metrics(
        self, waveform: Waveform
    ) -> tuple[AcousticMeasurement, AcousticMeasurement]:
        samples = resample_16k(waveform.samples, waveform.sample_rate)
        return self._f0_variation(samples, 16_000), self._cough_candidates(samples, 16_000)

    def _f0_variation(self, samples: np.ndarray, sample_rate: int) -> AcousticMeasurement:
        import librosa

        f0, voiced, probability = librosa.pyin(
            samples,
            fmin=65,
            fmax=400,
            sr=sample_rate,
            frame_length=2048,
            hop_length=256,
            fill_na=np.nan,
        )
        mask = voiced & np.isfinite(f0) & (probability >= 0.8)
        valid = np.asarray(f0[mask], dtype=np.float64)
        if valid.size * 256 / sample_rate < 2:
            return unmeasurable(Metric.F0_VARIATION, "semitone_mad", "INSUFFICIENT_VOICED_AUDIO")
        jumps = np.abs(12 * np.log2(valid[1:] / valid[:-1])) if valid.size > 1 else np.array([])
        if jumps.size and float(np.mean(jumps > 12)) > 0.15:
            return unmeasurable(Metric.F0_VARIATION, "semitone_mad", "PITCH_UNSTABLE")
        center_hz = float(np.median(valid))
        semitones = 12 * np.log2(valid / center_hz)
        center = float(np.median(semitones))
        spread = 1.4826 * float(np.median(np.abs(semitones - center)))
        return measured(Metric.F0_VARIATION, spread, "semitone_mad")

    def _cough_candidates(self, samples: np.ndarray, sample_rate: int) -> AcousticMeasurement:
        frame_length = round(0.96 * sample_rate)
        hop_length = round(0.48 * sample_rate)
        if samples.size < frame_length:
            return unmeasurable(Metric.COUGH_EVENTS, "회", "AUDIO_TOO_SHORT")
        frames = np.lib.stride_tricks.sliding_window_view(samples, frame_length)[::hop_length]
        if not len(frames):
            return unmeasurable(Metric.COUGH_EVENTS, "회", "AUDIO_TOO_SHORT")
        window = np.hanning(frame_length)
        rms = np.sqrt(np.mean(frames**2, axis=1) + 1e-12)
        db = 20 * np.log10(rms + 1e-12)
        median_db = float(np.median(db))
        energy_score = np.clip((db - median_db - 6) / 18, 0, 1)
        spectrum = np.abs(np.fft.rfft(frames * window, axis=1)) ** 2
        frequencies = np.fft.rfftfreq(frame_length, 1 / sample_rate)
        total_power = np.sum(spectrum, axis=1) + 1e-12
        high_ratio = np.sum(spectrum[:, frequencies >= 1_000], axis=1) / total_power
        high_score = np.clip((high_ratio - 0.15) / 0.55, 0, 1)
        zcr = np.mean(np.diff(np.signbit(frames), axis=1), axis=1)
        zcr_score = np.clip((zcr - 0.03) / 0.22, 0, 1)
        crest = np.max(np.abs(frames), axis=1) / (rms + 1e-9)
        crest_score = np.clip((crest - 3) / 8, 0, 1)
        scores = 0.4 * energy_score + 0.25 * high_score + 0.2 * zcr_score + 0.15 * crest_score
        candidates = np.flatnonzero(scores >= self.settings.cough_score_threshold)
        count = merge_patch_events(candidates, hop_length / sample_rate, merge_gap_seconds=0.75)
        return measured(Metric.COUGH_EVENTS, float(count), "회")


def valid_words(segments: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        word
        for segment in segments
        for word in segment.get("words", [])
        if str(word.get("text", "")).strip()
        and (word.get("confidence") is None or float(word["confidence"]) >= 0.5)
        and int(word.get("endMs", 0)) > int(word.get("startMs", 0))
    ]


def decode_pcm_wav(audio: bytes, declared_sample_rate: int | None = None) -> Waveform:
    try:
        with wave.open(io.BytesIO(audio), "rb") as wav:
            if wav.getcomptype() != "NONE":
                raise AudioDecodeError("INVALID_AUDIO")
            channels = wav.getnchannels()
            sample_width = wav.getsampwidth()
            sample_rate = wav.getframerate()
            frames = wav.readframes(wav.getnframes())
    except (EOFError, wave.Error) as exc:
        raise AudioDecodeError("INVALID_AUDIO") from exc
    if channels not in {1, 2} or sample_rate not in {16_000, 24_000, 44_100, 48_000}:
        raise AudioDecodeError("UNSUPPORTED_SAMPLE_RATE")
    if declared_sample_rate and declared_sample_rate != sample_rate:
        raise AudioDecodeError("SAMPLE_RATE_MISMATCH")
    if sample_width == 1:
        samples = (np.frombuffer(frames, dtype=np.uint8).astype(np.float32) - 128) / 128
    elif sample_width == 2:
        samples = np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768
    elif sample_width == 3:
        raw = np.frombuffer(frames, dtype=np.uint8).reshape(-1, 3)
        values = raw[:, 0].astype(np.int32) | (raw[:, 1].astype(np.int32) << 8)
        values |= raw[:, 2].astype(np.int32) << 16
        values = np.where(values & 0x800000, values - 0x1000000, values)
        samples = values.astype(np.float32) / 8_388_608
    elif sample_width == 4:
        samples = np.frombuffer(frames, dtype="<i4").astype(np.float32) / 2_147_483_648
    else:
        raise AudioDecodeError("INVALID_AUDIO")
    if not samples.size or samples.size % channels:
        raise AudioDecodeError("INVALID_AUDIO")
    samples = samples.reshape(-1, channels).mean(axis=1)
    return Waveform(np.ascontiguousarray(samples, dtype=np.float32), sample_rate)


def waveform_quality_reason(waveform: Waveform, settings: Settings) -> str | None:
    samples = waveform.samples
    if samples.size / waveform.sample_rate < settings.quality_min_duration_sec:
        return "AUDIO_TOO_SHORT"
    if float(np.mean(np.abs(samples) >= 0.999)) >= settings.quality_max_clipping_ratio:
        return "EXCESSIVE_CLIPPING"
    frame_size = max(1, round(0.05 * waveform.sample_rate))
    usable_size = samples.size - samples.size % frame_size
    frames = samples[:usable_size].reshape(-1, frame_size)
    frame_rms = np.sqrt(np.mean(frames**2, axis=1) + 1e-12)
    active_rms = float(np.percentile(frame_rms, settings.quality_active_percentile))
    if 20 * math.log10(active_rms + 1e-12) <= settings.quality_min_active_dbfs:
        return "SIGNAL_TOO_QUIET"
    return None


def resample_16k(samples: np.ndarray, sample_rate: int) -> np.ndarray:
    if sample_rate == 16_000:
        return samples
    import librosa

    return np.asarray(
        librosa.resample(samples, orig_sr=sample_rate, target_sr=16_000, res_type="soxr_hq"),
        dtype=np.float32,
    )


def merge_patch_events(
    candidate_indices: np.ndarray, hop_seconds: float, merge_gap_seconds: float
) -> int:
    if not candidate_indices.size:
        return 0
    count = 1
    previous_time = float(candidate_indices[0]) * hop_seconds
    for index in candidate_indices[1:]:
        current_time = float(index) * hop_seconds
        if current_time - previous_time > merge_gap_seconds:
            count += 1
        previous_time = current_time
    return count


def measured(metric: Metric, value: float, unit: str) -> AcousticMeasurement:
    return AcousticMeasurement(metric, round(float(value), 4), unit, "OK", None)


def unmeasurable(metric: Metric, unit: str, reason: str) -> AcousticMeasurement:
    return AcousticMeasurement(metric, None, unit, "UNMEASURABLE", reason)


def create_acoustic_analyzer(settings: Settings) -> AcousticAnalyzer:
    return CollogAcousticAnalyzer(settings)
