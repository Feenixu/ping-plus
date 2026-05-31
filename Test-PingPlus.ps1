<#
  Test-PingPlus.ps1 — offline smoke test.

  Seeds a temporary log with synthetic pings (including a fake outage window),
  imports the module, builds a report from that temp log, and verifies the
  HTML came out. Does NOT touch your real logs and does NOT hit the network.

    pwsh -File C:\ping+\Test-PingPlus.ps1
#>
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
Import-Module (Join-Path $here 'PingPlus.psm1') -Force

# Build a synthetic log in a temp sandbox by pointing the module's root there.
$sandbox = Join-Path $env:TEMP ('pingplus-test-' + [guid]::NewGuid().ToString('N'))
$logDir  = Join-Path $sandbox 'logs'
$repDir  = Join-Path $sandbox 'reports'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

# Override the module's private root so report reads/writes go to the sandbox.
& (Get-Module PingPlus) { param($r) $script:PingPlusRoot = $r } $sandbox

$logFile = Join-Path $logDir 'ping-log.jsonl'
$base = Get-Date '2026-05-31T12:00:00'
$lines = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt 60; $i++) {
    $ts = $base.AddSeconds($i).ToString('o')
    # Simulate an outage between ping #20 and #27 inclusive.
    if ($i -ge 20 -and $i -le 27) {
        $rec = [ordered]@{ ts=$ts; target='demo.example'; ip=$null; status='timeout'; latency_ms=$null; sub_ms=$false; raw='Request timed out.' }
    } else {
        $lat = 12 + (Get-Random -Minimum 0 -Maximum 18)
        $rec = [ordered]@{ ts=$ts; target='demo.example'; ip='93.184.216.34'; status='ok'; latency_ms=$lat; sub_ms=$false; raw="Reply from 93.184.216.34: bytes=32 time=${lat}ms TTL=56" }
    }
    $lines.Add(($rec | ConvertTo-Json -Compress))
}
Set-Content -Path $logFile -Value $lines -Encoding utf8
Write-Host "Seeded $($lines.Count) synthetic records -> $logFile"

Show-PingReport -NoOpen

$report = Join-Path $repDir 'report.html'
if (Test-Path $report) {
    $size = (Get-Item $report).Length
    Write-Host "PASS: report generated ($size bytes): $report" -ForegroundColor Green
    Write-Host "Open it to eyeball the synthetic outage (rows 20-27):" -ForegroundColor Cyan
    Write-Host "  Start-Process '$report'"
} else {
    Write-Error "FAIL: report was not created at $report"
}

Write-Host ""
Write-Host "Quick stats from the synthetic data:" -ForegroundColor Cyan
Get-PingStats | Format-Table -AutoSize

Write-Host ""
Write-Host "Sandbox: $sandbox  (delete when done: Remove-Item -Recurse -Force '$sandbox')" -ForegroundColor DarkGray
