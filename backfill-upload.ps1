# backfill-upload.ps1
# One-shot uploader for existing cost-log.jsonl entries into ccsj-web.
#
# Run this once after registering a machine on ccsj-web, so historical
# sessions land in the dashboard. Duplicate rows are dropped server-side
# by (machine_id, session_id_ext), so re-running is safe.
#
# Configuration (env vars, same as the SessionEnd hook):
#   CCSJ_UPLOAD_URL    - ingest endpoint (required)
#   CCSJ_UPLOAD_TOKEN  - machine token (required)
#   CCSJ_OUTPUT_DIR    - where cost-log.jsonl lives
#                        default: %USERPROFILE%\.claude-code-session-journal
#
# Usage:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File backfill-upload.ps1
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File backfill-upload.ps1 -JsonlPath D:\logs\cost-log.jsonl

param(
    [string]$JsonlPath
)

$ErrorActionPreference = 'Stop'

if (-not $env:CCSJ_UPLOAD_URL -or -not $env:CCSJ_UPLOAD_TOKEN) {
    Write-Error 'CCSJ_UPLOAD_URL and CCSJ_UPLOAD_TOKEN must both be set.'
    exit 1
}

if (-not $JsonlPath) {
    if ($env:CCSJ_OUTPUT_DIR) {
        $JsonlPath = Join-Path $env:CCSJ_OUTPUT_DIR 'cost-log.jsonl'
    } else {
        $JsonlPath = Join-Path $env:USERPROFILE '.claude-code-session-journal\cost-log.jsonl'
    }
}

if (-not (Test-Path -LiteralPath $JsonlPath)) {
    Write-Error "jsonl not found: $JsonlPath"
    exit 1
}

$lines = @(Get-Content -LiteralPath $JsonlPath -Encoding UTF8 |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

if ($lines.Count -eq 0) {
    Write-Host 'nothing to upload.'
    exit 0
}

Write-Host ("uploading {0} lines from {1} ..." -f $lines.Count, $JsonlPath)

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$body = ($lines -join "`n") + "`n"
$bytes = $utf8NoBom.GetBytes($body)

try {
    $resp = Invoke-RestMethod -Uri $env:CCSJ_UPLOAD_URL -Method Post `
        -Body $bytes -ContentType 'application/x-ndjson' `
        -Headers @{ Authorization = "Bearer $($env:CCSJ_UPLOAD_TOKEN)" } `
        -TimeoutSec 60
    Write-Host ("done. inserted={0} skipped={1} total={2}" -f $resp.inserted, $resp.skipped, $resp.total)
} catch {
    Write-Error ('upload failed: {0}' -f $_.Exception.Message)
    exit 1
}
