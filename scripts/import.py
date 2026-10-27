# /// script
# requires-python = ">=3.10"
# ///
"""Move meetings recorded before the database (recordings/, voices.json, server/config.env and the app's
preferences) into mel.db. Run by `./mel import`; safe to run again, since imported folders are moved away."""

import array
import datetime as dt
import json
import math
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import wave
from pathlib import Path

# Import from this checkout, or from another folder laid out like it (`./mel import <folder>`).
ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
DATA = Path(os.environ.get("MEL_DATA", Path.home() / "Library" / "Application Support" / "Mel"))
OLD = ROOT / "recordings"
VOICES = ROOT / "voices.json"
CONFIG = ROOT / "server" / "config.env"
SETTINGS = {  # config.env key or app preference -> settings key
    "LANGUAGES": "languages", "MODEL": "model", "LLM": "llm",
    "language": "language", "mic": "mic", "floatingTranscript": "floating_transcript",
    "transcriptionModel": "model", "titleModel": "llm",
}


def pack(vector) -> bytes:
    norm = math.sqrt(sum(x * x for x in vector)) or 1.0
    return array.array("f", (x / norm for x in vector)).tobytes()  # float32, little endian on Apple Silicon


def seconds(folder: Path) -> float | None:
    for name in ("meeting.wav", "mic.wav", "system.wav"):
        if (path := folder / name).exists():
            with wave.open(str(path)) as w:
                return w.getnframes() / w.getframerate()
    return None


def backup():
    """The text files only: audio is moved, never changed."""
    target = DATA / f"backup-{dt.datetime.now():%Y-%m-%d_%H-%M-%S}.tar.gz"
    with tarfile.open(target, "w:gz") as tar:
        for path in [VOICES, CONFIG, *OLD.glob("*/*.json"), *OLD.glob("*/*.md")]:
            if path.exists():
                tar.add(path, arcname=path.relative_to(ROOT))
    print(f"Backed up transcripts, voices and settings to {target}")


def import_settings(db: sqlite3.Connection):
    values = {}
    if CONFIG.exists():
        for line in CONFIG.read_text().splitlines():
            key, _, value = line.partition("=")
            if key in SETTINGS and value:
                values[SETTINGS[key]] = value
    for key in ("language", "mic", "floatingTranscript", "transcriptionModel", "titleModel"):  # the app's UserDefaults
        result = subprocess.run(["defaults", "read", "local.mel", key], capture_output=True, text=True)
        if result.returncode == 0:
            values[SETTINGS[key]] = result.stdout.strip()
    for key, value in values.items():
        db.execute("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value", (key, value))
    if CONFIG.exists():
        CONFIG.rename(CONFIG.with_name("config.env.imported"))
    print(f"Imported {len(values)} settings")


def import_people(db: sqlite3.Connection):
    if not VOICES.exists():
        return
    voices = json.loads(VOICES.read_text())
    for name, voice in voices.items():
        db.execute(
            "INSERT OR IGNORE INTO people (name, voiceprint, meetings) VALUES (?, ?, ?)",
            (name, pack(voice["embedding"]), voice.get("meetings", 1)),
        )
    VOICES.rename(VOICES.with_name("voices.json.imported"))
    print(f"Imported {len(voices)} people")


def import_meeting(db: sqlite3.Connection, folder: Path):
    match = re.fullmatch(r"(\d{4}-\d{2}-\d{2}_\d{2}-\d{2})(?:_(.+))?", folder.name)
    if not match:
        print(f"  skipped {folder.name}: not a recording folder")
        return
    started = dt.datetime.strptime(match[1], "%Y-%m-%d_%H-%M")
    title = match[2].replace("-", " ") if match[2] else None
    while (DATA / "Recordings" / f"{started:%Y-%m-%d_%H-%M-%S}").exists():  # two meetings in the same minute
        started += dt.timedelta(seconds=1)
    target = DATA / "Recordings" / f"{started:%Y-%m-%d_%H-%M-%S}"

    entries = json.loads((folder / "transcript.json").read_text()) if (folder / "transcript.json").exists() else []
    voiceprints = json.loads((folder / "speakers.json").read_text()) if (folder / "speakers.json").exists() else {}
    people = {row[1].lower(): row[0] for row in db.execute("SELECT id, name FROM people")}

    target.mkdir(parents=True)
    for wav in folder.glob("*.wav"):
        wav.rename(target / wav.name)
    try:
        with db:
            meeting = db.execute(
                "INSERT INTO meetings (title, started_at, duration, folder, status) VALUES (?, ?, ?, ?, 'done')",
                (title, started.isoformat(timespec="seconds"), seconds(target), target.name),
            ).lastrowid
            speakers = {}
            for label in dict.fromkeys(e["speaker"] for e in entries):
                person = None if label in ("Me", "Them") or label.startswith("Speaker ") else people.get(label.lower())
                speakers[label] = db.execute(
                    "INSERT INTO speakers (meeting_id, label, person_id, voiceprint) VALUES (?, ?, ?, ?)",
                    (meeting, label, person, pack(voiceprints[label]) if label in voiceprints else None),
                ).lastrowid
            db.executemany(
                "INSERT INTO segments (meeting_id, speaker_id, start, end, language, text) VALUES (?, ?, ?, ?, ?, ?)",
                [(meeting, speakers[e["speaker"]], e["start"], e["end"], e.get("language"), e["text"]) for e in sorted(entries, key=lambda e: e["start"])],
            )
    except Exception:
        for wav in target.glob("*.wav"):  # put the audio back so nothing is half imported
            wav.rename(folder / wav.name)
        target.rmdir()
        raise
    print(f"  {folder.name}: {len(entries)} segments, {len(speakers)} speakers")


def main():
    if not (DATA / "mel.db").exists():
        sys.exit(f"no database in {DATA}: run ./mel init")
    if not OLD.is_dir() and not VOICES.exists() and not CONFIG.exists():
        print("Nothing to import.")
        return
    backup()
    db = sqlite3.connect(DATA / "mel.db")
    db.execute("PRAGMA foreign_keys = ON")
    with db:
        import_settings(db)
        import_people(db)
    if OLD.is_dir():
        folders = sorted(p for p in OLD.iterdir() if p.is_dir() and any(p.glob("*.wav")))
        print(f"Importing {len(folders)} meetings")
        for folder in folders:
            import_meeting(db, folder)
        OLD.rename(OLD.with_name("recordings.imported"))  # what's left: the old transcript files
    print(f"Done. Your meetings are in {DATA}")


if __name__ == "__main__":
    main()
