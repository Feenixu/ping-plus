<#
  Test-PingPlus.ps1 - offline smoke + unit tests.

  1. ASCII/BOM guard over all PowerShell SOURCE files.
  2. Unit tests for the risky paths: line parser, config validation,
     log retention, and report math (percentiles, outage grouping).
  3. End-to-end smoke: seed a synthetic log, build a report, verify it.

  Everything runs in a temp sandbox; it does NOT touch your real logs and does
  NOT hit the network. Exits non-zero if any check fails.

    pwsh -File C:\ping+\Test-PingPlus.ps1
#>
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

# ---------------------------------------------------------------------------
# 1. ASCII guard: every PowerShell SOURCE file must be pure ASCII with no BOM
#    (see CLAUDE.md). config.psd1 is excluded: it is user-editable runtime data
#    (not a source file), users may legitimately type non-ASCII in its comments,
#    and PS 5.1 writes it with a BOM - scanning it here would wrongly fail the
#    build on a normal install.
# ---------------------------------------------------------------------------
foreach ($srcFile in Get-ChildItem -LiteralPath $here -File |
        Where-Object { $_.Extension -in '.ps1','.psd1','.psm1' -and $_.Name -ne 'config.psd1' }) {
    $srcBytes = [System.IO.File]::ReadAllBytes($srcFile.FullName)
    $nonAscii = 0
    foreach ($b in $srcBytes) { if ($b -gt 127) { $nonAscii++ } }
    if ($nonAscii -gt 0) {
        throw "$($srcFile.Name) contains $nonAscii non-ASCII byte(s); PowerShell sources must be pure ASCII (see CLAUDE.md)."
    }
}
Write-Host "ASCII check passed for all PowerShell sources." -ForegroundColor Green

Import-Module (Join-Path $here 'PingPlus.psd1') -Force
$mod = Get-Module PingPlus

# Point the module's private root at a throwaway sandbox so all reads/writes
# (log, config, reports) stay out of the real install.
$sandbox = Join-Path $env:TEMP ('pingplus-test-' + [guid]::NewGuid().ToString('N'))
$logDir  = Join-Path $sandbox 'logs'
$repDir  = Join-Path $sandbox 'reports'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
& $mod { param($r) $script:PingPlusRoot = $r } $sandbox
$logFile = Join-Path $logDir 'ping-log.jsonl'

# ---------------------------------------------------------------------------
# Tiny assertion harness
# ---------------------------------------------------------------------------
$script:pass = 0; $script:fail = 0
function Check {
    param([string] $Name, [bool] $Cond, [string] $Detail = '')
    if ($Cond) { $script:pass++; Write-Host "  PASS: $Name" -ForegroundColor DarkGreen }
    else       { $script:fail++; Write-Host "  FAIL: $Name  $Detail" -ForegroundColor Red }
}

# Seed the sandbox log with an array of record hashtables (fresh each call).
function Seed-Log {
    param([object[]] $Records)
    $lines = $Records | ForEach-Object { $_ | ConvertTo-Json -Compress }
    [System.IO.File]::WriteAllLines($logFile, [string[]]$lines)
}
# Build $Count records for one run id, starting at $Base, one second apart.
function New-RunRecs {
    param([string] $Run, [datetime] $Base, [int] $Count, [string] $Status = 'ok')
    0..($Count - 1) | ForEach-Object {
        @{
            ts = $Base.AddSeconds($_).ToString('o'); run = $Run; target = 'demo.example'
            ip = '1.1.1.1'; status = $Status
            latency_ms = $(if ($Status -eq 'ok') { 10 } else { $null }); sub_ms = $false; raw = 'x'
        }
    }
}
# Distinct run ids present in the sandbox log right now.
function Get-LogRuns {
    [System.IO.File]::ReadAllLines($logFile) |
        Where-Object { $_.Trim() } |
        ForEach-Object { ($_ | ConvertFrom-Json).run } | Sort-Object -Unique
}

# ---------------------------------------------------------------------------
# 2a. Line parser (ConvertFrom-PingLine)
# ---------------------------------------------------------------------------
Write-Host "`nParser:" -ForegroundColor Cyan
function Parse-Line {
    param([string] $Line, [string] $PreTarget = 'cmdline')
    & $mod {
        param($l, $pt)
        $st = [pscustomobject]@{ target = $pt; ip = $null }
        $r  = ConvertFrom-PingLine -Line $l -State $st -RunId 'r1' -Ts '2026-01-01T00:00:00.0000000+00:00'
        [pscustomobject]@{ rec = $r; state = $st }
    } $Line $PreTarget
}

$r = Parse-Line 'Reply from 142.250.80.46: bytes=32 time=14ms TTL=117'
Check 'IPv4 reply -> ok'          ($r.rec.status -eq 'ok')
Check 'IPv4 reply latency = 14'   ($r.rec.latency_ms -eq 14)
Check 'IPv4 reply ip captured'    ($r.rec.ip -eq '142.250.80.46') "(got '$($r.rec.ip)')"

$r = Parse-Line 'Reply from ::1: time<1ms'
Check 'IPv6 ::1 reply -> ok'      ($r.rec.status -eq 'ok') '(was dropped before the regex fix)'
Check 'IPv6 ::1 sub-ms latency 1' ($r.rec.latency_ms -eq 1 -and $r.rec.sub_ms)
Check 'IPv6 ::1 ip not truncated' ($r.rec.ip -eq '::1') "(got '$($r.rec.ip)')"

$r = Parse-Line 'Reply from 2607:f8b0:4009:805::200e: time=13ms'
Check 'Full IPv6 source intact'   ($r.rec.ip -eq '2607:f8b0:4009:805::200e') "(got '$($r.rec.ip)')"

$r = Parse-Line 'Reply from 192.168.1.254: Destination port unreachable.'
Check 'Port unreachable -> loss'  ($r.rec.status -eq 'unreachable') '(was silently unlogged)'

$r = Parse-Line 'Reply from 192.168.1.1: Destination host unreachable.'
Check 'Host unreachable -> loss'  ($r.rec.status -eq 'unreachable')

$r = Parse-Line 'Request timed out.'
Check 'Timeout -> timeout'        ($r.rec.status -eq 'timeout')

$r = Parse-Line 'Ping request could not find host badhost.invalid. Please check the name and try again.'
Check 'DNS error -> dns_error'    ($r.rec.status -eq 'dns_error')
Check 'DNS error recovers target' ($r.rec.target -eq 'badhost.invalid') "(got '$($r.rec.target)')"

$r = Parse-Line 'General failure.'
Check 'General failure -> error'  ($r.rec.status -eq 'error')

$r = Parse-Line 'Pinging google.com [142.250.80.46] with 32 bytes of data:'
Check 'Header sets target'        ($r.state.target -eq 'google.com')
Check 'Header sets ip'            ($r.state.ip -eq '142.250.80.46')
Check 'Header line is not logged' ($null -eq $r.rec)

# ---------------------------------------------------------------------------
# 2b. Config validation (bad values must fall back, never throw / never wipe)
# ---------------------------------------------------------------------------
Write-Host "`nConfig validation:" -ForegroundColor Cyan
$badCfg = "@{ RetentionMode='bogus'; KeepRuns='fifty'; KeepDays='soon'; ApplyOn='whenever'; KeepReports='lots' }"
Set-Content -Path (Join-Path $sandbox 'config.psd1') -Value $badCfg -Encoding ascii
$threw = $false
try { $c = Get-PingPlusConfig } catch { $threw = $true }
Check 'Bad config does not throw'      (-not $threw)
Check 'Bad RetentionMode -> both'      ($c.RetentionMode -eq 'both')
Check 'Bad KeepRuns -> default 50'     ($c.KeepRuns -eq 50)     "(got '$($c.KeepRuns)')"
Check 'Bad KeepDays -> default 30'     ($c.KeepDays -eq 30)     "(got '$($c.KeepDays)')"
Check 'Bad ApplyOn -> finish'          ($c.ApplyOn -eq 'finish')
Check 'Bad KeepReports -> default 10'  ($c.KeepReports -eq 10)  "(got '$($c.KeepReports)')"
Remove-Item (Join-Path $sandbox 'config.psd1') -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# 2c. Retention (highest stakes: bad logic can wipe history)
# ---------------------------------------------------------------------------
Write-Host "`nRetention:" -ForegroundColor Cyan
$cfg = { param($mode, $runs, $days) [pscustomobject]@{ RetentionMode = $mode; KeepRuns = $runs; KeepDays = $days; ApplyOn = 'finish'; KeepReports = 10 } }

$base = Get-Date '2026-01-01T12:00:00'
$threeRuns = @()
$threeRuns += New-RunRecs 'A' $base 5
$threeRuns += New-RunRecs 'B' $base.AddMinutes(10) 5
$threeRuns += New-RunRecs 'C' $base.AddMinutes(20) 5

Seed-Log $threeRuns
Invoke-PingRetention -Config (& $cfg 'runs' 2 0)
$runs = @(Get-LogRuns)
Check 'runs/KeepRuns=2 keeps 2 newest' (($runs -join ',') -eq 'B,C') "(kept '$($runs -join ',')')"

Seed-Log $threeRuns
Invoke-PingRetention -Config (& $cfg 'runs' 0 0)
Check 'KeepRuns=0 = no limit (keep all)' ((@(Get-LogRuns)).Count -eq 3)

Seed-Log $threeRuns
Invoke-PingRetention -Config (& $cfg 'none' 1 1)
Check "mode 'none' never deletes"        ((@(Get-LogRuns)).Count -eq 3)

# In-progress run must survive even when it's the OLDEST and KeepRuns=1.
Seed-Log $threeRuns
Invoke-PingRetention -Config (& $cfg 'runs' 1 0) -ActiveRun 'A'
$runs = @(Get-LogRuns)
Check 'Active run protected from prune'   (($runs -contains 'A') -and ($runs -contains 'C')) "(kept '$($runs -join ',')')"

# Age-based: recent run kept, 40-day-old run dropped.
$recent = New-RunRecs 'recent' ((Get-Date).AddDays(-1)) 3
$old    = New-RunRecs 'old'    ((Get-Date).AddDays(-40)) 3
Seed-Log (@($recent) + @($old))
Invoke-PingRetention -Config (& $cfg 'days' 0 30)
$runs = @(Get-LogRuns)
Check "days: old dropped, recent kept"    (($runs -join ',') -eq 'recent') "(kept '$($runs -join ',')')"

# both vs either on the same seed (KeepRuns=1, no age limit):
$twoRuns = @(New-RunRecs 'old' $base 3) + @(New-RunRecs 'new' $base.AddMinutes(10) 3)
Seed-Log $twoRuns
Invoke-PingRetention -Config (& $cfg 'both' 1 0)
Check "'both' (KeepRuns=1) keeps newest"  ((@(Get-LogRuns) -join ',') -eq 'new')
Seed-Log $twoRuns
Invoke-PingRetention -Config (& $cfg 'either' 1 0)
Check "'either' (no age cutoff) keeps all" ((@(Get-LogRuns)).Count -eq 2)

# ---------------------------------------------------------------------------
# 2d. Report math (percentiles + outage grouping across run boundaries)
# ---------------------------------------------------------------------------
Write-Host "`nReport math:" -ForegroundColor Cyan
$pct = & $mod {
    [pscustomobject]@{
        p50 = (Get-PingPercentile ([double[]](1..10)) 50)
        p95 = (Get-PingPercentile ([double[]](1..10)) 95)
        one = (Get-PingPercentile ([double[]](7)) 50)
    }
}
Check 'p50 of 1..10 = 5.5'   ([math]::Abs($pct.p50 - 5.5) -lt 1e-9)  "(got $($pct.p50))"
Check 'p95 of 1..10 = 9.55'  ([math]::Abs($pct.p95 - 9.55) -lt 1e-9) "(got $($pct.p95))"
Check 'percentile of single value' ($pct.one -eq 7)

function Rec { param($ts, $status, $run) [pscustomobject]@{ ts = "2026-01-01T$ts.0000000+00:00"; status = $status; run = $run } }
$within = @( (Rec '12:00:00' 'ok' 'A'), (Rec '12:00:01' 'timeout' 'A'), (Rec '12:00:02' 'timeout' 'A'), (Rec '12:00:03' 'ok' 'A') )
$o = @(& $mod { param($r) Get-PingOutages $r } (,$within))
Check 'One in-run outage found'       ($o.Count -eq 1)
Check 'Outage spans 2 failed pings'   ($o[0].count -eq 2)

$boundary = @( (Rec '12:00:00' 'ok' 'A'), (Rec '12:00:01' 'timeout' 'A'), (Rec '14:00:00' 'timeout' 'B'), (Rec '14:00:01' 'ok' 'B') )
$o = @(& $mod { param($r) Get-PingOutages $r } (,$boundary))
Check 'Outages split at run boundary' ($o.Count -eq 2) '(cross-session merge would give 1)'

# ---------------------------------------------------------------------------
# 3. End-to-end smoke: seed 60 records (deterministic) with a fake outage,
#    build the report, verify it and the stats.
# ---------------------------------------------------------------------------
Write-Host "`nEnd-to-end report:" -ForegroundColor Cyan
$smoke = New-Object System.Collections.Generic.List[object]
$sBase = Get-Date '2026-05-31T12:00:00'
for ($i = 0; $i -lt 60; $i++) {
    $ts = $sBase.AddSeconds($i).ToString('o')
    if ($i -ge 20 -and $i -le 27) {
        $smoke.Add(@{ ts=$ts; run='smoke1'; target='demo.example'; ip=$null; status='timeout'; latency_ms=$null; sub_ms=$false; raw='Request timed out.' })
    } else {
        $lat = 12 + ($i % 18)   # deterministic (was Get-Random)
        $smoke.Add(@{ ts=$ts; run='smoke1'; target='demo.example'; ip='93.184.216.34'; status='ok'; latency_ms=$lat; sub_ms=$false; raw="Reply from 93.184.216.34: bytes=32 time=${lat}ms TTL=56" })
    }
}
Seed-Log $smoke

Show-PingReport -NoOpen | Out-Null
$report = Join-Path $repDir 'report.html'
Check 'Report generated' (Test-Path $report)
if (Test-Path $report) { Check 'Report is non-empty' ((Get-Item $report).Length -gt 500) }

$stats = @(Get-PingStats)
Check 'Stats: 8 drops'      ($stats[0].Dropped -eq 8)     "(got $($stats[0].Dropped))"
Check 'Stats: 52 ok'        ($stats[0].OK -eq 52)         "(got $($stats[0].OK))"
Check 'Stats: loss ~13.33%' ([math]::Abs($stats[0].'Loss%' - 13.33) -lt 0.01) "(got $($stats[0].'Loss%'))"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
$color = if ($script:fail -eq 0) { 'Green' } else { 'Red' }
Write-Host "$($script:pass) passed, $($script:fail) failed." -ForegroundColor $color
Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
if ($script:fail -gt 0) { exit 1 }
Write-Host "All checks passed." -ForegroundColor Green
