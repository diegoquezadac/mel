# How Mel works

Mel records a meeting from your Mac, transcribes it while it happens, and when it ends tells the speakers apart and gives the meeting a title. Every model runs locally on the Apple GPU.

## Read in order

These pages follow one meeting from the moment you press record. Each one ends with a link to the next.

1. [Overview](01-overview.md): the pieces, how they talk, and a meeting end to end.
2. [Recording](02-recording.md): capturing your microphone and the call, and cutting the audio into utterances.
3. [Transcription](03-transcription.md): Whisper on the GPU, a language per sentence, and dropping text nobody said.
4. [After the meeting](04-after-the-meeting.md): stopping safely, telling speakers apart and writing a title.
5. [Voices](05-voices.md): naming someone once and recognizing them in every meeting.
6. [Data](06-data.md): the SQLite database that holds all of it, with example queries.
7. [The app](07-app.md): how the macOS app sits on top, the floating transcript and the keyboard.

The overview alone is enough to get the big picture.

## Look up when needed

- [Setup and permissions](setup.md): what `./mel setup` does, code signing and macOS privacy permissions.
- [Configuration](configuration.md): settings, models and every command.
- [Troubleshooting](troubleshooting.md): when something doesn't work.

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
docs/                   this documentation
models/                 downloaded models (not in git)

~/Library/Application Support/Mel/   your data: mel.db and Recordings/ (see 06-data.md)
```
