# Setting up Mel with an agent

Instructions for an AI agent guiding a user from a fresh clone to a working first recording. Humans can just run `./mel setup`, an interactive wizard that does the same.

Two ways to go:

- **Simplest:** ask the user to run `./mel setup` in their own terminal (in Claude Code: `! ./mel setup`). It asks a few questions and handles everything. Then continue at [step 8](#8-verify). Use this whenever the user is comfortable typing a command.
- **Step by step**, below, when the user wants you to drive. The wizard reads answers from the terminal, so agents can't answer its prompts; these are its non-interactive equivalents.

Work from the repository root. Run `./mel doctor` at any point: it shows what's done and what's missing.

Tell the user up front: about 10 minutes, a ~4 GB download, and they'll need to click a few things (a password dialog, macOS permission prompts, optionally a Hugging Face form).

## 1. Check the Mac

```sh
uname -m                    # must be arm64
sw_vers -productVersion     # must be 15 or later
```

Mel needs Apple Silicon (models run on the Apple GPU) and macOS 15 (system audio capture through ScreenCaptureKit). If either fails, stop: Mel can't run on this Mac.

## 2. Developer tools

```sh
xcode-select -p && swift --version
```

If that fails, run `xcode-select --install`. **User:** a macOS dialog appears; they click Install and wait (5 to 15 minutes). Poll `xcode-select -p` until it succeeds.

```sh
command -v uv || ls ~/.local/bin/uv
```

If uv is missing, ask before installing, then run `curl -LsSf https://astral.sh/uv/install.sh | sh` and use `~/.local/bin/uv` (or open a new shell) until it's on the PATH. Homebrew users can `brew install uv` instead.

## 3. Languages

Ask which languages are spoken in the user's meetings. Mel detects among these only, per sentence. Write them as Whisper codes:

```sh
mkdir -p server && touch server/config.env
grep -v '^LANGUAGES=' server/config.env > server/config.env.tmp; echo 'LANGUAGES=en,es' >> server/config.env.tmp
mv server/config.env.tmp server/config.env
```

Keep any other lines in that file (`MODEL`, `LLM`).

## 4. Build

```sh
./mel build
```

This compiles the recorder and the app, creates the signing certificate `Mel local signing` in the login keychain on first run, and installs `~/Applications/Mel.app`. It takes 1 to 2 minutes.

- **User:** macOS may ask for their login password so the certificate can be added to the keychain.
- Agent sandboxes often block writing to the keychain. If the build fails at `security import`, ask the user to run `./mel build` themselves once (`! ./mel build`); later builds reuse the certificate.
- Why a certificate: macOS ties recording permissions to the app's signature; see `docs/setup.md`.

## 5. Models

Ask before downloading (~4 GB, into `models/`):

```sh
./mel download
```

Whisper large-v3-turbo (1.6 GB) and Qwen3 4B (2.3 GB). The first run also installs Python dependencies. The download resumes if interrupted; run it again.

## 6. Speaker detection (optional)

Without it, everyone else in a call is "Them". With it, speakers are told apart and recognized by voice. Ask if the user wants it. It needs a free Hugging Face account, and every part of it is the user's:

1. **User:** create a token with the Read role at <https://huggingface.co/settings/tokens> (`open` the URL for them).
2. **User:** log in by pasting the token in their terminal: `uvx --from huggingface_hub hf auth login` (in Claude Code: `! uvx --from huggingface_hub hf auth login`). Never ask for the token in the chat.
3. **User:** accept the terms at <https://huggingface.co/pyannote/speaker-diarization-community-1>: fill in the short form and click Agree.
4. Verify:

```sh
./mel download --speakers; echo $?
```

Exit code 0 means ready. Exit code 3 means Hugging Face refuses access: the user isn't logged in (`uvx --from huggingface_hub hf auth whoami`) or hasn't accepted the terms (step 3).

## 7. Start

```sh
./mel server
open ~/Applications/Mel.app
```

The server takes a few seconds to load the models; `curl -s 127.0.0.1:8765/health` shows `"ready": true` when done.

## 8. Verify

```sh
./mel doctor
```

Every line should be ✓; speaker detection may be `!` if the user skipped it.

## 9. First recording (the user)

Recording permissions can only be granted by the user, and only when a recording starts:

1. In Mel, click **+**.
2. macOS asks for **Microphone** and for **Screen & System Audio Recording**. Allow both.
3. macOS asks to **Quit & Reopen** Mel. Accept, then click **+** again.
4. Say a sentence, play a video with speech, and press **Esc** to stop. Within seconds the meeting gets a title and a transcript with "Me" and "Them" (or speaker names).

Suggest headphones for real meetings, so the call isn't also picked up by the microphone.

## When something fails

| Symptom | Cause | Fix |
| --- | --- | --- |
| "Mel couldn't hear anything" | Permissions not granted, or granted to an older build | System Settings › Privacy & Security: enable Mel under Microphone and Screen & System Audio Recording, then quit and reopen Mel. If it persists: `tccutil reset All local.mel` and record again. |
| Build fails at `security import` | The agent can't write to the keychain | The user runs `./mel build` once. |
| Build fails in Swift | Command Line Tools missing or outdated | `xcode-select --install`, or `softwareupdate --list` for updates. |
| `download --speakers` exits 3 | Not logged in, or terms not accepted | Step 6. |
| Health never gets ready | Model still downloading or failed to load | `./mel logs` |
| Port 8765 in use | Another program | `lsof -i :8765` |
| Transcript lags behind | Mac too slow for the model | Settings › Models › Whisper Small |
| Text nobody said ("Thank you.") | Whisper inventing text in silence | Mostly filtered; see `docs/transcription.md` |

Logs: `setup.log` (wizard), `server/server.log` (server, also `./mel logs`). How everything works: `docs/README.md`.
