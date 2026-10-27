-- Mel's database. ./mel applies db/NNN_*.sql in order and records the last one in PRAGMA user_version.
-- Audio stays in files: meetings.folder is a folder in Recordings/ next to this database.

CREATE TABLE settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

INSERT INTO settings (key, value) VALUES
  ('languages', 'en,es'),                                   -- detected among these, per sentence
  ('model', 'mlx-community/whisper-large-v3-turbo'),        -- transcription
  ('llm', 'mlx-community/Qwen3-4B-Instruct-2507-4bit'),     -- titles
  ('language', 'auto'),                                     -- recording language: auto or a code
  ('mic', '1'),                                             -- record the microphone
  ('floating_transcript', '1');                             -- show the floating panel while recording

-- Someone you've named. Their voiceprint is the running mean of the speakers linked to them.
CREATE TABLE people (
  id         INTEGER PRIMARY KEY,
  name       TEXT NOT NULL UNIQUE COLLATE NOCASE,
  voiceprint BLOB NOT NULL,                                 -- 256 float32, little endian, unit length
  meetings   INTEGER NOT NULL DEFAULT 1,                    -- weight of the running mean
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%S', 'now', 'localtime'))
);

CREATE TABLE meetings (
  id         INTEGER PRIMARY KEY,
  title      TEXT,                                          -- NULL until named
  started_at TEXT NOT NULL,                                 -- local time, ISO 8601
  duration   REAL,                                          -- seconds, set when it ends
  folder     TEXT NOT NULL UNIQUE,                          -- Recordings/<folder>/: mic.wav, system.wav, meeting.wav
  language   TEXT NOT NULL DEFAULT 'auto',
  status     TEXT NOT NULL DEFAULT 'recording' CHECK (status IN ('recording', 'processing', 'done'))
);

-- A voice in one meeting: "Me" (the microphone), "Them" (the call, before speaker detection)
-- or "Speaker N". Shown as the linked person's name when there is one.
CREATE TABLE speakers (
  id         INTEGER PRIMARY KEY,
  meeting_id INTEGER NOT NULL REFERENCES meetings ON DELETE CASCADE,
  label      TEXT NOT NULL,
  person_id  INTEGER REFERENCES people ON DELETE SET NULL,
  voiceprint BLOB,                                          -- from speaker detection
  UNIQUE (meeting_id, label)
);
CREATE INDEX speakers_by_person ON speakers (person_id);

-- One line of a transcript, as Whisper returns it: usually a sentence.
CREATE TABLE segments (
  id         INTEGER PRIMARY KEY,
  meeting_id INTEGER NOT NULL REFERENCES meetings ON DELETE CASCADE,
  speaker_id INTEGER NOT NULL REFERENCES speakers ON DELETE CASCADE,
  start      REAL NOT NULL,                                 -- seconds from the start of the meeting
  end        REAL NOT NULL,
  language   TEXT,
  text       TEXT NOT NULL
);
CREATE INDEX segments_by_meeting ON segments (meeting_id, start);

-- Full-text search over every transcript, accent-insensitive ("reunion" finds "reunión").
CREATE VIRTUAL TABLE segments_search USING fts5 (
  text, content = 'segments', content_rowid = 'id', tokenize = 'unicode61 remove_diacritics 2'
);
CREATE TRIGGER segments_search_insert AFTER INSERT ON segments BEGIN
  INSERT INTO segments_search (rowid, text) VALUES (new.id, new.text);
END;
CREATE TRIGGER segments_search_delete AFTER DELETE ON segments BEGIN
  INSERT INTO segments_search (segments_search, rowid, text) VALUES ('delete', old.id, old.text);
END;
CREATE TRIGGER segments_search_update AFTER UPDATE OF text ON segments BEGIN
  INSERT INTO segments_search (segments_search, rowid, text) VALUES ('delete', old.id, old.text);
  INSERT INTO segments_search (rowid, text) VALUES (new.id, new.text);
END;
