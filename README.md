# claude-code-session-journal

A [Claude Code](https://docs.claude.com/en/docs/claude-code) SessionEnd hook
that turns every session into a one-line **work journal entry** — with cost,
duration, tool usage, and a summary you write yourself.

Every session ends with a line like this appended to `cost-log.md`:

```
- 2026-07-11: $10.16 | drafted Phase 1 experiment plan, ran competitor research | Opus 4.7: $10.16
```

Read it back in a week and you have a diary of what you built and what it cost.

## Why this exists (vs [ccusage](https://ccusage.com/))

`ccusage` is a cost analyzer — great when you ask "how much did I spend this month?"

This tool is a **session journal** — the answer to "what did I do this week
and what did each session cost me?" You write a one-line summary during each
session; the hook stitches it together with cost, model breakdown, tool-use
counts, and duration.

If you keep a daily/weekly work log (Obsidian, Notion, a plain text diary),
`cost-log.md` drops in as an append-only source of truth for your AI-assisted
work.

## Requirements

- Windows with **PowerShell 5.1+** (also runs on PowerShell 7 unchanged)
- Claude Code (any recent version supporting the `SessionEnd` hook)

Non-Windows users: this is PowerShell-only for now. A Node port is on the
backlog if there's demand.

## Install

1. Clone or download this repository:

   ```powershell
   git clone https://github.com/Swift317/claude-code-session-journal.git
   ```

2. Copy `log-session-cost.ps1` somewhere Claude Code can reach it. The
   convention is `.claude\hooks\log-session-cost.ps1` inside your project,
   but any absolute path works.

3. Register the hook in your Claude Code `settings.json` (or `.claude/settings.json`):

   ```json
   {
     "hooks": {
       "SessionEnd": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\\path\\to\\log-session-cost.ps1\""
             }
           ]
         }
       ]
     }
   }
   ```

4. Start a Claude Code session, do some work, exit normally. A new line will
   appear in `%USERPROFILE%\.claude-code-session-journal\cost-log.md`.

## Writing session summaries

The whole point of this tool. During any session, write a one-line summary
of what you worked on to a marker file. On SessionEnd the hook consumes it
and folds it into the journal entry.

Default marker path: `<script_dir>\..\.session-summary`
(i.e. `.claude\.session-summary` if you install the script under `.claude\hooks\`).

From your Claude Code session, just tell the agent:

> Please write a one-line summary of this session to `.claude/.session-summary`.

Or write it yourself before exiting:

```powershell
"drafted Phase 1 plan, ran competitor research" | Set-Content .claude\.session-summary -Encoding utf8
```

If the marker file is missing on SessionEnd, the entry is written with
`(no summary)` — nothing breaks.

## Configuration (all optional)

| Environment variable | Default | Purpose |
|----------------------|---------|---------|
| `CCSJ_OUTPUT_DIR` | `%USERPROFILE%\.claude-code-session-journal` | Where `cost-log.md` and `cost-log.jsonl` live |
| `CCSJ_SUMMARY_FILE` | `<script_dir>\..\.session-summary` | Path to the summary marker |
| `CCSJ_QUIET` | (unset) | Set to `1` to suppress `hook-fired.log` / `hook-errors.log` |
| `CCSJ_UPLOAD_URL` | (unset) | ccsj-web ingest endpoint. Uploads are skipped unless both this and `CCSJ_UPLOAD_TOKEN` are set. |
| `CCSJ_UPLOAD_TOKEN` | (unset) | Bearer token issued when you register a machine in ccsj-web. Treat as a secret. |

Per-project journal: set `CCSJ_OUTPUT_DIR` inside a project's
`.claude\settings.json` via the hook `env` block, and each project gets its
own log.

## Sending sessions to ccsj-web (optional)

[ccsj-web](https://github.com/Swift317/ccsj-web) is a hosted dashboard that
turns these local logs into charts, tag rollups, and team aggregates.
Enable uploads by setting two env vars:

1. Register a machine at your ccsj-web instance and copy the token (shown
   once).
2. Add both env vars to your Claude Code `settings.json` under the hook's
   `env` block:

   ```json
   {
     "hooks": {
       "SessionEnd": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\\path\\to\\log-session-cost.ps1\"",
               "env": {
                 "CCSJ_UPLOAD_URL": "https://your-ccsj-web-host/api/upload",
                 "CCSJ_UPLOAD_TOKEN": "paste-machine-token-here"
               }
             }
           ]
         }
       ]
     }
   }
   ```

3. (Optional) Backfill existing sessions:

   ```powershell
   $env:CCSJ_UPLOAD_URL   = "https://your-ccsj-web-host/api/upload"
   $env:CCSJ_UPLOAD_TOKEN = "paste-machine-token-here"
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\backfill-upload.ps1
   ```

   The server dedupes on `(machine_id, session_id_ext)`, so re-running is
   safe.

Local writes to `cost-log.md` / `cost-log.jsonl` happen first and always
succeed even if the upload fails, so the journal stays intact when you're
offline or the server is down.

## Output files

### `cost-log.md` — human-readable

One line per session, newest at bottom:

```
- 2026-07-10: $8.02 | dry-skin rewrite pass 2 + sitemap.xml | Opus 4.7: $8.02
- 2026-07-11: $10.16 | drafted Phase 1 experiment plan, ran competitor research | Opus 4.7: $10.16
```

Format: `- <date>: $<total> | <summary> | <model>: $<cost>, <model>: $<cost>, ...`

### `cost-log.jsonl` — machine-readable

One JSON object per line for post-hoc analysis:

```json
{"date":"2026-07-11","session_id":"860e8700-...","summary":"drafted Phase 1...","duration_min":371.6,"turns":12,"cost_total":10.16,"models":{"claude-opus-4-7":{"cost":10.1566,"input_tokens":168,"cache_creation_tokens":185153,"cache_read_tokens":2421916,"output_tokens":40661,"messages":36}},"tool_use_counts":{"TaskUpdate":2,"Read":2,"Bash":4,"Edit":1}}
```

Feed it to `ConvertFrom-Json`, `jq`, DuckDB, or a spreadsheet.

## How pricing is calculated

Costs are per 1M tokens (USD), matching the current published Anthropic
pricing. The table lives in the top of `log-session-cost.ps1` — update it
when Anthropic changes prices (last verified: 2026-07-11):

- **Opus**: $15 in / $75 out / $18.75 cache-write-5m / $30 cache-write-1h / $1.50 cache-read
- **Sonnet**: $3 in / $15 out / $3.75 cache-write-5m / $6 cache-write-1h / $0.30 cache-read
- **Haiku**: $1 in / $5 out / $1.25 cache-write-5m / $2 cache-write-1h / $0.10 cache-read

Model detection is by regex (`opus` / `sonnet` / `haiku` in the model id).

## Limitations

- **`SessionEnd` doesn't fire on abnormal termination** (`/clear`, window
  force-close, process kill). Those sessions won't be logged. A companion
  script to backfill missed sessions on the next `SessionStart` may land in
  a future release.
- **Windows / PowerShell only.**
- **No aggregation.** This tool logs sessions; it doesn't roll up daily/monthly
  totals. Pair it with `ccusage` or your own `jq` one-liner if you want that.

## License

MIT
