# Troubleshooting

Start with `./mel doctor`: it checks the Mac, the tools, the build, the models and the server, and says how to fix what's missing.

## "Mel couldn't hear anything"

The recording got no audio at all, which means macOS didn't grant the permissions.

1. System Settings › Privacy & Security › **Microphone** and **Screen & System Audio Recording**: turn Mel on in both (or your terminal, for `./mel start`).
2. Quit and reopen Mel. macOS only applies these permissions on launch.
3. Still nothing? Remove old Mel entries with **−**, run `tccutil reset All local.mel`, and record again so macOS asks from scratch.

## My voice appears twice, or the others appear as "Me"

Your microphone hears the speakers. Use headphones.

## The transcript lags behind

The model can't keep up on this Mac; the recording prints a warning when that happens. Audio is safe either way. Pick **Whisper Small** in Settings › Models, or let it catch up after the meeting.

## Everyone else is "Them"

Speaker detection isn't set up, or it failed. Run `./mel setup` and accept the optional step. `./mel logs` shows the reason, such as model terms not accepted on Hugging Face.

## The wrong person was recognized

Name them correctly in that meeting: their voice is learned from it. If a voice keeps matching the wrong people, forget it in Settings › Voices and name them again in a meeting with clear audio.

## Words that nobody said

Whisper sometimes writes "Thank you." or "Gracias." for near-silence; Mel filters the usual ones ([why](transcription.md#text-that-nobody-said)). If others slip through, add them to `GHOSTS` in `server/app.py`.

## The server doesn't start

`./mel logs` shows its output. Common causes: a model still downloading (the first start takes a while), or another process on port 8765 (`lsof -i :8765`).

## Something else

`setup.log` has the output of the last setup, `server/server.log` the server's. Please include both when you open an issue.
