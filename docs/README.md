# How Mel works

Mel records a meeting from your Mac, transcribes it while it happens, and when it ends tells the speakers apart and gives the meeting a title. Every model runs locally on the Apple GPU.

Start with the [architecture](architecture.md) for the big picture, then follow a meeting through the system:

| | |
| --- | --- |
| [Architecture](architecture.md) | The pieces, how they talk, and what ends up on disk |
| [Recording](recording.md) | Capturing your mic and the call, and cutting the audio into utterances |
| [Transcription](transcription.md) | Whisper on MLX, per-sentence language detection, and filtering invented text |
| [After the meeting](after-the-meeting.md) | Stopping safely, speaker detection and automatic titles |
| [Voices](voices.md) | Naming a speaker once and recognizing them in every meeting |
| [Data](data.md) | The SQLite database: tables, migrations and example queries |
| [The app](app.md) | The SwiftUI app, the floating transcript and keyboard control |
| [Setup and permissions](setup.md) | What `./mel setup` does, code signing and macOS privacy permissions |
| [Configuration](configuration.md) | Languages, models and the command line |
| [Troubleshooting](troubleshooting.md) | When something doesn't work |

## Repository map

```
mel                     the command line: setup, build, record, server
scripts/setup.sh        the setup wizard and ./mel doctor
scripts/import.py       moves data from before the database into it
db/                     the database schema, as numbered migrations
capture/                mel-capture, Swift: mic + system audio through ScreenCaptureKit
client/mel.py           records, cuts utterances, drives transcription and post-processing
server/app.py           local HTTP server: Whisper, pyannote and the title LLM
app/                    Mel.app, SwiftUI; drives ./mel
  Icon/make-icon.swift  draws the app icon
docs/                   you are here
models/                 downloaded models (not in git)

~/Library/Application Support/Mel/   your data: mel.db and Recordings/ (see data.md)
```
