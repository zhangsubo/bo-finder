"""Exercise the actual JSON-lines worker with one-second WAVs and two input tracks.

Run with the meeting runtime's Python. --realtime paces input at normal speed.
Only the supplied fixture is read; no microphone, system audio, or network access.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import wave


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True)
    parser.add_argument("--models", required=True)
    parser.add_argument("--realtime", action="store_true")
    args = parser.parse_args()
    with wave.open(args.audio) as reader:
        assert (reader.getframerate(), reader.getnchannels(), reader.getsampwidth()) == (16000, 1, 2)
        audio = reader.readframes(reader.getnframes())
    worker = Path(__file__).with_name("meeting_worker.py")
    process = subprocess.Popen([sys.executable, "-u", str(worker), "--models", args.models], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    began = time.monotonic()
    try:
        assert json.loads(process.stdout.readline()).get("ready") is True
        load_seconds = time.monotonic() - began
        started = time.monotonic()
        timings = []
        first_text = {}
        first_text_wall = {}
        transcript = {"mic": {}, "system": {}}
        utterances = {"mic": set(), "system": set()}
        updates = 0
        with tempfile.TemporaryDirectory(prefix="meeting-stream-") as folder:
            for index, offset in enumerate(range(0, len(audio), 32000)):
                if args.realtime:
                    time.sleep(max(0, started + index + 1 - time.monotonic()))
                file = Path(folder) / "chunk.wav"
                with wave.open(str(file), "wb") as writer:
                    writer.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                    writer.writeframes(audio[offset:offset + 32000])
                submitted = time.monotonic()
                for source in ["mic", "system"]:
                    process.stdin.write(json.dumps(dict(id=f"{source}-{index}", file=str(file), source=source, start=index)) + "\n")
                process.stdin.flush()
                for source in ["mic", "system"]:
                    result = json.loads(process.stdout.readline())
                    assert "error" not in result, result
                    assert result["id"] == f"{source}-{index}"
                    timings.append(time.monotonic() - submitted)
                    if result["text"]:
                        first_text.setdefault(source, index + 1)
                        first_text_wall.setdefault(source, time.monotonic() - started)
                        transcript[source][result["utterance"]] = result["text"]
                        if result["utterance"] in utterances[source]:
                            updates += 1
                        utterances[source].add(result["utterance"])
        assert not utterances["mic"].intersection(utterances["system"])
        assert len(first_text) == 2 and updates > 0
        values = sorted(timings)
        report = dict(audio_seconds=len(audio) / 32000, tracks=2, realtime=args.realtime,
                      load_seconds=load_seconds, responses=len(timings),
                      chunk_to_worker_p95_seconds=values[min(len(values) - 1, int(len(values) * .95))],
                      chunk_to_worker_max_seconds=max(values), first_text_audio_seconds=first_text,
                      first_text_wall_seconds=first_text_wall,
                      transcript={k: list(v.values()) for k, v in transcript.items()},
                      in_place_sentence_updates=updates, utterances={k: len(v) for k, v in utterances.items()})
        print(json.dumps(report, ensure_ascii=False, indent=2))
    finally:
        process.terminate()
        process.wait(timeout=10)


if __name__ == "__main__":
    main()
