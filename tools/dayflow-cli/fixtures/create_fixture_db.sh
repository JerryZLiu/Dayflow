#!/usr/bin/env bash
set -euo pipefail

# Creates a minimal Dayflow SQLite fixture for CLI development and tests.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_PATH="${1:-$ROOT/chunks.sqlite}"

rm -f "$DB_PATH" "${DB_PATH}-wal" "${DB_PATH}-shm"
sqlite3 "$DB_PATH" <<'SQL'
PRAGMA journal_mode = WAL;

CREATE TABLE timeline_cards (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  batch_id INTEGER,
  start TEXT NOT NULL,
  end TEXT NOT NULL,
  start_ts INTEGER,
  end_ts INTEGER,
  day DATE NOT NULL,
  title TEXT NOT NULL,
  summary TEXT,
  category TEXT NOT NULL,
  subcategory TEXT,
  detailed_summary TEXT,
  metadata TEXT,
  video_summary_url TEXT,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  is_deleted INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE screenshots (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  captured_at INTEGER NOT NULL,
  file_path TEXT NOT NULL,
  file_size INTEGER,
  idle_seconds_at_capture INTEGER,
  is_deleted INTEGER DEFAULT 0,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE analysis_batches (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  batch_start_ts INTEGER NOT NULL,
  batch_end_ts INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  reason TEXT,
  llm_metadata TEXT,
  detailed_transcription TEXT,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_standup_entries (
  standup_day TEXT NOT NULL PRIMARY KEY,
  payload_json TEXT NOT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Two activities on a fixed day for deterministic CLI output.
INSERT INTO timeline_cards (
  start, end, start_ts, end_ts, day, title, summary, category, subcategory,
  detailed_summary, metadata
) VALUES
(
  '9:00 AM', '10:30 AM',
  strftime('%s', '2026-03-11 09:00:00'),
  strftime('%s', '2026-03-11 10:30:00'),
  '2026-03-11',
  'Ship Dayflow CLI timeline command',
  'Implemented read-only timeline queries against chunks.sqlite.',
  'Work', 'Engineering',
  'Worked through SQL query parity with StorageManager and added JSON output.',
  '{"appSites":{"primary":"Cursor","secondary":"Terminal"},"distractions":[]}'
),
(
  '2:00 PM', '2:45 PM',
  strftime('%s', '2026-03-11 14:00:00'),
  strftime('%s', '2026-03-11 14:45:00'),
  '2026-03-11',
  'Review pull request',
  'Reviewed environment setup changes for Cloud Agents.',
  'Work', 'Engineering',
  'Checked install scripts, fixtures, and Linux build support.',
  '{"appSites":{"primary":"GitHub","secondary":"Safari"},"distractions":[{"title":"Slack"}]}'
);

INSERT INTO screenshots (captured_at, file_path)
VALUES (strftime('%s', '2026-03-11 14:40:00'), '/tmp/dayflow-fixture.png');

INSERT INTO analysis_batches (batch_start_ts, batch_end_ts, status)
VALUES (
  strftime('%s', '2026-03-11 08:00:00'),
  strftime('%s', '2026-03-11 15:00:00'),
  'completed'
);

INSERT INTO daily_standup_entries (standup_day, payload_json)
VALUES (
  '2026-03-11',
  '{"highlightsTitle":"Highlights","highlights":[{"text":"Dayflow CLI builds on Linux"}],"tasksTitle":"Tasks","tasks":[{"text":"Validate environment setup end to end"}],"blockersTitle":"Blockers","blockersBody":"None"}'
);
SQL

echo "Created fixture database at $DB_PATH"
