"""Local-only JSON-lines ASR worker. No network requests or microphone access."""
import argparse
import json
import sys
import time
import wave
import uuid
from pathlib import Path


def read_audio(path):
    import numpy as np
    with wave.open(str(path), "rb") as f:
        if f.getframerate() != 16000 or f.getnchannels() != 1 or f.getsampwidth() != 2:
            raise ValueError("Expected 16kHz mono PCM16 WAV")
        return np.frombuffer(f.readframes(f.getnframes()), dtype="<i2").astype(np.float32) / 32768


class Engine:
    def __init__(self, models):
        import sherpa_onnx
        self.models = Path(models)
        self.asr = sherpa_onnx.OnlineRecognizer.from_transducer(
            tokens=str(self.models / "tokens.txt"),
            encoder=str(self.models / "encoder-960ms.onnx"),
            decoder=str(self.models / "decoder-960ms.onnx"),
            joiner=str(self.models / "joiner-960ms.onnx"),
            num_threads=4, sample_rate=16000, feature_dim=80,
            decoding_method="greedy_search", provider="cpu", model_type="zipformer2",
            enable_endpoint_detection=True,
            rule1_min_trailing_silence=2.4, rule2_min_trailing_silence=1.2,
            rule3_min_utterance_length=20,
        )
        self.live_streams = {}

    def preview(self, job):
        source = job["source"]
        samples = read_audio(job["file"])
        start = float(job["start"])
        state = self.live_streams.get(source)
        # A pause or skipped backlog must not splice unrelated audio together.
        if state is None or abs(start - state["end"]) > 0.5:
            state = dict(stream=self.asr.create_stream(), utterance=str(uuid.uuid4()), start=start, end=start)
            self.live_streams[source] = state
        stream = state["stream"]
        stream.accept_waveform(16000, samples)
        while self.asr.is_ready(stream):
            self.asr.decode_stream(stream)
        state["end"] = start + len(samples) / 16000
        result = dict(text=self.asr.get_result(stream).strip(), utterance=state["utterance"], start=state["start"], end=state["end"])
        if self.asr.is_endpoint(stream):
            self.live_streams.pop(source, None)
        return result

    def recognize(self, samples):
        import numpy as np
        if not len(samples) or float(np.max(np.abs(samples))) < 0.002:
            return ""
        stream = self.asr.create_stream()
        stream.accept_waveform(16000, samples)
        stream.accept_waveform(16000, np.zeros(32000, dtype=np.float32))
        stream.input_finished()
        while self.asr.is_ready(stream):
            self.asr.decode_stream(stream)
        return self.asr.get_result(stream).strip()

    def final(self, manifest, directory, speaker_count=0):
        import numpy as np
        import sherpa_onnx
        chunks = manifest["chunks"]
        duration = max((c["start"] + c["duration"] for c in chunks), default=0)
        # Allow the final capture buffer and timer interval at the four-hour limit.
        if not 0 < duration <= 4 * 3600 + 60:
            raise ValueError("Recording must be between 0 and 4 hours")
        # Mix preserved tracks on their original wall-clock timeline, including pauses.
        audio = np.zeros(int(duration * 16000) + 16000, dtype=np.float32)
        for chunk in chunks:
            path = (directory / chunk["file"]).resolve()
            if path.parent != directory.resolve():
                raise ValueError("Invalid audio path")
            samples = read_audio(path)
            start = max(0, round(chunk["start"] * 16000))
            length = min(len(samples), len(audio) - start)
            audio[start:start + length] += samples[:length]
        audio = np.clip(audio, -1, 1)
        config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
            segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
                pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(
                    model=str(self.models / "segmentation.onnx")
                ), num_threads=4, provider="cpu"
            ),
            embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(
                model=str(self.models / "embedding.onnx"), num_threads=4, provider="cpu"
            ),
            clustering=sherpa_onnx.FastClusteringConfig(num_clusters=speaker_count if speaker_count > 0 else -1, threshold=0.75),
            min_duration_on=0.3, min_duration_off=0.5,
        )
        if not config.validate():
            raise ValueError("Speaker models are missing or invalid")
        diarizer = sherpa_onnx.OfflineSpeakerDiarization(config)
        turns = diarizer.process(audio).sort_by_start_time()
        speakers = {}
        result = []
        for turn_index, turn in enumerate(turns):
            if turn.speaker not in speakers:
                index = len(speakers)
                speakers[turn.speaker] = chr(65 + index) if index < 26 else f"{index + 1}"
            # Segmentation boundaries can clip initial/final syllables. Include nearby
            # silence, bounded by adjacent turns so another speaker is not added.
            previous_end = turns[turn_index - 1].end if turn_index else 0
            next_start = turns[turn_index + 1].start if turn_index + 1 < len(turns) else len(audio) / 16000
            start = max(0, min(turn.start, max(previous_end, turn.start - 0.25)))
            turn_end = min(len(audio) / 16000, max(turn.end, min(next_start, turn.end + 0.35)))
            while start < turn_end:
                end = min(start + 20, turn_end)
                text = self.recognize(audio[round(start * 16000):round(end * 16000)])
                if text:
                    result.append(dict(start=start, end=end, speaker=speakers[turn.speaker], text=text))
                start = end
        return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--models", required=True)
    parser.add_argument("--final")
    parser.add_argument("--speakers", type=int, default=0)
    args = parser.parse_args()
    engine = Engine(args.models)
    if args.final:
        path = Path(args.final)
        with path.open() as f:
            manifest = json.load(f)
        print(json.dumps({"segments": engine.final(manifest, path.parent, args.speakers)}, ensure_ascii=False), flush=True)
        return
    print(json.dumps({"ready": True}), flush=True)
    for line in sys.stdin:
        job = json.loads(line)
        begin = time.monotonic()
        try:
            result = engine.preview(job)
            response = {"id": job["id"], **result, "seconds": time.monotonic() - begin}
        except Exception:
            response = {"id": job["id"], "error": "本地识别失败，请检查音频及模型配置。"}
        print(json.dumps(response, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
