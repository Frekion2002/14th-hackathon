"""HeAR health acoustic event detector를 받아 ONNX로 변환한다.

모델 가중치는 Health AI Developer Foundations 약관 대상이라 이 저장소에 커밋하지 않는다.
각자 https://huggingface.co/google/hear 에서 약관에 동의하고 `HF_TOKEN`으로 이 스크립트를
한 번 실행한다. 결과물은 `.gitignore`된 `backend/models/`에 떨어진다.

변환에는 TensorFlow와 tf2onnx가 필요하지만 런타임은 onnxruntime만 쓴다. 그래서 두 패키지를
프로젝트 의존성에 넣지 않고 실행할 때만 붙인다.

    HF_TOKEN=hf_... uv run --with tensorflow --with tf2onnx python scripts/fetch_cough_model.py

산출물:
    models/hear-event-detector-small.onnx        약 5 MB
    models/hear-event-detector-small.json        provenance (HF revision, sha256, 도구 버전)
    models/NOTICE                                HAI-DEF 고지와 변경 사실
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# google/hear는 gated repo이며 revision은 content-addressed다. 이 값이 실제 provenance pin이다.
HF_REPO = "google/hear"
HF_REVISION = "9b2eb2853c426676255cc6ac5804b7f1fe8e563f"
VARIANT = "event_detector_small"
ONNX_OPSET = 17

# 변환 후 정상 동작을 확인할 최소 조건. 무음 2초에서는 어떤 class도 확신하지 않아야 한다.
LABELS = [
    "Cough",
    "Snore",
    "Baby Cough",
    "Breathe",
    "Sneeze",
    "Throat Clear",
    "Laugh",
    "Speech",
]

NOTICE = """HeAR health acoustic event detector

이 디렉터리의 모델 파일은 Google의 Health AI Developer Foundations(HAI-DEF)에서
배포하는 `google/hear` 저장소의 `{variant}`에서 파생되었다.

HAI-DEF is provided under and subject to the Health AI Developer Foundations
Terms of Use: https://developers.google.com/health-ai-developer-foundations/terms

변경 사실: 원본은 TensorFlow SavedModel이며, 이 파일은 tf2onnx로 ONNX opset {opset}로
변환한 것이다. 가중치와 연산 그래프의 의미는 변경하지 않았다.

원본 revision: {repo}@{revision}

사용 제한은 위 약관 3.2절을 따른다. 특히 Health Regulatory Authority가 Google을 의료기기
제조사로 간주할 수 있는 용도로 사용하지 않는다. 콜록은 이 모델의 출력을 진단, 위험군 라벨,
응급도 판정에 사용하지 않으며 개인 기준선 대비 변화 관찰에만 쓴다.
"""


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def convert(saved_model: Path, destination: Path) -> None:
    subprocess.run(
        [
            sys.executable,
            "-m",
            "tf2onnx.convert",
            "--saved-model",
            str(saved_model),
            "--output",
            str(destination),
            "--opset",
            str(ONNX_OPSET),
        ],
        check=True,
    )


def verify(model_path: Path) -> None:
    """변환본이 실제로 실행되고 기대한 출력 모양을 내는지 확인한다."""
    import numpy as np
    import onnxruntime as ort

    session = ort.InferenceSession(str(model_path), providers=["CPUExecutionProvider"])
    name = session.get_inputs()[0].name
    scores = session.run(None, {name: np.zeros((1, 32_000), dtype=np.float32)})[0]
    if scores.shape != (1, len(LABELS)):
        raise SystemExit(f"예상 출력 모양 (1, {len(LABELS)}), 실제 {scores.shape}")
    loudest = float(np.max(scores))
    if loudest > 0.5:
        raise SystemExit(f"무음 입력에서 {LABELS[int(np.argmax(scores))]}={loudest:.3f}로 반응한다")
    print(f"검증 통과: 무음 2초에서 최고 확률 {loudest:.4f}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "models",
        help="산출물 디렉터리 (기본: backend/models)",
    )
    args = parser.parse_args()

    from huggingface_hub import snapshot_download

    print(f"{HF_REPO}@{HF_REVISION[:12]} 에서 {VARIANT} 내려받는 중")
    snapshot = Path(
        snapshot_download(
            HF_REPO,
            revision=HF_REVISION,
            allow_patterns=[f"event_detector/{VARIANT}/*"],
        )
    )
    saved_model = snapshot / "event_detector" / VARIANT

    args.output_dir.mkdir(parents=True, exist_ok=True)
    model_path = args.output_dir / f"hear-event-detector-{VARIANT.split('_')[-1]}.onnx"

    with tempfile.TemporaryDirectory() as work:
        staged = Path(work) / model_path.name
        convert(saved_model, staged)
        verify(staged)
        shutil.move(str(staged), model_path)

    import onnxruntime as ort

    digest = sha256_of(model_path)
    (args.output_dir / f"{model_path.stem}.json").write_text(
        json.dumps(
            {
                "source": {"repo": HF_REPO, "revision": HF_REVISION, "variant": VARIANT},
                "labels": LABELS,
                "sha256": digest,
                "opset": ONNX_OPSET,
                "onnxruntime": ort.__version__,
                "sizeBytes": model_path.stat().st_size,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    (args.output_dir / "NOTICE").write_text(
        NOTICE.format(variant=VARIANT, opset=ONNX_OPSET, repo=HF_REPO, revision=HF_REVISION),
        encoding="utf-8",
    )

    print(f"\n{model_path}  ({model_path.stat().st_size / 1e6:.2f} MB)")
    print(f"sha256 {digest}")
    print("\nSettings.cough_model_sha256에 위 값을 넣으면 로딩 시 검증한다.")


if __name__ == "__main__":
    main()
