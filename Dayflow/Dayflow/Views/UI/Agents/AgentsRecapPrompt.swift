//
//  AgentsRecapPrompt.swift
//  Dayflow
//
//  Builds the one-shot prompt for the headless Fable run that generates the
//  Agents tab data. The run is expected to read the day's Claude Code and
//  Codex session transcripts off disk and write a single JSON file matching
//  the AgentsModels schema.
//

import Foundation

enum AgentsRecapPrompt {

  /// Marker embedded in every recap prompt. The prompt instructs the model to
  /// skip any session transcript containing this string, so the recap run
  /// never summarizes itself (its own session file is being written while it
  /// runs).
  static let runMarker = "DAYFLOW_AGENTS_RECAP_RUN"

  /// - Parameters:
  ///   - day: calendar day being summarized, formatted yyyy-MM-dd (local time)
  ///   - outputPath: absolute path the model must write the JSON file to
  static func build(day: String, outputPath: String) -> String {
    let home = NSHomeDirectory()
    let codexDayPath = day.replacingOccurrences(of: "-", with: "/")

    return """
      \(runMarker) — you are running headlessly to generate data for Dayflow's Agents view. Do not ask questions; make reasonable judgment calls and finish in one shot.

      ## Goal
      Read every Claude Code and Codex CLI session from \(day) (local time) on this machine, and produce ONE JSON file that summarizes the day's agent activity as workstreams → threads → condensed turns. A macOS app renders this file directly, so the JSON must match the schema below exactly.

      ## Where sessions live
      - Claude Code: \(home)/.claude/projects/<encoded-project-dir>/*.jsonl — one file per session. The directory name encodes the project path ('/' replaced with '-'). Only include session files whose modification time falls on \(day). `find \(home)/.claude/projects -name '*.jsonl' -newermt '\(day) 00:00' ! -newermt '\(day) 23:59:59'` is a good starting point.
      - Codex CLI: \(home)/.codex/sessions/\(codexDayPath)/rollout-*.jsonl (already partitioned by day).

      ## How to read them — important
      Session files can be many megabytes. NEVER read a whole large file. Use jq/grep/head/tail to extract only what you need:
      - Claude Code JSONL: each line is a JSON object. Human prompts are lines with .type=="user" whose .message.content is a plain string or contains text blocks — but lines whose content is tool_result blocks are tool output, NOT human turns; exclude them. Assistant text lives in .type=="assistant" lines under .message.content[].text. Skip lines with .isSidechain==true (subagent chatter). The file's early lines carry the cwd/project path.
      - Codex JSONL: look for message items with role "user" / "assistant" (user text is sometimes wrapped in <user_message> tags; strip the tags). The session_meta line carries the cwd.
      A practical approach per file: count real human messages first; if zero, skip the session entirely.
      Work fast: parallelize the sweep by spawning subagents (your Task tool) with model: "sonnet" — e.g. one subagent per project directory, each returning condensed threads for its sessions. The sweep is mechanical extraction, so the faster model is the right tool for it; reserve your own judgment for grouping the workstreams and assembling + writing the final JSON yourself. Budget roughly 15 minutes of wall time.

      ## Sessions to exclude
      - Any transcript containing the string \(runMarker) (that is this recap run itself, or a previous one).
      - Sessions with zero real human messages (warmup/automation noise).
      - Pure subagent transcripts.

      ## What to produce per session ("thread")
      - title: short description of what the thread was about, max 60 chars.
      - turns: the session condensed into AT MOST 12 alternating turns. Each user turn paraphrases what the human asked or decided (max 120 chars, keep the human's voice: "Switch over to Gemini"). Each agent turn states the OUTCOME of what the agent did or answered — what it concluded or delivered, not what it attempted. Merge runs of small back-and-forth into single turns. Trivial Q&A sessions may have just 2 turns.
      - highlight: mark at most 3 turns per thread, only where truly warranted (many threads have none):
        - "keyDecision" — a fork in direction (human or agent made a call that changed the path).
        - "keyInfo" — findings worth remembering later; put the specifics as short strings in that turn's "bullets" array.
        - "readyForReview" — a finished deliverable awaiting human review; usually the final agent turn.
      - status, exactly one of:
        - "reviewReady" — the agent finished and produced something the human has not yet acted on.
        - "blocked" — the agent stopped needing input, hit an error it could not resolve, or asked a question that was never answered.
        - "inProgress" — the session file was modified within the last 15 minutes.
        - "completed" — everything else (thread concluded, question answered, work acknowledged).
      - latestOutcome: one line, the current end-state of the thread (max 90 chars).
      - artifacts: if a turn produced a distinct deliverable (a report, doc, PR, generated file), set artifactName (short label) and artifactPath (absolute path if known) on that turn.
      - sessionPath: the absolute path of the transcript file. source: "claude" or "codex". projectName: human-readable project folder name (e.g. "Dayflow", "DayflowWeb"), empty string if none.

      ## Workstreams
      Group the threads into 3–7 workstreams by project and purpose, with short human names ("Dayflow Backend", "Research", "SEO", "Marketing"). Use "Miscellaneous" for stragglers rather than inventing thin groups. Each workstream gets:
      - summary: one line describing what happened there today (max 90 chars).
      - bullets: 2–5 accomplishment strings, outcome-phrased ("Found out users used Dayflow for 500k hours").

      ## Output
      Write the JSON to exactly this path (create the directory if needed): \(outputPath)
      It must match this schema — same keys, same enum values, nothing extra:

      {
        "schemaVersion": 1,
        "day": "\(day)",
        "generatedAt": "<ISO-8601 timestamp with offset>",
        "workstreams": [
          {
            "id": "dayflow-backend",
            "name": "Dayflow Backend",
            "summary": "Finding solutions for expired credits, updated Sonnet",
            "bullets": ["Explored solutions for expiring credits, switched to Gemini"],
            "threads": [
              {
                "id": "expired-openai-credits",
                "title": "Find solutions for addressing expired OpenAI credits",
                "source": "claude",
                "projectName": "DayflowWeb",
                "sessionPath": "\(home)/.claude/projects/-Users-x-DayflowWeb/0199-example.jsonl",
                "status": "reviewReady",
                "startedAt": "\(day)T09:14:00-07:00",
                "endedAt": "\(day)T11:32:00-07:00",
                "latestOutcome": "Tuned prompts to enhance Gemini performance",
                "turns": [
                  { "role": "user", "text": "Move to Gemini and run evals", "highlight": "none", "bullets": [] },
                  { "role": "agent", "text": "Evals were mid", "highlight": "none", "bullets": [] },
                  { "role": "user", "text": "Ran out of Claude credits. Switch over to Gemini.", "highlight": "keyDecision", "bullets": [] },
                  { "role": "agent", "text": "Prompts are optimized, ready for review", "highlight": "readyForReview", "bullets": [], "artifactName": "Prompt tuning report", "artifactPath": "/path/to/report.md" }
                ]
              }
            ]
          }
        ]
      }

      Rules: ids are unique kebab-case strings; timestamps are ISO-8601 with a timezone offset; "highlight" is one of none/keyDecision/keyInfo/readyForReview; "status" is one of blocked/reviewReady/inProgress/completed; "source" is claude/codex. Omit artifactName/artifactPath when there is no artifact. The file must be raw JSON — no markdown fences, no commentary.

      Validate the file parses (e.g. `jq . <file>`) before finishing. Then reply with exactly: DONE
      """
  }
}
