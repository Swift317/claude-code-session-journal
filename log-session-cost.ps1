# claude-code-session-journal
# SessionEnd hook: parse the Claude Code session transcript, calculate token
# cost per model, and append the session to a persistent work journal.
#
# Output:
#   <OutputDir>\cost-log.md    - human-readable one-line-per-session log
#                                 (great for daily/weekly review or dropping
#                                  into Obsidian / Notion / a diary app)
#   <OutputDir>\cost-log.jsonl - machine-readable JSONL for later analysis
#
# The "session summary" field lets you record what you actually did in the
# session. Write one line of free-form text into <SummaryFile> at any point
# during the session; on SessionEnd this file is consumed and its contents
# become the summary in both cost-log.md and cost-log.jsonl. This is the
# core differentiator vs pure cost trackers: the log doubles as a work log.
#
# Configuration (all optional, via environment variables):
#   CCSJ_OUTPUT_DIR    - where cost-log.{md,jsonl} live
#                        default: %USERPROFILE%\.claude-code-session-journal
#   CCSJ_SUMMARY_FILE  - path to the .session-summary marker file
#                        default: <script_dir>\..\.session-summary
#                        (i.e. .claude\.session-summary if installed at
#                         .claude\hooks\log-session-cost.ps1)
#   CCSJ_QUIET         - if "1", suppress hook-fired.log / hook-errors.log
#                        default: unset (debug logs written next to script)
#   CCSJ_UPLOAD_URL    - ccsj-web ingest endpoint (e.g. https://ccsj.dev/api/upload)
#                        upload is skipped unless both URL and TOKEN are set
#   CCSJ_UPLOAD_TOKEN  - machine token from ccsj-web (Machines > New > copy once)
#                        used as Bearer token; treat as a secret
#
# Invocation modes:
#   1. SessionEnd hook  : stdin JSON payload (transcript_path, session_id)
#   2. Replay (manual / companion check-missing-sessions.ps1):
#        -TranscriptPath <path> -SessionId <uuid> -Replay
#
# In -Replay mode the .session-summary marker is NOT consumed
# (that marker belongs to the live session, not the old one being replayed).
#
# Pricing is per 1M tokens (USD). Update the $pricing hashtable below when
# Anthropic prices change. Last verified: 2026-07-11.
#
# Requires PowerShell 5.1+ (Windows). Runs unmodified on PowerShell 7.

param(
    [string]$TranscriptPath,
    [string]$SessionId,
    [switch]$Replay
)

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot

# ---- resolve output paths from env vars with sensible defaults ----
if ($env:CCSJ_OUTPUT_DIR) {
    $logDir = $env:CCSJ_OUTPUT_DIR
} else {
    $logDir = Join-Path $env:USERPROFILE '.claude-code-session-journal'
}
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$mdFile    = Join-Path $logDir 'cost-log.md'
$jsonlFile = Join-Path $logDir 'cost-log.jsonl'

if ($env:CCSJ_SUMMARY_FILE) {
    $summaryFile = $env:CCSJ_SUMMARY_FILE
} else {
    $summaryFile = Join-Path $scriptDir '..\.session-summary'
}

$debugEnabled = ($env:CCSJ_QUIET -ne '1')
$errLog   = Join-Path $scriptDir 'hook-errors.log'
$firedLog = Join-Path $scriptDir 'hook-fired.log'

# fire marker: records that the hook was invoked at all (debug)
if ($debugEnabled) {
    try {
        $mode = if ($Replay.IsPresent) { 'replay' } else { 'SessionEnd' }
        $fireLine = '[{0}] log-session-cost fired ({1}) cwd={2}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $mode, (Get-Location).Path
        [System.IO.File]::AppendAllText($firedLog, $fireLine + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    } catch {}
}

function Write-ErrLog($msg) {
    if (-not $debugEnabled) { return }
    try {
        $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $msg
        [System.IO.File]::AppendAllText($errLog, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    } catch {}
}

try {
    $isReplay = $Replay.IsPresent

    # ---- resolve transcript_path / session_id from params or stdin ----
    if ($TranscriptPath -and $SessionId) {
        $transcriptPath = $TranscriptPath
        $sessionId      = $SessionId
    } else {
        $payloadRaw = [Console]::In.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($payloadRaw)) {
            Write-ErrLog 'empty stdin payload'
            exit 0
        }
        $payload = $payloadRaw | ConvertFrom-Json
        $transcriptPath = $payload.transcript_path
        $sessionId      = $payload.session_id
    }
    if (-not $transcriptPath -or -not (Test-Path -LiteralPath $transcriptPath)) {
        Write-ErrLog "transcript not found: $transcriptPath"
        exit 0
    }

    # ---- pricing table (USD per 1M tokens) ----
    # Update when Anthropic prices change. Last verified: 2026-07-11.
    $pricing = @{
        'opus'   = @{ Input = 15.0; Output = 75.0; CacheWrite5m = 18.75; CacheWrite1h = 30.0; CacheRead = 1.50 }
        'sonnet' = @{ Input = 3.0;  Output = 15.0; CacheWrite5m = 3.75;  CacheWrite1h = 6.0;  CacheRead = 0.30 }
        'haiku'  = @{ Input = 1.0;  Output = 5.0;  CacheWrite5m = 1.25;  CacheWrite1h = 2.0;  CacheRead = 0.10 }
    }
    function Get-PricingFor($model) {
        if ($model -match 'opus')   { return $pricing['opus'] }
        if ($model -match 'sonnet') { return $pricing['sonnet'] }
        if ($model -match 'haiku')  { return $pricing['haiku'] }
        return $null
    }
    function Get-DisplayName($model) {
        if ($model -match 'opus-4-7')   { return 'Opus 4.7' }
        if ($model -match 'opus-4-6')   { return 'Opus 4.6' }
        if ($model -match 'opus-4-5')   { return 'Opus 4.5' }
        if ($model -match 'sonnet-4-6') { return 'Sonnet 4.6' }
        if ($model -match 'sonnet-4-5') { return 'Sonnet 4.5' }
        if ($model -match 'haiku-4-5')  { return 'Haiku 4.5' }
        return $model
    }
    function Get-Num($obj, $field) {
        if ($null -eq $obj) { return 0 }
        $v = $obj.$field
        if ($null -eq $v) { return 0 }
        return [int64]$v
    }

    # ---- parse transcript JSONL ----
    $seenMsgIds  = @{}
    $byModel     = @{}
    $toolCounts  = @{}
    $firstTs     = $null
    $lastTs      = $null
    $userTurns   = 0

    foreach ($line in Get-Content -LiteralPath $transcriptPath -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $entry = $line | ConvertFrom-Json } catch { continue }

        if ($entry.timestamp) {
            try {
                $ts = [DateTime]::Parse($entry.timestamp)
                if ($null -eq $firstTs -or $ts -lt $firstTs) { $firstTs = $ts }
                if ($null -eq $lastTs  -or $ts -gt $lastTs)  { $lastTs  = $ts }
            } catch {}
        }

        # count real user turns (skip tool_result-only entries)
        if ($entry.type -eq 'user' -and $entry.message -and $entry.message.role -eq 'user') {
            $hasText = $false
            foreach ($block in @($entry.message.content)) {
                if ($block -is [string]) { $hasText = $true; break }
                if ($block.type -eq 'text') { $hasText = $true; break }
            }
            if ($hasText) { $userTurns++ }
        }

        if ($entry.type -ne 'assistant') { continue }
        if (-not $entry.message) { continue }
        $msgId = $entry.message.id
        if (-not $msgId) { continue }
        if ($seenMsgIds.ContainsKey($msgId)) { continue }
        $seenMsgIds[$msgId] = $true

        # count tool uses
        foreach ($block in @($entry.message.content)) {
            if ($block.type -eq 'tool_use' -and $block.name) {
                $tn = [string]$block.name
                if (-not $toolCounts.ContainsKey($tn)) { $toolCounts[$tn] = 0 }
                $toolCounts[$tn] = $toolCounts[$tn] + 1
            }
        }

        $usage = $entry.message.usage
        $model = $entry.message.model
        if (-not $usage -or -not $model) { continue }

        if (-not $byModel.ContainsKey($model)) {
            $byModel[$model] = [ordered]@{
                cost                  = 0.0
                input_tokens          = 0
                cache_creation_tokens = 0
                cache_read_tokens     = 0
                output_tokens         = 0
                messages              = 0
            }
        }
        $byModel[$model].input_tokens          += (Get-Num $usage 'input_tokens')
        $byModel[$model].cache_creation_tokens += (Get-Num $usage 'cache_creation_input_tokens')
        $byModel[$model].cache_read_tokens     += (Get-Num $usage 'cache_read_input_tokens')
        $byModel[$model].output_tokens         += (Get-Num $usage 'output_tokens')
        $byModel[$model].messages              += 1
    }

    # nothing to log
    if ($seenMsgIds.Count -eq 0) {
        Write-ErrLog 'no assistant messages in transcript; skipping'
        exit 0
    }

    # ---- calculate cost per model ----
    $totalCost = 0.0
    foreach ($model in @($byModel.Keys)) {
        $price = Get-PricingFor $model
        $agg = $byModel[$model]
        if ($null -eq $price) {
            Write-ErrLog "no pricing for model: $model"
            continue
        }
        $cost = (
            ($agg.input_tokens          * $price.Input) +
            ($agg.cache_creation_tokens * $price.CacheWrite5m) +
            ($agg.cache_read_tokens     * $price.CacheRead) +
            ($agg.output_tokens         * $price.Output)
        ) / 1000000.0
        $byModel[$model].cost = [Math]::Round($cost, 4)
        $totalCost += $cost
    }
    $totalCostRounded = [Math]::Round($totalCost, 2)

    # ---- read session summary marker (optional, live sessions only) ----
    # Skip in replay mode: the marker belongs to the live session, not the
    # old session being replayed, so consuming it would mis-attribute the
    # summary and also lose it from the live SessionEnd.
    $summary = '(no summary)'
    if (-not $isReplay) {
        if (Test-Path -LiteralPath $summaryFile) {
            try {
                $raw = (Get-Content -LiteralPath $summaryFile -Raw -Encoding UTF8).Trim()
                if ($raw) { $summary = $raw }
                Remove-Item -LiteralPath $summaryFile -Force
            } catch {
                Write-ErrLog "summary read failed: $_"
            }
        }
    }

    # ---- duration ----
    $durationMin = 0
    if ($firstTs -and $lastTs) {
        $durationMin = [Math]::Round(($lastTs - $firstTs).TotalMinutes, 1)
    }

    # In replay mode use the actual session end date (from transcript),
    # not today, so cost-log dates match when each session ran.
    if ($isReplay -and $lastTs) {
        $date = $lastTs.ToString('yyyy-MM-dd')
    } else {
        $date = (Get-Date -Format 'yyyy-MM-dd')
    }
    $inv  = [System.Globalization.CultureInfo]::InvariantCulture

    # ---- build both output lines BEFORE writing anything ----
    $record = [ordered]@{
        date            = $date
        session_id      = $sessionId
        summary         = $summary
        duration_min    = $durationMin
        turns           = $userTurns
        cost_total      = $totalCostRounded
        models          = $byModel
        tool_use_counts = $toolCounts
    }
    $jsonlLine = ($record | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine

    $modelParts = @()
    foreach ($model in $byModel.Keys) {
        $display = Get-DisplayName $model
        $costStr = ([double]$byModel[$model].cost).ToString('F2', $inv)
        $modelParts += "${display}: `$${costStr}"
    }
    $modelSummary = ($modelParts -join ', ')
    $totalStr = ([double]$totalCostRounded).ToString('F2', $inv)
    $mdLine = "- ${date}: `$${totalStr} | ${summary} | ${modelSummary}" + [Environment]::NewLine

    # ---- write both files ----
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::AppendAllText($mdFile,    $mdLine,    $utf8NoBom)
    [System.IO.File]::AppendAllText($jsonlFile, $jsonlLine, $utf8NoBom)

    # ---- upload to ccsj-web (opt-in) ----
    # Local write already succeeded; upload failures must not break the hook.
    if ($env:CCSJ_UPLOAD_URL -and $env:CCSJ_UPLOAD_TOKEN) {
        try {
            $bodyBytes = $utf8NoBom.GetBytes($jsonlLine)
            Invoke-RestMethod -Uri $env:CCSJ_UPLOAD_URL -Method Post `
                -Body $bodyBytes -ContentType 'application/x-ndjson' `
                -Headers @{ Authorization = "Bearer $($env:CCSJ_UPLOAD_TOKEN)" } `
                -TimeoutSec 10 | Out-Null
        } catch {
            Write-ErrLog ('upload failed: {0}' -f $_.Exception.Message)
        }
    }

    exit 0
} catch {
    Write-ErrLog ('unhandled error: {0} at line {1}' -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber)
    exit 0
}
