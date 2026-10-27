# 5. Voices

Name a speaker once, and Mel recognizes them in every meeting, before and after.

```mermaid
flowchart TD
    N["You name 'Speaker 2' → Ana<br/>in a meeting"] --> R["Link the speaker<br/>to the person Ana"]
    R --> L["Learn: fold the speaker's voiceprint<br/>into Ana's"]
    L --> P["Earlier meetings:<br/>an unnamed speaker that<br/>sounds like Ana becomes Ana"]
    L --> F["Later meetings:<br/>speaker detection names<br/>matching voices"]
```

## Voiceprints

Speaker detection gives every speaker in a meeting a voiceprint: a 256-number vector from pyannote's speaker-embedding model. Two recordings of the same person point in nearly the same direction; different people don't. Mel compares voices by **cosine similarity**:

| | Typical similarity |
| --- | --- |
| Same person, different meetings | ~0.9 |
| Different people | 0.3 to 0.7 |
| Mel's threshold (`VOICE_MATCH`) | **0.75** |

## Learning

Each person is a row of `people` with one voiceprint and how many meetings it came from. Naming a speaker links them to that person (`speakers.person_id`), creating the person if needed, and folds the speaker's voiceprint into the person's: an average weighted by meeting count. Different microphones, rooms and connections all feed one profile, so recognition improves the more you name.

The transcript itself isn't rewritten: a speaker's name is the linked person's name, or the speaker's label ("Speaker 2") when there's no person. Renaming a person renames them in every meeting at once.

## Recognizing

- **New meetings.** After speaker detection, each speaker's voiceprint is compared to every named voice. The best pairs are matched first, each name is used once per meeting, and only pairs above the threshold count. The rest stay "Speaker N".
- **Earlier meetings.** When you name someone, and every time the app opens, Mel looks for that voice in your other meetings. A speaker still called "Speaker N" whose voiceprint matches gets the name, without transcribing again. It never renames someone who already has a name.

Only other people are recognized: your microphone is always "Me".

## Managing voices

**Settings › Voices** lists everyone Mel knows and lets you forget a voice: Mel stops recognizing them, and meetings where they were named keep the name. Voiceprints never leave your Mac.

---

[← 4. After the meeting](04-after-the-meeting.md) · [6. Data →](06-data.md)
