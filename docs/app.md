# The app

`Mel.app` is a SwiftUI app (`app/Sources`) in two files: `App.swift` holds the state and talks to `./mel`, `Views.swift` the interface. It follows the standard macOS layout: a sidebar of meetings grouped by day, a detail page, a toolbar and a Settings window.

## A thin layer over `./mel`

The app doesn't record or transcribe by itself. It runs the same commands you'd type:

```mermaid
flowchart LR
    subgraph app["Mel.app"]
        model["Model<br/>(ObservableObject)"]
        views["Views"]
    end
    model -- "./mel start --language xx" --> rec["recording"]
    rec -- "stdout lines" --> model
    model -- "stdin: language es" --> rec
    model -- "./mel transcribe folder" --> tr["re-transcription"]
    model -- "./mel server / stop" --> srv["server"]
    model -- "GET /health every 2 s" --> srv
    model -- "reads and edits" --> files[("recordings/<br/>voices.json<br/>config.env")]
    views --> model
```

- **Recording** runs `./mel start` and reads its output line by line: `[00:01:02] Them (es): …` becomes a live transcript entry, `Titled “…” → folder` tells it the final folder. Changing the language writes `language es` to the recording's stdin.
- **Stopping** sends `SIGTERM` once. **Skip** sends another, which skips the current step ([after the meeting](after-the-meeting.md)).
- **The server** starts when the app opens and stops when you quit, unless a recording started from the terminal is still using it.
- **Editing** works on the files directly: renaming a meeting renames its folder; naming a speaker rewrites `transcript.json` and `transcript.md` in the client's format, updates `speakers.json` and [learns the voice](voices.md).

## Pages

| Page | What's on it |
| --- | --- |
| Meeting | Editable title, date, speaker chips (click to name), transcript grouped by speaker, and a player along the bottom. Hovering a block turns its avatar into a play button. |
| Recording | The transcript as it's written, with the time, language and Stop along the bottom. |
| Floating transcript | A dark panel above every window and Space, with the transcript as chat bubbles (yours on the right), so you can follow it during a full-screen call. It's an `NSPanel` that never takes focus. |
| Settings | Recording language and microphone, models, server status and logs, voices, storage. |

## Keyboard

| Key | Action |
| --- | --- |
| ⌘R | New recording |
| Esc, ⌘. | Stop recording |
| Space | Play or pause; on the recording page, stop |
| ← → | Skip 15 seconds |
| ↑ ↓ | Previous or next meeting |
| ⌫ | Move the meeting to the Trash |
| ⇧⌘C | Copy the transcript |
| ⌥⌘R | Show in Finder |
| ⇧⌘T | Show the floating transcript |

Space and the arrows go through an `NSEvent` monitor, so they work wherever focus is, except while you're typing.

## Building

`./mel build` compiles the app with SwiftPM, wraps it into `~/Applications/Mel.app` with `app/Info.plist` and the icon, and signs it. The bundle records where the repository is (`MelRoot` in Info.plist), which is how the app finds `./mel`. See [Setup](setup.md) for why signing matters.

The icon is drawn by `app/Icon/make-icon.swift`: a mel spectrogram of three spoken syllables in matplotlib's *magma* colormap. Delete `app/Icon/AppIcon.icns` and rebuild to regenerate it.
