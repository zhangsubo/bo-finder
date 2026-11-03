"""Prepare an isolated build-local runtime and verified X-ASR weights; no user settings touched."""
import hashlib
from pathlib import Path
import subprocess
import sys
import tarfile
import venv

ROOT = Path(__file__).resolve().parent.parent
MODELS = ROOT / "build/meeting-models"
RUNTIME = ROOT / "build/meeting-runtime"
REVISION = "689ff18c584d29910da37b6fe904db0c1489c9d1"
WEIGHTS = {
    "encoder-960ms.onnx": "dd9484b7c34c951495f3420f26f9f2ab706e748bc087cd14dfe0b90d3156264f",
    "decoder-960ms.onnx": "3658368d274a5d5fd39a7ac20c46bed0ad9cfea1f0feddef30d5d89797c1f499",
    "joiner-960ms.onnx": "03781c98165a2385024c9cecdd2b6b13310d81db23a62c7da420782c2915cf81",
}


def digest(path):
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def download(url, name, expected=None):
    target = MODELS / name
    if target.exists() and (expected is None or digest(target) == expected):
        return target
    partial = target.with_suffix(target.suffix + ".partial")
    subprocess.run(["curl", "--http1.1", "--fail", "--location", "--retry", "4", "--retry-all-errors", "--continue-at", "-", "--output", str(partial), url], check=True)
    if expected and digest(partial) != expected:
        raise RuntimeError(f"SHA256 mismatch: {name}; download retained for diagnosis")
    partial.replace(target)
    return target


def main():
    MODELS.mkdir(parents=True, exist_ok=True)
    if not (RUNTIME / "bin/python").exists():
        venv.create(RUNTIME, with_pip=True)
    subprocess.run([str(RUNTIME / "bin/python"), "-m", "pip", "install", "sherpa-onnx==2.0.0", "numpy>=1.26,<3"], check=True)
    base = f"https://huggingface.co/GilgameshWind/X-ASR-zh-en/resolve/{REVISION}/deployment/models/chunk-960ms-model"
    for name, expected in WEIGHTS.items():
        download(base + "/" + name, name, expected)
    download(base + "/tokens.txt", "tokens.txt")
    archive = download("https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2", "speakers.tar.bz2")
    with tarfile.open(archive) as bundle:
        for source, destination in [("model.onnx", "segmentation.onnx"), ("LICENSE", "segmentation-LICENSE")]:
            data = bundle.extractfile("sherpa-onnx-pyannote-segmentation-3-0/" + source).read()
            (MODELS / destination).write_bytes(data)
    download("https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx", "embedding.onnx")
    print("Python:", RUNTIME / "bin/python")
    print("Models:", MODELS)
    print("Model sources: X-ASR (Apache-2.0), pyannote segmentation (bundled MIT notice), 3D-Speaker (Apache-2.0).")


if __name__ == "__main__":
    main()
