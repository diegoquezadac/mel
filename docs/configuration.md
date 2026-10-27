# Configuration

## Languages and models

Settings are rows of the `settings` table in `mel.db` ([data](data.md)). Setup writes the languages, the app's **Settings** everything else, and `./mel` passes the server's ones as environment variables every time it starts it. Environment variables you set yourself win.

| Setting | Default | |
| --- | --- | --- |
| `languages` (`LANGUAGES`) | `en,es` | Languages spoken in your meetings. Detection only chooses among these. Any [Whisper language code](https://github.com/openai/whisper/blob/main/whisper/tokenizer.py). |
| `model` (`MODEL`) | `mlx-community/whisper-large-v3-turbo` | Any MLX Whisper repo on Hugging Face, or a short name like `large-v3-turbo`. |
| `llm` (`LLM`) | `mlx-community/Qwen3-4B-Instruct-2507-4bit` | Title model; any mlx-lm chat model. The app offers Qwen2.5 7B and Llama 3.2 3B and 1B. |
| `DIARIZATION_MODEL` (environment only) | `pyannote/speaker-diarization-community-1` | pyannote pipeline. |
| `PORT` (environment only) | `8765` | Server port. |

The app's Settings also hold the recording language (`language`), the microphone (`mic`) and the floating transcript (`floating_transcript`). The server reads its settings at startup: after changing one by hand (`./mel sql "UPDATE settings SET value = 'en,pt' WHERE key = 'languages'"`), run `./mel stop`. The app restarts it when you change a model.

## Command line

```
./mel setup                    install or update, step by step
./mel doctor                   check everything
./mel app                      open the app
./mel start [title]            record; Ctrl+C stops (again: skip the current step)
        --language xx          a fixed language instead of auto-detect
        --no-mic               only what the Mac plays
./mel transcribe <meeting>     transcribe a meeting again (by id)
        --language xx
./mel server | stop | logs     run, stop or follow the server
./mel build                    rebuild the recorder and the app
./mel download [--speakers]    download the configured models
./mel export <meeting>         print a meeting as Markdown
./mel sql [query]              open the database, or run a query
./mel import                   move data from before the database into it
```

While `./mel start` runs, type `language es` (or `auto`) and Enter to change the language for the rest of the meeting.

## Server API

`server/app.py` serves on `127.0.0.1:8765`:

| Endpoint | Body | Returns |
| --- | --- | --- |
| `GET /health` | | `{"ready", "model", "error"}` |
| `POST /transcribe?language=auto` | 16 kHz mono int16 PCM | `{"language", "segments": [{"start", "end", "text"}]}` |
| `POST /diarize` | 16 kHz mono int16 PCM | `{"turns": [{"start", "end", "speaker"}], "voiceprints": {label: [256 floats]}}` |
| `POST /title` | `{"transcript": "Speaker: text\n…"}` | `{"title"}` |

`./mel download [--speakers]` fetches the configured models without starting the server (setup uses it).
