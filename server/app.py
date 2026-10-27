# /// script
# requires-python = ">=3.10"
# dependencies = ["mlx-whisper==0.4.3", "fastapi==0.115.6", "uvicorn==0.34.0", "pyannote.audio==4.0.7", "mlx-lm==0.32.2"]
# ///
"""Local meeting server: Whisper transcription and title generation (MLX, Apple GPU), speaker diarization (pyannote)."""

import asyncio
import logging
import os
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# Keep downloaded models in the repo; the Hugging Face token stays in its default place (`hf auth login`).
os.environ.setdefault("HF_HUB_CACHE", str(ROOT / "models" / "hub"))

import mlx.core as mx  # noqa: E402
import numpy as np  # noqa: E402
import uvicorn  # noqa: E402
from fastapi import FastAPI, HTTPException, Request  # noqa: E402
from mlx_whisper import transcribe as whisper_transcribe  # noqa: E402
from mlx_whisper.audio import N_FRAMES, N_SAMPLES, log_mel_spectrogram, pad_or_trim  # noqa: E402
from mlx_whisper.decoding import DecodingOptions, decode  # noqa: E402
from mlx_whisper.tokenizer import get_tokenizer  # noqa: E402
from mlx_whisper.transcribe import ModelHolder  # noqa: E402

MODEL = os.getenv("MODEL", "large-v3-turbo")
REPO = MODEL if "/" in MODEL else f"mlx-community/whisper-{MODEL}"
LANGUAGES = [lang.strip() for lang in os.getenv("LANGUAGES", "en,es").split(",") if lang.strip()]
PORT = int(os.getenv("PORT", "8765"))
LLM = os.getenv("LLM", "mlx-community/Qwen3-4B-Instruct-2507-4bit")
DIARIZATION_MODEL = os.getenv("DIARIZATION_MODEL", "pyannote/speaker-diarization-community-1")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("mel")
logging.getLogger("httpx").setLevel(logging.WARNING)  # quiet Hugging Face download requests

app = FastAPI()
state = {"model": None, "error": None, "diarizer": None, "llm": None}
# MLX binds GPU streams to the thread that created them, so all model work runs on this one thread.
mlx_thread = ThreadPoolExecutor(max_workers=1)
diarizer_lock = threading.Lock()


def load_model():
    log.info("loading %s; first run downloads it", REPO)
    try:
        state["model"] = ModelHolder.get_model(REPO, mx.float16)
        log.info("model ready")
    except Exception as e:  # surfaced through /health
        log.exception("failed to load model")
        state["error"] = str(e)


def segments(tokens: list[int], language: str, duration: float) -> list[dict]:
    """Split decoded tokens into segments at Whisper's timestamp tokens (20 ms steps)."""
    model = state["model"]
    tokenizer = get_tokenizer(model.is_multilingual, num_languages=model.num_languages, language=language, task="transcribe")
    out, start, text = [], 0.0, []
    for token in tokens + [tokenizer.timestamp_begin + round(duration / 0.02)]:
        if token < tokenizer.timestamp_begin:
            text.append(token)
            continue
        time = (token - tokenizer.timestamp_begin) * 0.02
        if text:
            out.append({"start": start, "end": min(time, duration), "text": tokenizer.decode(text)})
            text = []
        start = time
    return out


# Whisper learned from subtitled videos, where silence is often captioned with these, so it "hears" them in
# near-silence (breathing, keyboard, a quiet room). Normalized: lowercase, no punctuation.
GHOSTS = {
    "gracias", "muchas gracias", "gracias por ver", "gracias por ver el video", "thank you", "thanks", "thank you for watching",
    "thanks for watching", "you", "bye", "suscríbete al canal", "subtítulos realizados por la comunidad de amaraorg", "subtítulos por la comunidad de amaraorg",
}


def peak_dbfs(audio: np.ndarray) -> float:
    """Loudest 20 ms of the chunk, in dB below full scale."""
    frames = audio[: len(audio) // 320 * 320].reshape(-1, 320)
    return 20 * np.log10(np.sqrt((frames**2).mean(axis=1)).max() + 1e-9) if len(frames) else -120.0


def is_ghost(text: str, peak: float) -> bool:
    # In recorded meetings these phrases peaked around -34 dBFS when invented; real speech rarely goes below -23 dBFS.
    return peak < -26 and re.sub(r"[^\w\s]", "", text).strip().lower() in GHOSTS


def run(audio: np.ndarray, language: str | None):
    """Language is detected per call, so speakers can switch languages between utterances."""
    model = state["model"]
    duration = len(audio) / 16000
    peak = peak_dbfs(audio)
    if peak < -36:  # quieter than any real speech recorded so far (lowest 1%: -32 dBFS); Whisper would make something up
        return language or "", []
    mel = pad_or_trim(log_mel_spectrogram(audio, n_mels=model.dims.n_mels, padding=N_SAMPLES), N_FRAMES, axis=-2)
    features = model.encoder(mel.astype(mx.float16)[None])[0]  # encode once; detection and decoding both reuse it
    if language is None:
        _, probs = model.detect_language(features)
        language = max(LANGUAGES or probs, key=lambda l: probs.get(l, 0.0))
    result = decode(model, features, DecodingOptions(language=language, temperature=0.0))
    if result.no_speech_prob > 0.6 and result.avg_logprob < -1:
        return language, []  # silence or noise
    if duration > 30 or result.compression_ratio > 2.4 or result.avg_logprob < -1:
        # Too long for one window, or a doubtful decode: use the full pipeline with temperature fallback.
        result = whisper_transcribe(audio, path_or_hf_repo=REPO, language=language, condition_on_previous_text=False)
        found = [{"start": s["start"], "end": s["end"], "text": s["text"]} for s in result["segments"]]
    else:
        found = segments(result.tokens, language, duration)
    if is_ghost(" ".join(s["text"] for s in found), peak):
        log.info("dropped %r: likely invented in near-silence (peak %.0f dBFS)", " ".join(s["text"] for s in found).strip(), peak)
        return language, []
    return language, found


TITLE_PROMPT = """You name meetings from their transcripts, like a calendar event title.

Rules:
- 2 to 6 words about the subject discussed, e.g. "Q3 budget review", "Onboarding de nuevos ingenieros", "Landing page redesign feedback".
- Use the main language of the meeting.
- Name what was talked about, never the meeting itself: not its language, how it started or ended.
- Always give a title. If there is no clear subject, make your best guess from what was said, e.g. "Mic test" or "Charla informal".
- Reply with the title only, without quotes or a final period."""


def load_llm():
    from mlx_lm import load  # imported lazily, like pyannote

    if state["llm"] is None:
        log.info("loading %s; first run downloads it", LLM)
        state["llm"] = load(LLM)
    return state["llm"]


def title_for(transcript: str) -> str:
    from mlx_lm import generate

    model, tokenizer = load_llm()
    if len(transcript) > 30_000:  # the start and end of a long meeting are enough for a title, and much faster
        transcript = transcript[:22_000] + "\n[…]\n" + transcript[-8_000:]
    messages = [{"role": "system", "content": TITLE_PROMPT}, {"role": "user", "content": transcript}]
    prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True)
    text = generate(model, tokenizer, prompt=prompt, max_tokens=24)
    return text.strip().splitlines()[0].strip(' "“”.')


def load_diarizer():
    import torch  # imported lazily: torch and pyannote take seconds to load
    from pyannote.audio import Pipeline

    with diarizer_lock:
        if state["diarizer"] is None:
            log.info("loading %s; first run downloads it", DIARIZATION_MODEL)
            state["diarizer"] = Pipeline.from_pretrained(DIARIZATION_MODEL).to(torch.device("mps"))
    return state["diarizer"]


def preload_diarizer():
    try:
        load_diarizer()
    except Exception as e:  # e.g. not logged in to Hugging Face; /diarize reports it when used
        log.warning("speaker detection unavailable: %s", e)


def diarize_audio(audio: np.ndarray) -> tuple[list[dict], dict[str, list[float]]]:
    import torch

    output = load_diarizer()({"waveform": torch.from_numpy(audio)[None], "sample_rate": 16000})
    # Overlap-free turns line up better with transcript segments; voiceprints come in speaker_diarization label order.
    turns = [{"start": t.start, "end": t.end, "speaker": s} for t, _, s in output.exclusive_speaker_diarization.itertracks(yield_label=True)]
    voiceprints = dict(zip(output.speaker_diarization.labels(), output.speaker_embeddings.tolist()))
    return turns, voiceprints


@app.get("/health")
def health():
    return {"ready": state["model"] is not None, "model": MODEL, "error": state["error"]}


@app.post("/transcribe")
async def transcribe(request: Request, language: str = "auto"):
    """Body: raw 16 kHz mono signed 16-bit little-endian PCM."""
    if state["model"] is None:
        raise HTTPException(503, state["error"] or "model is still loading")
    audio = np.frombuffer(await request.body(), dtype=np.int16).astype(np.float32) / 32768.0
    started = time.time()
    lang, segments = await asyncio.wrap_future(mlx_thread.submit(run, audio, None if language == "auto" else language))
    elapsed = time.time() - started
    log.info("%.1fs of audio in %.1fs (%s)", len(audio) / 16000, elapsed, lang)
    return {"language": lang, "segments": segments, "elapsed": elapsed}



@app.post("/diarize")
async def diarize(request: Request):
    """Body: raw 16 kHz mono signed 16-bit little-endian PCM. Returns speaker turns and one voiceprint per speaker."""
    audio = np.frombuffer(await request.body(), dtype=np.int16).astype(np.float32) / 32768.0
    started = time.time()
    try:
        turns, voiceprints = await asyncio.to_thread(diarize_audio, audio)
    except Exception as e:
        log.exception("diarization failed")
        if "gated repo" in str(e):
            raise HTTPException(500, f"accept the terms at https://huggingface.co/{DIARIZATION_MODEL} and run `uvx --from huggingface_hub hf auth login`")
        raise HTTPException(500, f"diarization failed: {e}")
    log.info("diarized %.1fs of audio in %.1fs (%d speakers)", len(audio) / 16000, time.time() - started, len({t["speaker"] for t in turns}))
    return {"turns": turns, "voiceprints": voiceprints}


@app.post("/title")
async def title(request: Request):
    """Body: {"transcript": "Speaker: text\\n..."}. Returns a short title."""
    transcript = (await request.json())["transcript"]
    started = time.time()
    result = await asyncio.wrap_future(mlx_thread.submit(title_for, transcript))
    log.info("titled %d chars in %.1fs: %s", len(transcript), time.time() - started, result)
    return {"title": result}

def download(speakers: bool) -> int:
    """Fetch the models ahead of the first meeting (`./mel setup`). Exit code 3: speaker detection isn't accessible."""
    from huggingface_hub import snapshot_download

    logging.getLogger().setLevel(logging.WARNING)  # only this module's progress, plus the download bars
    log.setLevel(logging.INFO)
    for repo in (REPO, LLM):
        log.info("downloading %s", repo)
        snapshot_download(repo)
    if not speakers:
        return 0
    try:
        load_diarizer()
    except Exception as e:
        log.error("speaker detection unavailable: %s", str(e).splitlines()[0])
        return 3
    log.info("speaker detection ready")
    return 0


if __name__ == "__main__":
    import sys

    if sys.argv[1:2] == ["download"]:
        sys.exit(download(speakers="--speakers" in sys.argv))
    mlx_thread.submit(load_model)
    # Load the speaker and title models up front, so a meeting is finished right after it stops.
    mlx_thread.submit(load_llm)
    threading.Thread(target=preload_diarizer, daemon=True).start()
    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="warning")
