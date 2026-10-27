# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy>=1.26"]
# ///
"""Record a meeting (mic + system audio) and transcribe it live with the local Whisper server."""

from __future__ import annotations

import argparse
import collections
import contextlib
import datetime as dt
import json
import os
import queue
import re
import shutil
import signal
import sqlite3
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
CAPTURE_BIN = ROOT / "capture" / ".build" / "release" / "mel-capture"
RATE = 16_000
FRAME = 480  # 30 ms analysis frames
HEADER = struct.Struct("<BdI")  # source, pts seconds, frame count
TRACKS = {0: "mic", 1: "system"}
SPEAKERS = {"mic": "Me", "system": "Them"}
VOICE_MATCH = 0.75  # cosine similarity; the same voice scores ~0.9, different voices well below
# mel.db and Recordings/; ./mel sets MEL_DATA and creates the database (db/*.sql).
DATA = Path(os.environ.get("MEL_DATA", Path.home() / "Library" / "Application Support" / "Mel"))
RECORDINGS = DATA / "Recordings"


def ts(seconds: float) -> str:
    s = int(seconds)
    return f"{s // 3600:02d}:{s % 3600 // 60:02d}:{s % 60:02d}"


def read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as w:
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)


def open_wav(path: Path) -> wave.Wave_write:
    w = wave.open(str(path), "wb")
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(RATE)
    return w


def pack(voiceprint) -> bytes:
    """A voiceprint as stored in the database: unit-length float32."""
    v = np.asarray(voiceprint, dtype=np.float32)
    return (v / (np.linalg.norm(v) or 1.0)).astype("<f4").tobytes()


def unpack(blob: bytes) -> np.ndarray:
    return np.frombuffer(blob, dtype="<f4")


class Store:
    """mel.db. One connection shared by the recording threads, so every call takes the lock."""

    def __init__(self):
        if not (DATA / "mel.db").exists():
            sys.exit(f"no database in {DATA}: run ./mel init")
        self.db = sqlite3.connect(DATA / "mel.db", check_same_thread=False, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys = ON")
        self.db.execute("PRAGMA busy_timeout = 5000")
        self.lock = threading.RLock()

    def run(self, sql: str, *args) -> sqlite3.Cursor:
        with self.lock:
            return self.db.execute(sql, args)

    def one(self, sql: str, *args) -> sqlite3.Row | None:
        return self.run(sql, *args).fetchone()

    @contextlib.contextmanager
    def transaction(self):
        with self.lock:
            self.db.execute("BEGIN IMMEDIATE")
            try:
                yield
            except BaseException:
                self.db.execute("ROLLBACK")
                raise
            self.db.execute("COMMIT")

    def setting(self, key: str, default: str) -> str:
        row = self.one("SELECT value FROM settings WHERE key = ?", key)
        return row["value"] if row else default


def match_voices(store: Store, voiceprints: dict[str, list[float]]) -> dict[str, sqlite3.Row]:
    """Map diarization labels to people, best matches first, each person used once."""
    people = store.run("SELECT id, name, voiceprint FROM people").fetchall()
    pairs = sorted(
        ((float(unpack(pack(vec)) @ unpack(person["voiceprint"])), label, person) for label, vec in voiceprints.items() for person in people),
        key=lambda p: p[0],
        reverse=True,
    )
    matches: dict[str, sqlite3.Row] = {}
    for similarity, label, person in pairs:
        if similarity < VOICE_MATCH:
            break
        if label not in matches and person["id"] not in {p["id"] for p in matches.values()}:
            matches[label] = person
    return matches


class Segmenter:
    """Energy-based endpointing: cuts a stream into utterance-sized chunks at pauses."""

    def __init__(self, on_chunk, min_db=-50.0, margin_db=12.0):
        self.on_chunk = on_chunk
        self.min_db, self.margin_db = min_db, margin_db
        self.noise_db = -60.0
        self.pos = 0  # samples consumed
        self.pending = np.zeros(0, dtype=np.int16)
        self.preroll = collections.deque(maxlen=10)  # 300 ms kept before speech starts
        self.chunk: list[np.ndarray] | None = None
        self.chunk_start = 0
        self.speech = self.silence = 0  # frame counts

    def feed(self, samples: np.ndarray):
        data = np.concatenate([self.pending, samples])
        n = len(data) // FRAME * FRAME
        self.pending = data[n:]
        for frame in data[:n].reshape(-1, FRAME):
            self._frame(frame)
            self.pos += FRAME

    def _frame(self, frame: np.ndarray):
        rms = np.sqrt(np.mean(frame.astype(np.float32) ** 2))
        db = max(20 * np.log10(rms / 32768 + 1e-10), -100.0)
        voiced = db > max(self.min_db, self.noise_db + self.margin_db)
        # Track the noise floor: fast while quiet, slowly otherwise so a constant hum is eventually absorbed.
        self.noise_db += (0.001 if voiced else 0.05) * (db - self.noise_db)

        if self.chunk is None:
            if voiced:
                self.chunk = [*self.preroll, frame]
                self.chunk_start = self.pos - len(self.preroll) * FRAME
                self.preroll.clear()
                self.speech, self.silence = 1, 0
            else:
                self.preroll.append(frame)
            return

        self.chunk.append(frame)
        if voiced:
            self.speech, self.silence = self.speech + 1, 0
        else:
            self.silence += 1
        duration = len(self.chunk) * FRAME / RATE
        pause = self.silence * FRAME / RATE
        if pause >= 1.5 or (pause >= 0.6 and duration >= 6) or (not voiced and duration >= 20) or duration >= 30:
            self.flush()

    def flush(self):
        if self.chunk is not None and self.speech * FRAME >= 0.3 * RATE:
            self.on_chunk(self.chunk_start / RATE, np.concatenate(self.chunk))
        self.chunk = None
        self.speech = self.silence = 0


class Track:
    """One audio source: written to its own WAV and fed to a segmenter on a shared timeline."""

    def __init__(self, name: str, path: Path, on_chunk):
        self.wav = open_wav(path)
        self.written = 0
        self.segmenter = Segmenter(lambda start, pcm: on_chunk(name, start, pcm))

    def write(self, position: int, pcm: np.ndarray):
        gap = position - self.written
        if gap > RATE // 10:  # source was silent/paused; keep tracks aligned
            self._append(np.zeros(gap, dtype=np.int16))
        self._append(pcm)

    def _append(self, pcm: np.ndarray):
        self.wav.writeframes(pcm.tobytes())
        self.written += len(pcm)
        self.segmenter.feed(pcm)

    def close(self):
        self.segmenter.flush()
        self.wav.close()


class Server:
    def __init__(self, url: str):
        self.url = url.rstrip("/")

    def wait_ready(self, timeout: float) -> bool:
        deadline, unreachable_deadline = time.time() + timeout, time.time() + 30
        announced = False
        while time.time() < deadline:
            try:
                with urllib.request.urlopen(f"{self.url}/health", timeout=3) as r:
                    health = json.load(r)
                if health.get("error"):
                    print(f"! server failed to load model: {health['error']}")
                    return False
                if health.get("ready"):
                    return True
                if not announced:
                    print(f"… loading model {health.get('model')} (the first run downloads it)")
                    announced = True
            except (urllib.error.URLError, OSError):
                if time.time() > unreachable_deadline:
                    return False
            time.sleep(2)
        return False

    def transcribe(self, pcm: np.ndarray, language: str) -> dict:
        request = urllib.request.Request(
            f"{self.url}/transcribe?language={language}",
            data=pcm.tobytes(),
            headers={"Content-Type": "application/octet-stream"},
        )
        with urllib.request.urlopen(request, timeout=600) as r:
            return json.load(r)

    def title(self, transcript: str) -> str:
        request = urllib.request.Request(
            f"{self.url}/title", data=json.dumps({"transcript": transcript}).encode(), headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(request, timeout=600) as r:
            return json.load(r)["title"]

    def diarize(self, pcm: np.ndarray) -> dict:
        request = urllib.request.Request(
            f"{self.url}/diarize", data=pcm.tobytes(), headers={"Content-Type": "application/octet-stream"}
        )
        with urllib.request.urlopen(request, timeout=3600) as r:
            return json.load(r)


class Transcript:
    """A meeting's segments. Live recordings insert each one as it's transcribed, so the app shows them;
    save() then writes the final speakers and segments in one transaction."""

    def __init__(self, store: Store, meeting: int, live: bool):
        self.store, self.meeting, self.live = store, meeting, live
        self.entries: list[dict] = []
        self.people: dict[str, int] = {}  # speaker label -> person id, from voice recognition
        self.voiceprints: dict[str, list[float]] = {}
        self.lock = threading.Lock()
        if live:
            self.speaker_ids = {}
            for label in SPEAKERS.values():
                store.run("INSERT OR IGNORE INTO speakers (meeting_id, label) VALUES (?, ?)", meeting, label)
                self.speaker_ids[label] = store.one("SELECT id FROM speakers WHERE meeting_id = ? AND label = ?", meeting, label)["id"]

    def add(self, track: str, offset: float, result: dict):
        for seg in result["segments"]:
            text = seg["text"].strip()
            if not text:
                continue
            entry = {
                "start": round(offset + seg["start"], 2),
                "end": round(offset + seg["end"], 2),
                "speaker": SPEAKERS[track],
                "language": result["language"],
                "text": text,
            }
            with self.lock:
                self.entries.append(entry)
            if self.live:
                self.store.run(
                    "INSERT INTO segments (meeting_id, speaker_id, start, end, language, text) VALUES (?, ?, ?, ?, ?, ?)",
                    self.meeting, self.speaker_ids[entry["speaker"]], entry["start"], entry["end"], entry["language"], text,
                )
            print(f"[{ts(entry['start'])}] {entry['speaker']} ({entry['language']}): {text}", flush=True)

    def label_speakers(self, turns: list[dict], voiceprints: dict[str, list[float]]):
        """Rename "Them" entries after the diarization turn that overlaps each one most.

        Speakers whose voice matches a person keep their name as label; the rest become "Speaker N".
        """
        known = match_voices(self.store, voiceprints)
        names: dict[str, str] = {}
        for entry in sorted(self.entries, key=lambda e: e["start"]):
            if entry["speaker"] != SPEAKERS["system"]:
                continue
            overlap = collections.Counter()
            for t in turns:
                overlap[t["speaker"]] += max(0.0, min(entry["end"], t["end"]) - max(entry["start"], t["start"]))
            if overlap and (best := overlap.most_common(1)[0])[1] > 0:
                label = best[0]
                if label not in names:
                    unknown = sum(1 for n in names.values() if n.startswith("Speaker "))
                    names[label] = known[label]["name"] if label in known else f"Speaker {unknown + 1}"
                    if label in known:
                        self.people[names[label]] = known[label]["id"]
                entry["speaker"] = names[label]
        # Kept with each speaker so the app can learn a voice when you name them.
        self.voiceprints = {name: voiceprints[label] for label, name in names.items() if label in voiceprints}

    def save(self):
        """Replace the meeting's speakers and segments with the final ones."""
        entries = sorted(self.entries, key=lambda e: e["start"])
        with self.store.transaction():
            self.store.run("DELETE FROM speakers WHERE meeting_id = ?", self.meeting)  # cascades to segments
            ids = {}
            for label in dict.fromkeys(e["speaker"] for e in entries):
                voiceprint = self.voiceprints.get(label)
                ids[label] = self.store.run(
                    "INSERT INTO speakers (meeting_id, label, person_id, voiceprint) VALUES (?, ?, ?, ?)",
                    self.meeting, label, self.people.get(label), pack(voiceprint) if voiceprint else None,
                ).lastrowid
            for e in entries:
                self.store.run(
                    "INSERT INTO segments (meeting_id, speaker_id, start, end, language, text) VALUES (?, ?, ?, ?, ?, ?)",
                    self.meeting, ids[e["speaker"]], e["start"], e["end"], e["language"], e["text"],
                )


class Pipeline:
    """Transcribes chunks on a background thread so capture and saving never block."""

    def __init__(self, server: Server, transcript: Transcript, language: str):
        self.server, self.transcript, self.language = server, transcript, language
        self.queue: queue.Queue = queue.Queue()
        self.available = True
        self.warned = False

    def start(self, wait: float):
        threading.Thread(target=self._run, args=(wait,), daemon=True).start()

    def submit(self, track: str, offset: float, pcm: np.ndarray):
        self.queue.put((track, offset, pcm))
        if self.queue.qsize() > 6 and not self.warned:
            print("! transcription is falling behind (audio is safe). Consider a smaller MODEL, e.g. MODEL=small.")
            self.warned = True

    def _run(self, wait: float):
        self.available = self.server.wait_ready(wait)
        if not self.available:
            print("! transcription server unavailable: recording audio only. Run `./mel transcribe <meeting>` later.")
        while True:
            track, offset, pcm = self.queue.get()
            try:
                if self.available:
                    self.transcript.add(track, offset, self.server.transcribe(pcm, self.language))
            except Exception as e:
                print(f"! chunk at {ts(offset)} ({track}) failed: {e}")
            finally:
                self.queue.task_done()

    def finish(self):
        if pending := self.queue.unfinished_tasks:
            print(f"Finishing {pending} pending chunk(s)… (Ctrl+C to skip)")
        try:
            self.queue.join()
        except KeyboardInterrupt:
            print("Skipped remaining transcription; audio is saved.")


def diarize(server: Server, folder: Path, transcript: Transcript):
    """Tell the other participants apart. Optional: on failure the transcript keeps "Them"."""
    path = folder / "system.wav"
    if not path.exists() or not any(e["speaker"] == SPEAKERS["system"] for e in transcript.entries):
        return
    print("Detecting speakers… (Ctrl+C to skip)", flush=True)
    try:
        result = server.diarize(read_wav(path))
        transcript.label_speakers(result["turns"], result.get("voiceprints", {}))
    except KeyboardInterrupt:
        print("Skipped speaker detection.")
    except Exception as e:
        detail = e.read().decode(errors="replace") if isinstance(e, urllib.error.HTTPError) else e
        print(f"! speaker detection skipped: {detail}")


def name_meeting(server: Server, transcript: Transcript):
    """Give an untitled meeting a title from its transcript."""
    row = transcript.store.one("SELECT title FROM meetings WHERE id = ?", transcript.meeting)
    if row["title"] or not transcript.entries:  # titled by you, or nothing was said
        return
    print("Naming meeting…", flush=True)
    text = "\n".join(f"{e['speaker']}: {e['text']}" for e in sorted(transcript.entries, key=lambda e: e["start"]))
    try:
        title = server.title(text)
    except KeyboardInterrupt:
        print("Skipped naming.")
        return
    except Exception as e:
        print(f"! naming skipped: {e}")
        return
    if title:
        transcript.store.run("UPDATE meetings SET title = ? WHERE id = ?", title, transcript.meeting)
        print(f"Titled “{title}”", flush=True)


def finish_meeting(server: Server, folder: Path, transcript: Transcript):
    """Detect speakers and name the meeting at the same time; each can be skipped."""
    namer = threading.Thread(target=name_meeting, args=(server, transcript), daemon=True)
    namer.start()  # the title only needs the text
    with skippable():
        diarize(server, folder, transcript)
    with skippable():
        namer.join()


def ignore_stops():
    """After stopping, further Ctrl+C (or the app's Stop) must not cut saving short."""
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)


@contextlib.contextmanager
def skippable():
    """Ctrl+C (or the app's Skip) skips only the step inside this block; the meeting is saved either way."""
    signal.signal(signal.SIGINT, signal.default_int_handler)
    signal.signal(signal.SIGTERM, signal.default_int_handler)
    try:
        yield
    except KeyboardInterrupt:
        pass  # arrived just outside the step's own handler
    finally:
        ignore_stops()


def watch_commands(pipeline: Pipeline):
    """Change the language mid-meeting: the app (or you, in the terminal) writes `language <code>` or `language auto`."""
    for line in sys.stdin:
        command, _, value = line.strip().partition(" ")
        if command == "language" and re.fullmatch(r"auto|[a-z]{2,3}", value):
            pipeline.language = value
            print(f"Language: {value}", flush=True)


def read_exact(stream, n: int) -> bytes | None:
    data = stream.read(n)
    return data if len(data) == n else None


def mix(folder: Path):
    tracks = [read_wav(p) for p in (folder / f"{n}.wav" for n in TRACKS.values()) if p.exists()]
    if not tracks:
        return
    out = np.zeros(max(map(len, tracks)), dtype=np.int32)
    for t in tracks:
        out[: len(t)] += t
    with open_wav(folder / "meeting.wav") as w:
        w.writeframes(np.clip(out, -32768, 32767).astype(np.int16).tobytes())


def wav_seconds(folder: Path) -> float:
    lengths = [wave.open(str(p)).getnframes() for p in (folder / f"{n}.wav" for n in TRACKS.values()) if p.exists()]
    return max(lengths, default=0) / RATE


def record(args):
    if not CAPTURE_BIN.exists():
        sys.exit(f"capture tool not built: run `./mel setup` ({CAPTURE_BIN})")
    store = Store()
    started = dt.datetime.now()
    folder = RECORDINGS / started.strftime("%Y-%m-%d_%H-%M-%S")
    folder.mkdir(parents=True, exist_ok=True)
    meeting = store.run(
        "INSERT INTO meetings (title, started_at, folder, language) VALUES (?, ?, ?, ?)",
        args.title, started.isoformat(timespec="seconds"), folder.name, args.language,
    ).lastrowid

    transcript = Transcript(store, meeting, live=True)
    pipeline = Pipeline(Server(args.server), transcript, args.language)
    pipeline.start(wait=600)
    threading.Thread(target=watch_commands, args=(pipeline,), daemon=True).start()
    tracks = {i: Track(n, folder / f"{n}.wav", pipeline.submit) for i, n in TRACKS.items()}

    proc = subprocess.Popen([str(CAPTURE_BIN)] + (["--no-mic"] if args.no_mic else []), stdout=subprocess.PIPE)
    print(f"● Recording → meeting {meeting} ({folder})\n  Press Ctrl+C to stop.\n", flush=True)
    t0 = None
    try:
        while header := read_exact(proc.stdout, HEADER.size):
            source, pts, frames = HEADER.unpack(header)
            data = read_exact(proc.stdout, frames * 2)
            if data is None:
                break
            t0 = pts if t0 is None else t0
            tracks[source].write(round((pts - t0) * RATE), np.frombuffer(data, dtype=np.int16))
    except KeyboardInterrupt:
        pass
    finally:
        ignore_stops()
        if proc.poll() is None:
            proc.terminate()
        proc.wait()

    print("\n■ Stopped.")
    for track in tracks.values():
        track.close()
    if t0 is None:  # the folder holds only empty WAV headers
        store.run("DELETE FROM meetings WHERE id = ?", meeting)
        shutil.rmtree(folder)
        sys.exit("! no audio was captured: allow Screen & System Audio Recording and Microphone for the app running mel "
                 "(your terminal or Mel) in System Settings › Privacy & Security, then restart that app")
    store.run("UPDATE meetings SET status = 'processing', duration = ? WHERE id = ?", wav_seconds(folder), meeting)
    with skippable():
        pipeline.finish()
    mix(folder)
    if pipeline.available:
        finish_meeting(pipeline.server, folder, transcript)
    transcript.save()
    store.run("UPDATE meetings SET status = 'done' WHERE id = ?", meeting)
    print(f"✓ Saved meeting {meeting}", flush=True)


def transcribe(args):
    """Transcribe a meeting again from its audio, e.g. with another model or language."""
    store = Store()
    row = store.one("SELECT folder FROM meetings WHERE id = ?", args.meeting)
    if row is None:
        sys.exit(f"no meeting {args.meeting} (list them with ./mel sql \"SELECT id, title FROM meetings\")")
    folder = RECORDINGS / row["folder"]
    if not (folder / "meeting.wav").exists():  # the recording was cut off before mixing
        mix(folder)
    server = Server(args.server)
    if not server.wait_ready(600):
        sys.exit("transcription server unavailable (try `./mel logs`)")
    store.run("UPDATE meetings SET status = 'processing', duration = ? WHERE id = ?", wav_seconds(folder), args.meeting)
    chunks = []
    for name in TRACKS.values():
        if (path := folder / f"{name}.wav").exists():
            # One chunk per utterance so each gets its own language, like live transcription.
            segmenter = Segmenter(lambda start, pcm, name=name: chunks.append((name, start, pcm)))
            segmenter.feed(read_wav(path))
            segmenter.flush()
    transcript = Transcript(store, args.meeting, live=False)
    try:
        for i, (name, start, pcm) in enumerate(sorted(chunks, key=lambda c: c[1]), 1):
            print(f"({i}/{len(chunks)})", end=" ", flush=True)
            transcript.add(name, start, server.transcribe(pcm, args.language))
        finish_meeting(server, folder, transcript)
        transcript.save()  # the previous transcript stays until here
    finally:
        store.run("UPDATE meetings SET status = 'done' WHERE id = ?", args.meeting)
    print(f"✓ Transcribed meeting {args.meeting}")


def export(args):
    """Print a meeting as Markdown."""
    store = Store()
    meeting = store.one("SELECT title, started_at FROM meetings WHERE id = ?", args.meeting)
    if meeting is None:
        sys.exit(f"no meeting {args.meeting}")
    rows = store.run(
        """SELECT s.start, COALESCE(p.name, sp.label) AS speaker, s.text FROM segments s
           JOIN speakers sp ON sp.id = s.speaker_id LEFT JOIN people p ON p.id = sp.person_id
           WHERE s.meeting_id = ? ORDER BY s.start""",
        args.meeting,
    ).fetchall()
    print(f"# {meeting['title'] or 'Untitled meeting'}\n\n{meeting['started_at'].replace('T', ' ')}\n")
    print("\n\n".join(f"[{ts(r['start'])}] **{r['speaker']}**: {r['text']}" for r in rows))


def main():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--server", default="http://127.0.0.1:8765")
    common.add_argument("--language", help="auto (detected per utterance among LANGUAGES) or a language code such as en; default: the app's setting")
    parser = argparse.ArgumentParser(prog="mel", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    rec = sub.add_parser("record", parents=[common], help="record and transcribe live")
    rec.add_argument("title", nargs="?", help="title for the meeting (otherwise one is written from the transcript)")
    rec.add_argument("--no-mic", action="store_true", help="only capture system audio")
    tr = sub.add_parser("transcribe", parents=[common], help="transcribe a meeting again")
    tr.add_argument("meeting", type=int)
    ex = sub.add_parser("export", help="print a meeting as Markdown")
    ex.add_argument("meeting", type=int)
    args = parser.parse_args()
    if hasattr(args, "language") and args.language is None:
        args.language = Store().setting("language", "auto")
    signal.signal(signal.SIGTERM, signal.default_int_handler)  # the app stops recordings with SIGTERM
    {"record": record, "transcribe": transcribe, "export": export}[args.command](args)


if __name__ == "__main__":
    main()
