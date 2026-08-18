from __future__ import annotations

import argparse
import asyncio
import io
import json
import sys
import wave
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import httpx

from app.config import Settings
from app.services.http import request_with_retry

# 기준선과 변화 신호는 calendar week 단위로 계산된다. 주 1회 통화를 여러 주에 걸쳐 쌓아야
# 앵커 기준선(4주)과 롤링 기준선/승격 신호(그 이후)를 눈으로 확인할 수 있는데, 실기기로
# 여러 주를 기다릴 수 없다. ElevenLabs로 주차별 부모/자녀 음성을 합성하고 replay_call로
# 과거 주차에 넣어 실제 파이프라인(STT→Gemini→음향→기준선)을 그대로 태운다. 개발 전용이다.
#
# 부모 발화가 PARENT_MIN_SPEECH_SECONDS 미만이면 통화가 ANALYSIS_EXCLUDED로 빠지므로
# 대본은 넉넉히 길게 잡는다.

PCM_SAMPLE_RATE = 24_000
PCM_OUTPUT_FORMAT = f"pcm_{PCM_SAMPLE_RATE}"


class MockDataError(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class WeekScript:
    label: str
    parent: str
    child: str


# 앞 4주는 안정적인 기준선, 뒤 4주는 악화 추세다. 기침 언급과 되묻기가 늘고 복약이
# 흔들리도록 써서 change signal이 실제로 잡히는지 확인한다.
BASELINE_WEEKS: list[WeekScript] = [
    WeekScript(
        label="안정-1",
        parent=(
            "어 그래, 잘 지내지. 오늘 아침에 혈압약은 챙겨서 먹었어. "
            "요즘은 밥맛도 괜찮고 잠도 그럭저럭 잘 자는 편이야. "
            "저녁 아홉 시쯤 누우면 금방 잠들고 아침 여섯 시에 저절로 눈이 떠진다. "
            "어제는 동네 한 바퀴 삼십 분쯤 걷고 왔는데 다리도 안 아프고 좋더라. "
            "요새 날이 선선해져서 걷기에 딱 좋아. 내일도 나갈 생각이다. "
            "머리 아픈 것도 없고 어지럽지도 않았어. 걱정 안 해도 된다. "
            "너는 회사 일은 어떠냐. 너무 무리하지 말고 밥 잘 챙겨 먹어라."
        ),
        child="어머니 오늘 혈압약은 챙겨 드셨어요? 머리 아프거나 어지럽진 않으셨어요?",
    ),
    WeekScript(
        label="안정-2",
        parent=(
            "응 약은 오늘도 아침에 먹었지. 하루도 안 빼먹고 있어. "
            "이번 주는 날이 좋아서 매일 아침에 산책을 나갔다. 한 사십 분씩 걸었어. "
            "공원에 가면 아는 사람들도 만나고 이야기도 하고 그러니까 시간이 잘 가더라. "
            "잠은 열한 시쯤 자서 여섯 시에 일어나니까 잘 자는 거지. 중간에 깨지도 않아. "
            "밥도 세 끼 꼬박꼬박 챙겨 먹고 있고 반찬도 골고루 해서 먹는다. "
            "어지러운 건 전혀 없었고 컨디션도 괜찮았어. 너나 잘 챙겨 먹고 다녀라."
        ),
        child="어머니 이번 주는 어떠셨어요? 약은 잘 챙겨 드시고 계세요?",
    ),
    WeekScript(
        label="안정-3",
        parent=(
            "그래 나야 뭐 늘 똑같지. 혈압약은 아침마다 잊지 않고 먹고 있어. "
            "지난주에 병원 가서 혈압 쟀는데 정상이라고 하더라. 의사 선생님이 잘 관리하고 있대. "
            "약도 그대로 계속 먹으면 된다고 하고 다음 진료는 두 달 뒤에 오라고 했어. "
            "산책도 계속 하고 있고 잠도 푹 자고 있어. 머리 아픈 건 없었어. "
            "요새는 저녁 먹고 나서도 한 바퀴 더 돌고 들어와. 그러면 잠이 더 잘 오더라. "
            "그러니까 걱정하지 말고 너나 몸 잘 챙겨라."
        ),
        child="어머니 병원은 다녀오셨어요? 혈압은 어떻게 나왔어요?",
    ),
    WeekScript(
        label="안정-4",
        parent=(
            "어 오늘도 약 먹었어. 걱정하지 마라. 아침에 밥 먹고 바로 챙겨 먹는다. "
            "이번 주도 별일 없이 잘 지냈다. 아침에 일어나서 산책하고 밥 먹고 그러고 있어. "
            "어제는 시장에 가서 장도 보고 왔는데 다리 아픈 것도 없고 멀쩡하더라. "
            "잠도 잘 오고 어지럽거나 그런 것도 없었어. 몸은 아주 괜찮아. "
            "기침이나 감기 기운도 전혀 없고 목도 안 아프다. "
            "너는 밥은 잘 먹고 다니냐. 끼니 거르지 말고 챙겨 먹어라."
        ),
        child="어머니 이번 주도 별일 없으셨죠? 잠은 잘 주무세요?",
    ),
]

DECLINE_WEEKS: list[WeekScript] = [
    WeekScript(
        label="악화-1",
        parent=(
            "어 그래. 음, 약은 먹었나. 아마 먹었을 거야. 아침에 먹은 것 같기도 하고. "
            "근데 요 며칠 기침이 좀 나더라. 콜록, 콜록. 목이 좀 칼칼해. "
            "환절기라 그런가 싶기도 한데 며칠째 계속 그러네. "
            "잠도 좀 설쳤어. 새벽에 두 번씩 깨더라고. 그러고 나면 다시 잠들기가 힘들어. "
            "산책은 좀 못 나갔어. 날도 쌀쌀하고 기운도 없고 해서 그냥 집에 있었다. "
            "어? 뭐라고? 잘 안 들리네. 다시 말해봐라."
        ),
        child="어머니 기침을 하시네요? 약은 챙겨 드셨어요?",
    ),
    WeekScript(
        label="악화-2",
        parent=(
            "응? 뭐라고 했지? 아 약 말이구나. "
            "어제는 깜빡하고 저녁 약을 안 먹었어. 요즘 자꾸 잊어버린다. "
            "달력에 표시를 해놔도 그걸 또 안 보게 되더라고. "
            "기침은 계속 나. 콜록. 특히 밤에 심해서 잠을 못 자겠어. "
            "누우면 더 심해져서 앉아서 한참 있다가 다시 눕고 그런다. "
            "머리도 좀 무겁고 어지러울 때가 있더라. 산책은 거의 못 했다. "
            "기운이 없어서 그냥 누워만 있게 되네."
        ),
        child="어머니 약을 빠뜨리셨어요? 기침은 좀 어떠세요?",
    ),
    WeekScript(
        label="악화-3",
        parent=(
            "어, 어? 응 뭐라고? 아 그래 그래. "
            "이번 주는 약을 두 번인가 세 번인가 빼먹은 것 같아. 잘 기억이 안 나네. "
            "약통을 봐도 몇 개 남았는지 헷갈리고 그래. "
            "기침이 더 심해졌어. 콜록, 콜록. 가래도 좀 나오고. "
            "말을 좀 오래 하면 목이 잠기고 기침이 나와서 힘들다. "
            "밤에 자꾸 깨서 잠을 제대로 못 자. 어지러운 것도 더 자주 있어. "
            "산책은 아예 못 나가고 있다."
        ),
        child="어머니 병원에 가보셔야 하는 거 아니에요? 기침이 오래가네요.",
    ),
    WeekScript(
        label="악화-4",
        parent=(
            "뭐? 응? 잘 안 들려. 크게 좀 말해봐. "
            "약은... 글쎄 요즘 자꾸 잊어버려서 잘 못 챙겨 먹었어. "
            "이번 주는 절반은 빼먹은 것 같다. 미안하다 자꾸 이래서. "
            "기침은 여전해. 콜록. 밤새 기침하느라 잠을 거의 못 잤다. "
            "새벽 세 시에 깨서 그냥 앉아 있었어. 그러다 아침이 되더라. "
            "어지러워서 어제는 앉았다 일어나다가 휘청했어. 벽을 짚고 겨우 섰다. "
            "산책은 못 나가고 있어. 기운이 하나도 없다."
        ),
        child="어머니 어지러우셨다고요? 병원 같이 가요.",
    ),
]


async def synthesize(
    client: httpx.AsyncClient, settings: Settings, voice_id: str, text: str
) -> bytes:
    response = await request_with_retry(
        client,
        "POST",
        f"{settings.elevenlabs_base_url.rstrip('/')}/v1/text-to-speech/{voice_id}",
        params={"output_format": PCM_OUTPUT_FORMAT},
        headers={
            "xi-api-key": settings.elevenlabs_api_key,
            "accept": "audio/pcm",
        },
        json={
            "text": text,
            "model_id": settings.elevenlabs_model,
            "voice_settings": {"stability": 0.5, "similarity_boost": 0.75},
        },
    )
    return response.content


def to_wav(pcm: bytes) -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(PCM_SAMPLE_RATE)
        handle.writeframes(pcm)
    return buffer.getvalue()


def wav_seconds(payload: bytes) -> float:
    with wave.open(io.BytesIO(payload), "rb") as handle:
        return handle.getnframes() / handle.getframerate()


def parse_state(stdout: str) -> str | None:
    """replay_call이 마지막에 출력하는 report JSON에서 통화 상태만 꺼낸다.

    파이프라인이 로그로 traceback을 찍는 경우가 있어 첫 중괄호를 쓰면 안 된다.
    report는 항상 줄 맨 앞의 `{`로 시작하므로 그중 마지막 것을 쓴다.
    """
    for start in reversed([0] + [i + 1 for i, ch in enumerate(stdout) if ch == "\n"]):
        if not stdout.startswith("{", start):
            continue
        try:
            return json.loads(stdout[start:]).get("state")
        except json.JSONDecodeError:
            continue
    return None


def minutes_ago_for(week_index: int, total_weeks: int, hour: int) -> int:
    """가장 오래된 주가 week_index=0이 되도록 과거로 민다.

    calendar week 경계에 걸치지 않게 각 주의 같은 요일 같은 시각을 노린다.
    """
    weeks_back = total_weeks - week_index
    target = datetime.now(ZoneInfo("Asia/Seoul")) - timedelta(weeks=weeks_back)
    target = target.replace(hour=hour, minute=0, second=0, microsecond=0)
    delta = datetime.now(UTC) - target.astimezone(UTC)
    return max(1, int(delta.total_seconds() // 60))


async def build(args: argparse.Namespace) -> int:
    settings = Settings()
    if not settings.elevenlabs_api_key:
        raise MockDataError("ELEVENLABS_API_KEY가 필요합니다")
    parent_voice = args.parent_voice or settings.elevenlabs_voice_id
    child_voice = args.child_voice or settings.elevenlabs_voice_id
    if not parent_voice:
        raise MockDataError("ELEVENLABS_VOICE_ID 또는 --parent-voice가 필요합니다")

    scripts = (BASELINE_WEEKS + DECLINE_WEEKS)[: args.weeks]
    if len(scripts) < args.weeks:
        raise MockDataError(f"대본은 최대 {len(BASELINE_WEEKS + DECLINE_WEEKS)}주까지 있습니다")

    out_dir = Path(args.out_dir)
    await asyncio.to_thread(out_dir.mkdir, parents=True, exist_ok=True)
    outcomes: list[tuple[str, str]] = []

    async with httpx.AsyncClient(timeout=120.0) as client:
        for index, script in enumerate(scripts):
            parent_wav = out_dir / f"week{index + 1:02d}-parent.wav"
            child_wav = out_dir / f"week{index + 1:02d}-child.wav"
            if parent_wav.exists() and child_wav.exists() and not args.force:
                print(f"[{script.label}] 이미 있음, 합성 건너뜀")
            else:
                parent_audio = to_wav(
                    await synthesize(client, settings, parent_voice, script.parent)
                )
                child_audio = to_wav(await synthesize(client, settings, child_voice, script.child))
                parent_wav.write_bytes(parent_audio)
                child_wav.write_bytes(child_audio)
                print(
                    f"[{script.label}] 합성 완료 "
                    f"부모 {wav_seconds(parent_audio):.1f}s / 자녀 {wav_seconds(child_audio):.1f}s"
                )

            parent_seconds = wav_seconds(parent_wav.read_bytes())
            if parent_seconds < settings.parent_min_speech_seconds:
                print(
                    f"  경고: 부모 발화 {parent_seconds:.1f}s < "
                    f"{settings.parent_min_speech_seconds}s. 이 통화는 분석에서 제외된다"
                )

            if args.audio_only:
                continue

            minutes = minutes_ago_for(index, len(scripts), args.hour)
            when = datetime.now(ZoneInfo("Asia/Seoul")) - timedelta(minutes=minutes)
            print(f"  replay → {when:%Y-%m-%d %H:%M} (KST, {minutes}분 전)")
            process = await asyncio.create_subprocess_exec(
                sys.executable,
                "-m",
                "scripts.replay_call",
                "--parent-audio",
                str(parent_wav),
                "--child-audio",
                str(child_wav),
                "--raw-audio",
                str(parent_wav),
                "--child-phone",
                args.child_phone,
                "--parent-phone",
                args.parent_phone,
                "--minutes-ago",
                str(minutes),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            raw_out, raw_err = await process.communicate()
            out = raw_out.decode(errors="replace")
            err = raw_err.decode(errors="replace")
            state = parse_state(out)
            # replay_call은 ANALYZED가 아니면 exit 1을 준다. 부모 발화가 짧아 제외된 통화도
            # 여기 해당하는데, 그건 파이프라인이 규칙대로 동작한 결과이므로 남은 주차까지
            # 중단시키지 않는다. 스크립트 자체가 죽은 경우에만 멈춘다.
            if state is None:
                raise MockDataError(f"[{script.label}] replay 실패\n{out[-1500:]}\n{err[-1500:]}")
            outcomes.append((script.label, state))
            marker = "OK" if state == "ANALYZED" else "제외"
            print(f"    → {state} ({marker})")

    print(f"\n완료: {len(outcomes)}주치 처리")
    for label, state in outcomes:
        print(f"  {label}: {state}")
    excluded = [label for label, state in outcomes if state != "ANALYZED"]
    if excluded:
        print(
            f"\n분석에서 제외된 주: {', '.join(excluded)}"
            f"\n부모 발화가 {settings.parent_min_speech_seconds}초를 넘어야 기준선 표본이 된다."
        )
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(
        description="ElevenLabs 음성으로 주차별 통화 목업을 만들고 실제 파이프라인에 태운다"
    )
    parser.add_argument("--weeks", type=int, default=4, help="생성할 주 수 (최대 8)")
    parser.add_argument("--child-phone", default="01000000002")
    parser.add_argument("--parent-phone", default="01000000010")
    parser.add_argument("--parent-voice", help="부모 목소리 voice ID (기본: .env 값)")
    parser.add_argument("--child-voice", help="자녀 목소리 voice ID (기본: .env 값)")
    parser.add_argument("--hour", type=int, default=10, help="통화 시각 (KST, 기본 오전 10시)")
    parser.add_argument("--out-dir", default=".data/mock-audio")
    parser.add_argument("--force", action="store_true", help="이미 있는 음성도 다시 합성한다")
    parser.add_argument("--audio-only", action="store_true", help="합성만 하고 replay는 건너뛴다")
    args = parser.parse_args()
    try:
        raise SystemExit(asyncio.run(build(args)))
    except MockDataError as exc:
        print(f"실패: {exc}")
        raise SystemExit(2) from exc


if __name__ == "__main__":
    main()
