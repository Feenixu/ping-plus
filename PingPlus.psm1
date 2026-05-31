# ============================================================================
#  ping+  (PingPlus.psm1)
#  A non-destructive wrapper around Windows' built-in ping.exe that:
#    * passes every argument straight through to the real ping
#    * streams ping's output live to your console (so it feels normal)
#    * timestamps & logs every single reply / timeout / error to a JSONL file
#    * can render a self-contained local HTML report (latency graph,
#      availability strip, and "between these timestamps all pings failed"
#      outage windows) with ZERO external dependencies (pure inline SVG).
#
#  The real C:\Windows\System32\PING.EXE is never touched or overwritten.
# ============================================================================

# Root folder = the directory this module lives in.
$script:PingPlusRoot = $PSScriptRoot
if (-not $script:PingPlusRoot) { $script:PingPlusRoot = 'C:\ping+' }

function Get-PingPlusPaths {
    $root    = $script:PingPlusRoot
    $logDir  = Join-Path $root 'logs'
    $repDir  = Join-Path $root 'reports'
    [pscustomobject]@{
        Root      = $root
        LogDir    = $logDir
        ReportDir = $repDir
        LogFile   = Join-Path $logDir 'ping-log.jsonl'
    }
}

# ----------------------------------------------------------------------------
#  Invoke-PingPlus  —  the wrapper. Call it directly, or via the `ping` /
#  `ping+` / `pingplus` aliases (see PingPlus.psm1 export + Install.ps1).
# ----------------------------------------------------------------------------
function Invoke-PingPlus {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]] $PingArgs
    )

    $paths = Get-PingPlusPaths
    if (-not (Test-Path $paths.LogDir)) {
        New-Item -ItemType Directory -Path $paths.LogDir -Force | Out-Null
    }
    $logFile = $paths.LogFile

    # Always call the REAL ping by absolute path so we never recurse into our
    # own `ping` function.
    $pingExe = Join-Path $env:SystemRoot 'System32\PING.EXE'
    if (-not (Test-Path $pingExe)) { $pingExe = 'ping.exe' }

    # No args -> just show ping's normal usage text, log nothing.
    if (-not $PingArgs -or $PingArgs.Count -eq 0) {
        & $pingExe
        return
    }

    # Best-effort target = last token that isn't a -flag / /flag.
    $target = ($PingArgs | Where-Object { $_ -notmatch '^[-/]' } | Select-Object -Last 1)
    if (-not $target) { $target = 'unknown' }
    $ip = $null

    # Stream ping line-by-line. Because we append per line, Ctrl+C on a
    # continuous (`-t`) ping still leaves a complete log.
    & $pingExe @PingArgs 2>&1 | ForEach-Object {
        $line   = [string]$_
        $ts     = (Get-Date).ToString('o')   # ISO-8601 round-trip
        $status = $null
        $lat    = $null
        $subms  = $false

        if ($line -match 'Pinging\s+(?<host>\S+)\s+\[(?<ip>[^\]]+)\]') {
            $target = $Matches['host']; $ip = $Matches['ip']
        }
        elseif ($line -match 'Pinging\s+(?<host>\S+)\s+with') {
            $target = $Matches['host']; if (-not $ip) { $ip = $Matches['host'] }
        }
        elseif ($line -match 'Request timed out')                       { $status = 'timeout' }
        elseif ($line -match 'Destination (host|net) unreachable')      { $status = 'unreachable' }
        elseif ($line -match 'could not find host|could not find')      { $status = 'dns_error' }
        elseif ($line -match 'General failure|transmit failed|TTL expired') { $status = 'error' }
        elseif ($line -match 'Reply from (?<rip>[^:]+):.*time(?<op>[=<])(?<t>\d+)\s*ms') {
            $status = 'ok'
            $lat    = [int]$Matches['t']
            if ($Matches['op'] -eq '<') { $subms = $true }
            if (-not $ip) { $ip = ($Matches['rip']).Trim() }
        }

        # Echo to console, colouring drops red so live runs are readable.
        if ($status -in 'timeout', 'unreachable', 'dns_error', 'error') {
            Write-Host $line -ForegroundColor Red
        }
        else {
            Write-Host $line
        }

        # Only persist meaningful events (replies / drops), not banner/blank lines.
        if ($status) {
            $rec = [ordered]@{
                ts         = $ts
                target     = $target
                ip         = $ip
                status     = $status
                latency_ms = $lat
                sub_ms     = $subms
                raw        = $line.Trim()
            }
            ($rec | ConvertTo-Json -Compress) | Add-Content -Path $logFile -Encoding utf8
        }
    }
}

# ----------------------------------------------------------------------------
#  Internal helpers for the report
# ----------------------------------------------------------------------------
function ConvertTo-PingTime {
    param([string] $s)
    try {
        return [datetime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind)
    } catch {
        try { return [datetime]$s } catch { return $null }
    }
}

function Format-PingSpan {
    param([TimeSpan] $ts)
    if ($ts.TotalSeconds -lt 1)  { return ('{0} ms' -f [int]$ts.TotalMilliseconds) }
    if ($ts.TotalMinutes -lt 1)  { return ('{0:n1} s' -f $ts.TotalSeconds) }
    if ($ts.TotalHours   -lt 1)  { return ('{0}m {1}s' -f $ts.Minutes, $ts.Seconds) }
    return ('{0}h {1}m {2}s' -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds)
}

function Get-PingPercentile {
    param([double[]] $values, [double] $p)
    if (-not $values -or $values.Count -eq 0) { return $null }
    $sorted = $values | Sort-Object
    if ($sorted.Count -eq 1) { return $sorted[0] }
    $rank = ($p / 100.0) * ($sorted.Count - 1)
    $lo = [math]::Floor($rank); $hi = [math]::Ceiling($rank)
    if ($lo -eq $hi) { return $sorted[[int]$rank] }
    $frac = $rank - $lo
    return $sorted[[int]$lo] + ($sorted[[int]$hi] - $sorted[[int]$lo]) * $frac
}

function ConvertTo-HtmlText {
    param([string] $s)
    if ($null -eq $s) { return '' }
    return $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

# Build an inline SVG latency line chart (no external deps).
function New-PingLatencySvg {
    param([object[]] $records)

    $w = 900; $h = 240; $padL = 48; $padR = 16; $padT = 16; $padB = 28
    $plotW = $w - $padL - $padR
    $plotH = $h - $padT - $padB

    $points = foreach ($r in $records) {
        $t = ConvertTo-PingTime $r.ts
        if ($null -eq $t) { continue }
        [pscustomobject]@{ t = $t; ok = ($r.status -eq 'ok'); lat = $r.latency_ms }
    }
    $points = $points | Sort-Object t
    if (-not $points -or $points.Count -eq 0) { return '<p class="muted">No data to plot.</p>' }

    $tMin = ($points[0]).t
    $tMax = ($points[-1]).t
    $spanTicks = ($tMax - $tMin).Ticks
    if ($spanTicks -le 0) { $spanTicks = 1 }

    $oks = $points | Where-Object { $_.ok -and $null -ne $_.lat }
    $latMax = 10
    if ($oks) { $latMax = [math]::Max(10, (($oks | Measure-Object lat -Maximum).Maximum)) }
    $latMax = [math]::Ceiling($latMax * 1.1)

    $xOf = { param($t) $padL + ($plotW * (($t - $tMin).Ticks / $spanTicks)) }
    $yOf = { param($v) $padT + ($plotH * (1 - ([math]::Min($v, $latMax) / $latMax))) }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("<svg viewBox='0 0 $w $h' class='chart' xmlns='http://www.w3.org/2000/svg'>")
    # axes / gridlines
    [void]$sb.Append("<rect x='$padL' y='$padT' width='$plotW' height='$plotH' fill='#0d1117' stroke='#30363d'/>")
    foreach ($g in 0, 0.25, 0.5, 0.75, 1) {
        $gy = $padT + ($plotH * $g)
        $val = [int]([math]::Round($latMax * (1 - $g)))
        [void]$sb.Append("<line x1='$padL' y1='$gy' x2='$($padL+$plotW)' y2='$gy' stroke='#21262d'/>")
        [void]$sb.Append("<text x='$($padL-6)' y='$($gy+4)' fill='#8b949e' font-size='10' text-anchor='end'>$val</text>")
    }
    [void]$sb.Append("<text x='$padL' y='$($h-8)' fill='#8b949e' font-size='10'>$($tMin.ToString('yyyy-MM-dd HH:mm:ss'))</text>")
    [void]$sb.Append("<text x='$($padL+$plotW)' y='$($h-8)' fill='#8b949e' font-size='10' text-anchor='end'>$($tMax.ToString('yyyy-MM-dd HH:mm:ss'))</text>")

    # latency polyline (only over ok points)
    $poly = New-Object System.Collections.Generic.List[string]
    foreach ($p in $points) {
        if ($p.ok -and $null -ne $p.lat) {
            $x = [math]::Round((& $xOf $p.t), 1)
            $y = [math]::Round((& $yOf $p.lat), 1)
            $poly.Add("$x,$y")
        }
    }
    if ($poly.Count -ge 2) {
        [void]$sb.Append("<polyline fill='none' stroke='#58a6ff' stroke-width='1.5' points='$($poly -join ' ')'/>")
    }
    foreach ($pt in $poly) {
        $xy = $pt -split ','
        [void]$sb.Append("<circle cx='$($xy[0])' cy='$($xy[1])' r='1.6' fill='#58a6ff'/>")
    }

    # drop markers (red ticks at bottom)
    foreach ($p in $points) {
        if (-not $p.ok) {
            $x = [math]::Round((& $xOf $p.t), 1)
            [void]$sb.Append("<line x1='$x' y1='$($padT+$plotH)' x2='$x' y2='$($padT+$plotH-12)' stroke='#f85149' stroke-width='2'/>")
        }
    }
    [void]$sb.Append('</svg>')
    return $sb.ToString()
}

# Build an inline SVG availability strip (green=ok, red=drop) in time order.
function New-PingStripSvg {
    param([object[]] $records)
    $ordered = $records | Sort-Object { ConvertTo-PingTime $_.ts }
    $n = $ordered.Count
    if ($n -eq 0) { return '' }
    $w = 900; $h = 26
    $bw = [math]::Max(($w / $n), 0.5)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("<svg viewBox='0 0 $w $h' class='strip' xmlns='http://www.w3.org/2000/svg'>")
    [void]$sb.Append("<rect x='0' y='0' width='$w' height='$h' fill='#0d1117'/>")
    for ($i = 0; $i -lt $n; $i++) {
        $x = [math]::Round($i * $bw, 2)
        $col = if ($ordered[$i].status -eq 'ok') { '#2ea043' } else { '#f85149' }
        [void]$sb.Append("<rect x='$x' y='0' width='$([math]::Ceiling($bw))' height='$h' fill='$col'/>")
    }
    [void]$sb.Append('</svg>')
    return $sb.ToString()
}

# Find maximal runs of consecutive non-ok pings -> outage windows.
function Get-PingOutages {
    param([object[]] $records)
    $ordered = $records | Sort-Object { ConvertTo-PingTime $_.ts }
    $outages = New-Object System.Collections.Generic.List[object]
    $cur = $null
    foreach ($r in $ordered) {
        if ($r.status -ne 'ok') {
            if ($null -eq $cur) {
                $cur = [pscustomobject]@{ start = (ConvertTo-PingTime $r.ts); end = (ConvertTo-PingTime $r.ts); count = 1; kinds = @{} }
            } else {
                $cur.end = (ConvertTo-PingTime $r.ts); $cur.count++
            }
            $cur.kinds[$r.status] = ([int]$cur.kinds[$r.status]) + 1
        } else {
            if ($null -ne $cur) { $outages.Add($cur); $cur = $null }
        }
    }
    if ($null -ne $cur) { $outages.Add($cur) }
    return $outages
}

# ----------------------------------------------------------------------------
#  Show-PingReport  —  render + open the HTML report.
# ----------------------------------------------------------------------------
function Show-PingReport {
    [CmdletBinding()]
    param(
        [string] $Target,          # filter to one host
        [int]    $Last = 0,        # 0 = all records
        [switch] $NoOpen           # don't auto-open the browser
    )

    $paths = Get-PingPlusPaths
    if (-not (Test-Path $paths.LogFile)) {
        Write-Warning "No log yet at $($paths.LogFile). Run some pings first (e.g. 'ping google.com')."
        return
    }
    if (-not (Test-Path $paths.ReportDir)) {
        New-Item -ItemType Directory -Path $paths.ReportDir -Force | Out-Null
    }

    $records = Get-Content -Path $paths.LogFile -Encoding utf8 |
        Where-Object { $_.Trim() } |
        ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } |
        Where-Object { $_ }

    if ($Target) { $records = $records | Where-Object { $_.target -eq $Target } }
    if ($Last -gt 0) { $records = $records | Select-Object -Last $Last }
    if (-not $records) { Write-Warning 'No matching records.'; return }

    $generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $groups = $records | Group-Object target

    $css = @'
<style>
 :root{color-scheme:dark}
 body{font-family:Segoe UI,system-ui,Arial,sans-serif;background:#010409;color:#c9d1d9;margin:0;padding:24px}
 h1{font-size:20px;margin:0 0 4px}
 h2{font-size:16px;margin:28px 0 6px;border-bottom:1px solid #30363d;padding-bottom:6px}
 .muted{color:#8b949e;font-size:12px}
 .cards{display:flex;flex-wrap:wrap;gap:10px;margin:10px 0}
 .card{background:#0d1117;border:1px solid #30363d;border-radius:8px;padding:10px 14px;min-width:110px}
 .card .v{font-size:20px;font-weight:600}
 .card .k{font-size:11px;color:#8b949e;text-transform:uppercase;letter-spacing:.04em}
 .bad .v{color:#f85149}.good .v{color:#2ea043}
 table{border-collapse:collapse;width:100%;font-size:13px;margin-top:6px}
 th,td{border:1px solid #30363d;padding:5px 8px;text-align:left}
 th{background:#161b22}
 .chart,.strip{width:100%;height:auto;background:#0d1117;border:1px solid #30363d;border-radius:8px;margin:6px 0}
 .legend{font-size:11px;color:#8b949e;margin:4px 0 0}
 .legend span{display:inline-block;width:10px;height:10px;border-radius:2px;margin:0 4px 0 12px;vertical-align:middle}
</style>
'@

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("<!doctype html><html><head><meta charset='utf-8'><title>ping+ report</title>$css</head><body>")
    [void]$sb.Append("<h1>ping+ report</h1><div class='muted'>Generated $generated &middot; source: $(ConvertTo-HtmlText $paths.LogFile)</div>")

    foreach ($g in $groups) {
        $recs  = $g.Group
        $total = $recs.Count
        $oks   = @($recs | Where-Object { $_.status -eq 'ok' })
        $okN   = $oks.Count
        $drops = $total - $okN
        $rate  = if ($total) { [math]::Round(100.0 * $drops / $total, 2) } else { 0 }

        $lat = @($oks | Where-Object { $null -ne $_.latency_ms } | ForEach-Object { [double]$_.latency_ms })
        $lMin = if ($lat) { [int]($lat | Measure-Object -Minimum).Minimum } else { '-' }
        $lMax = if ($lat) { [int]($lat | Measure-Object -Maximum).Maximum } else { '-' }
        $lAvg = if ($lat) { [math]::Round(($lat | Measure-Object -Average).Average, 1) } else { '-' }
        $lP50 = if ($lat) { [math]::Round((Get-PingPercentile $lat 50), 1) } else { '-' }
        $lP95 = if ($lat) { [math]::Round((Get-PingPercentile $lat 95), 1) } else { '-' }

        $outages = Get-PingOutages $recs
        $tFirst  = ConvertTo-PingTime ($recs | Sort-Object { ConvertTo-PingTime $_.ts } | Select-Object -First 1).ts
        $tLast   = ConvertTo-PingTime ($recs | Sort-Object { ConvertTo-PingTime $_.ts } | Select-Object -Last 1).ts

        $rateCls = if ($rate -eq 0) { 'good' } else { 'bad' }

        [void]$sb.Append("<h2>$(ConvertTo-HtmlText $g.Name)</h2>")
        [void]$sb.Append("<div class='muted'>$($tFirst.ToString('yyyy-MM-dd HH:mm:ss')) &rarr; $($tLast.ToString('yyyy-MM-dd HH:mm:ss'))</div>")
        [void]$sb.Append("<div class='cards'>")
        [void]$sb.Append("<div class='card'><div class='v'>$total</div><div class='k'>Pings</div></div>")
        [void]$sb.Append("<div class='card good'><div class='v'>$okN</div><div class='k'>OK</div></div>")
        [void]$sb.Append("<div class='card bad'><div class='v'>$drops</div><div class='k'>Dropped</div></div>")
        [void]$sb.Append("<div class='card $rateCls'><div class='v'>$rate%</div><div class='k'>Loss</div></div>")
        [void]$sb.Append("<div class='card'><div class='v'>$lAvg</div><div class='k'>Avg ms</div></div>")
        [void]$sb.Append("<div class='card'><div class='v'>$lMin/$lMax</div><div class='k'>Min/Max ms</div></div>")
        [void]$sb.Append("<div class='card'><div class='v'>$lP50/$lP95</div><div class='k'>p50/p95 ms</div></div>")
        [void]$sb.Append("<div class='card $((if($outages.Count){'bad'}else{'good'}))'><div class='v'>$($outages.Count)</div><div class='k'>Outages</div></div>")
        [void]$sb.Append("</div>")

        [void]$sb.Append((New-PingLatencySvg $recs))
        [void]$sb.Append("<div class='legend'><span style='background:#58a6ff'></span>latency (ms)<span style='background:#f85149'></span>drop</div>")
        [void]$sb.Append((New-PingStripSvg $recs))
        [void]$sb.Append("<div class='legend'><span style='background:#2ea043'></span>reply<span style='background:#f85149'></span>drop &middot; left&rarr;right = oldest&rarr;newest</div>")

        if ($outages.Count) {
            [void]$sb.Append("<table><tr><th>#</th><th>From</th><th>To</th><th>Duration</th><th>Failed pings</th><th>Type</th></tr>")
            $i = 1
            foreach ($o in $outages) {
                $dur = Format-PingSpan ($o.end - $o.start)
                $kinds = ($o.kinds.GetEnumerator() | ForEach-Object { "$($_.Key) x$($_.Value)" }) -join ', '
                [void]$sb.Append("<tr><td>$i</td><td>$($o.start.ToString('yyyy-MM-dd HH:mm:ss'))</td><td>$($o.end.ToString('yyyy-MM-dd HH:mm:ss'))</td><td>$dur</td><td>$($o.count)</td><td>$(ConvertTo-HtmlText $kinds)</td></tr>")
                $i++
            }
            [void]$sb.Append("</table>")
        } else {
            [void]$sb.Append("<p class='muted'>No outages recorded for this host. \o/</p>")
        }
    }

    [void]$sb.Append("</body></html>")

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $outFile = Join-Path $paths.ReportDir 'report.html'
    $sb.ToString() | Set-Content -Path $outFile -Encoding utf8
    # also keep a timestamped copy for history
    $sb.ToString() | Set-Content -Path (Join-Path $paths.ReportDir "report-$stamp.html") -Encoding utf8

    Write-Host "Report written to $outFile" -ForegroundColor Green
    if (-not $NoOpen) { Start-Process $outFile }
}

# ----------------------------------------------------------------------------
#  Quick stats in the terminal (no browser)
# ----------------------------------------------------------------------------
function Get-PingStats {
    [CmdletBinding()]
    param([string] $Target, [int] $Last = 0)
    $paths = Get-PingPlusPaths
    if (-not (Test-Path $paths.LogFile)) { Write-Warning 'No log yet.'; return }
    $records = Get-Content $paths.LogFile -Encoding utf8 | Where-Object { $_.Trim() } |
        ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_ }
    if ($Target) { $records = $records | Where-Object { $_.target -eq $Target } }
    if ($Last -gt 0) { $records = $records | Select-Object -Last $Last }
    $records | Group-Object target | ForEach-Object {
        $t = $_.Group; $tot = $t.Count
        $ok = @($t | Where-Object status -eq 'ok').Count
        $lat = @($t | Where-Object { $_.status -eq 'ok' -and $null -ne $_.latency_ms } | ForEach-Object { [double]$_.latency_ms })
        [pscustomobject]@{
            Target  = $_.Name
            Pings   = $tot
            OK      = $ok
            Dropped = $tot - $ok
            'Loss%' = if ($tot) { [math]::Round(100.0*($tot-$ok)/$tot,2) } else { 0 }
            AvgMs   = if ($lat) { [math]::Round(($lat|Measure-Object -Average).Average,1) } else { $null }
            MaxMs   = if ($lat) { [int]($lat|Measure-Object -Maximum).Maximum } else { $null }
        }
    }
}

Export-ModuleMember -Function Invoke-PingPlus, Show-PingReport, Get-PingStats, Get-PingPlusPaths
