# AGENTS.md

Mel records meetings on a Mac (the microphone plus the call's audio) and transcribes them locally: Whisper for text, pyannote for speakers, a small LLM for titles, all on the Apple GPU. A SwiftUI app sits on top of a command line, `./mel`.

## If the user wants to install or fix Mel

Follow [SETUP.md](SETUP.md). It takes a user from a fresh clone to a working first recording, says which steps only the user can do, and how to diagnose each failure. Run `./mel doctor` whenever you need to know what state the installation is in.

## Ground rules

- **Recordings are private.** `~/Library/Application Support/Mel/` (`mel.db` and `Recordings/`) holds real conversations. Read them only when the user's request needs it, never paste their content into issues, commits, web searches or other services, and never copy them into the repository.
- **Secrets stay with the user.** Never ask for a Hugging Face token in the chat. The user pastes it into `hf auth login` in their own terminal (in Claude Code: `! uvx --from huggingface_hub hf auth login`).
- **Ask before anything heavy or persistent:** downloading models (~4 GB), installing tools, creating the signing certificate, or resetting macOS permissions (`tccutil reset`).
- **Don't stop a recording.** Before restarting the app, the server or rebuilding, check that none is running: `pgrep -f "client/mel.py record"`. Quitting the app or `./mel stop` mid-meeting stops live transcription.
- **macOS permission prompts, keychain password dialogs and Hugging Face web forms need the user.** Tell them exactly what to click instead of retrying.

## Working on the code

| Path | What it is |
| --- | --- |
| `mel` | Entry point (bash): build, setup, server lifecycle, recording |
| `scripts/setup.sh` | The setup wizard and `./mel doctor` |
| `capture/` | `mel-capture`, Swift: ScreenCaptureKit audio to framed PCM on stdout |
| `client/mel.py` | Recording, utterance cutting, writing transcripts to `mel.db`, post-processing |
| `server/app.py` | FastAPI on 127.0.0.1:8765: `/transcribe`, `/diarize`, `/title` |
| `app/Sources/` | Mel.app (SwiftUI): `App.swift` state and processes, `Database.swift` SQLite, `Views.swift` UI |
| `db/` | The schema as numbered migrations, applied by `./mel` |
| `docs/` | How everything works, with diagrams. Start at `docs/README.md` |

- All data lives in SQLite (`docs/data.md`); query it with `./mel sql`. Change the schema only by adding the next `db/NNN_*.sql`; never edit one that has shipped. The server never touches the database.
- Python scripts declare their dependencies inline (PEP 723); run them with `uv run`, never pip.
- `./mel build` rebuilds the recorder and the app (into `~/Applications/Mel.app`). Restart the app afterwards to see changes.
- MLX work must stay on the server's single `mlx_thread`; MLX binds GPU streams to the thread that created them.
- The app only drives `./mel` and reads and edits the database; keep recording and transcription logic in the client and server, so the terminal and the app behave the same.
- The UI follows standard macOS patterns (sidebar, toolbar, `Form` settings, SF Symbols, system colors). Avoid custom chrome.
- Match the surrounding code's style and comment density. When behavior changes, update the matching page in `docs/`.
- There is no test suite. Verify changes by running them: `./mel doctor`, `./mel transcribe <meeting>` on a short meeting, `./mel export <meeting>`, `./mel logs`.
