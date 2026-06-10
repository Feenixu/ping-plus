# ============================================================================
#  ping+  (PingPlus.psm1)   v1.0.1   —   https://github.com/Feenixu/ping-plus
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
        LogFile    = Join-Path $logDir 'ping-log.jsonl'
        ConfigFile = Join-Path $root 'config.psd1'
    }
}

# ----------------------------------------------------------------------------
#  Concurrency-safe log I/O.  Add-Content / Get-Content take exclusive-ish
#  handles, so back-to-back ping runs (or an end-of-run report read racing a
#  still-writing run) collide with "Stream was not readable" / "being used by
#  another process". These helpers open with FileShare.ReadWrite and retry
#  briefly, so readers and writers never lock each other out.
# ----------------------------------------------------------------------------
$script:PingUtf8NoBom = [System.Text.UTF8Encoding]::new($false)

# Cache of one named-mutex per log path (with a reentrancy depth), so we don't
# reallocate a kernel handle on every logged line. Keyed by lower-cased path.
$script:PingLogMutexes = @{}

# Deterministic, FIPS-safe path hash (FNV-1a, 32-bit). Used only to derive a
# legal/stable mutex name from the log path. Crypto hashes (MD5/SHA) are avoided
# because [Security.Cryptography.MD5]::Create() throws under Windows FIPS policy,
# which would take down all logging; this needs no cryptographic strength.
function Get-PingPathHash {
    param([string] $Text)
    # FNV-1a 32-bit. Mask to 32 bits after each step so the widest product is
    # 4294967295 * 16777619 (~7.2e16), which fits in UInt64 without overflow.
    # NOTE: the mask MUST be the decimal literal 4294967295 — in PowerShell the
    # hex literal 0xFFFFFFFF parses as Int32 -1, which would not mask at all and
    # let $hash overflow on the next multiply.
    $mask = [uint64]4294967295
    $hash = [uint64]2166136261
    foreach ($b in [System.Text.Encoding]::UTF8.GetBytes($Text)) {
        $hash = ($hash -bxor [uint64]$b) -band $mask
        $hash = ($hash * [uint64]16777619) -band $mask
    }
    return ('{0:x8}' -f [uint32]$hash)
}

# A cross-process named mutex keyed to the log path. FileMode.Append's
# seek-then-write is NOT atomic across processes, so two simultaneous `ping -t`
# runs (separate processes) could grab the same end-offset and clobber each
# other's lines. Holding this mutex around every WRITE serializes them so no
# line is ever lost.
function Get-PingLogMutex {
    param([string] $Path)
    # 'Local\' (per-session) is enough: the real case is two ping runs by the
    # same user in the same session. 'Global\' would require SeCreateGlobalPrivilege
    # and throw for non-admin/constrained tokens, breaking logging entirely.
    $hash = Get-PingPathHash ($Path.ToLowerInvariant())
    return [System.Threading.Mutex]::new($false, "Local\pingplus_$hash")
}

# Run $Action while holding the per-path write lock. Reentrant on the same
# thread (depth-counted) so a holder can call other locked helpers without
# self-deadlock — e.g. retention holds the lock across read+rewrite, and the
# rewrite calls Write-PingLogLines which also locks. THROWS on acquisition
# timeout so callers retry rather than silently writing unlocked.
function Invoke-WithPingLogLock {
    param([string] $Path, [scriptblock] $Action)
    $key = $Path.ToLowerInvariant()
    $entry = $script:PingLogMutexes[$key]
    if (-not $entry) {
        $entry = [pscustomobject]@{ Mutex = (Get-PingLogMutex -Path $Path); Depth = 0 }
        $script:PingLogMutexes[$key] = $entry
    }
    $acquiredHere = $false
    if ($entry.Depth -eq 0) {
        $ok = $false
        try { $ok = $entry.Mutex.WaitOne(5000) }
        catch [System.Threading.AbandonedMutexException] {
            # A prior holder crashed mid-write; we now own the lock. The log may
            # have a torn final line, but readers tolerate that (bad JSON is
            # skipped). Surface it for diagnostics.
            Write-Verbose 'ping+: previous log writer abandoned the lock (process likely crashed).'
            $ok = $true
        }
        if (-not $ok) { throw [System.TimeoutException]::new("ping+: timed out acquiring log lock for $Path") }
        $acquiredHere = $true
    }
    $entry.Depth++
    try { & $Action }
    finally {
        $entry.Depth--
        if ($acquiredHere) { try { $entry.Mutex.ReleaseMutex() } catch { } }
    }
}

function Add-PingLogLine {
    param([string] $Path, [string] $Line)
    $err = $null
    for ($try = 0; $try -lt 25; $try++) {
        try {
            Invoke-WithPingLogLock -Path $Path -Action {
                $fs = [System.IO.FileStream]::new($Path,
                    [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::ReadWrite)
                try {
                    $sw = [System.IO.StreamWriter]::new($fs, $script:PingUtf8NoBom)
                    $sw.WriteLine($Line)
                    $sw.Flush(); $sw.Dispose()
                } finally { $fs.Dispose() }
            }
            return
        }
        catch { $err = $_; Start-Sleep -Milliseconds 20 }
    }
    # Last resort: don't let a logging hiccup ever break the ping itself.
    Write-Verbose "ping+ log append gave up after retries: $($err.Exception.Message)"
}

function Read-PingLogLines {
    param([string] $Path)
    if (-not (Test-Path $Path)) { return @() }
    for ($try = 0; $try -lt 25; $try++) {
        try {
            $fs = [System.IO.FileStream]::new($Path,
                [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite)
            try {
                $sr = [System.IO.StreamReader]::new($fs, $script:PingUtf8NoBom)
                $text = $sr.ReadToEnd(); $sr.Dispose()
            } finally { $fs.Dispose() }
            return $text -split "`r?`n" | Where-Object { $_.Trim() }
        }
        catch { Start-Sleep -Milliseconds 20 }
    }
    Write-Verbose 'ping+ log read gave up after retries.'
    return @()
}

function Write-PingLogLines {
    param([string] $Path, [string[]] $Lines)
    # Atomic rewrite under the write lock so retention can't clobber (or be
    # clobbered by) a concurrent append from another ping run. Write a temp file
    # then move it over the original, so a reader never sees a half-written log.
    Invoke-WithPingLogLock -Path $Path -Action {
        $tmp = "$Path.tmp"
        $done = $false
        try {
            $sw = [System.IO.StreamWriter]::new($tmp, $false, $script:PingUtf8NoBom)
            try { foreach ($l in $Lines) { $sw.WriteLine($l) } } finally { $sw.Dispose() }
            for ($try = 0; $try -lt 25; $try++) {
                try { [System.IO.File]::Replace($tmp, $Path, $null); $done = $true; break }
                catch {
                    try { Move-Item -Path $tmp -Destination $Path -Force; $done = $true; break }
                    catch { Start-Sleep -Milliseconds 20 }
                }
            }
            if (-not $done) { Write-Warning "ping+: could not rewrite log $Path after retries; left unchanged." }
        }
        finally {
            # Never leave an orphaned temp copy of the log behind.
            if (-not $done -and (Test-Path $tmp)) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        }
    }
}

# ----------------------------------------------------------------------------
#  Configuration + log retention
# ----------------------------------------------------------------------------

# Written verbatim to config.psd1 the first time config is needed. The comments
# make it self-documenting so the user can just open and tweak it.
$script:PingPlusConfigTemplate = @'
@{
    # =====================================================================
    #  ping+ configuration   —  edit, save, then use `ping` as normal.
    #  (Open quickly with:  pingconfig )
    # =====================================================================

    # Which log-retention strategy to apply to logs\ping-log.jsonl:
    #   'runs'   = keep only the last <KeepRuns> ping runs
    #   'days'   = keep only records from the last <KeepDays> days
    #   'both'   = keep a record only if it passes BOTH limits (bounds size AND age)
    #   'either' = keep a record if it passes EITHER limit (most lenient)
    #   'none'   = never delete anything
    RetentionMode = 'both'

    # Keep only the last N ping runs. One "run" = one `ping ...` command you ran.
    # Applies when RetentionMode is 'runs', 'both', or 'either'. 0 = no run limit.
    KeepRuns = 50

    # Delete records older than this many days.
    # Applies when RetentionMode is 'days', 'both', or 'either'. 0 = no age limit.
    KeepDays = 30

    # When to run cleanup automatically: 'start', 'finish', or 'both'.
    ApplyOn = 'finish'

    # How many timestamped report snapshots to keep in the reports\ folder.
    # 'report.html' (the latest) is always kept; this bounds the dated copies
    # like report-20260531-231841.html so that folder can't grow forever.
    # 0 = keep none (only the latest). Set higher if you want report history.
    KeepReports = 10
}
'@

function Get-PingPlusConfigDefaults {
    @{
        RetentionMode = 'both'
        KeepRuns      = 50
        KeepDays      = 30
        ApplyOn       = 'finish'
        KeepReports   = 10
    }
}

# Load (creating on first use) the effective config, validated + normalized.
function Get-PingPlusConfig {
    [CmdletBinding()]
    param()
    $cfgFile = (Get-PingPlusPaths).ConfigFile
    if (-not (Test-Path $cfgFile)) {
        try { Set-Content -Path $cfgFile -Value $script:PingPlusConfigTemplate -Encoding utf8 } catch { }
    }
    $cfg = Get-PingPlusConfigDefaults
    if (Test-Path $cfgFile) {
        try {
            $loaded = Import-PowerShellDataFile -Path $cfgFile
            foreach ($k in $loaded.Keys) { $cfg[$k] = $loaded[$k] }
        }
        catch {
            Write-Warning "ping+: could not parse $cfgFile ($($_.Exception.Message)). Using defaults."
        }
    }
    # Validate / normalize so bad values can never wipe data unexpectedly.
    $mode = "$($cfg.RetentionMode)".ToLower()
    $cfg.RetentionMode = if ($mode -in 'runs', 'days', 'both', 'either', 'none') { $mode } else { 'both' }
    $apply = "$($cfg.ApplyOn)".ToLower()
    $cfg.ApplyOn = if ($apply -in 'start', 'finish', 'both') { $apply } else { 'finish' }
    $cfg.KeepRuns = [math]::Max(0, [int]$cfg.KeepRuns)
    $cfg.KeepDays = [math]::Max(0.0, [double]$cfg.KeepDays)
    $cfg.KeepReports = [math]::Max(0, [int]$cfg.KeepReports)
    [pscustomobject]$cfg
}

# Open config.psd1 in an editor ($EDITOR, else VS Code, else Notepad).
function Edit-PingPlusConfig {
    [CmdletBinding()]
    param()
    $null = Get-PingPlusConfig                      # materialize if missing
    $cfgFile = (Get-PingPlusPaths).ConfigFile
    if ($env:EDITOR) { & $env:EDITOR $cfgFile; return }
    $code = Get-Command code -ErrorAction SilentlyContinue
    if ($code) { & $code.Source $cfgFile; return }
    notepad $cfgFile
}

# Apply the configured retention policy to the log (safe to call anytime).
function Invoke-PingRetention {
    [CmdletBinding()]
    param([object] $Config)

    $logFile = (Get-PingPlusPaths).LogFile
    if (-not (Test-Path $logFile)) { return }
    if (-not $Config) { $Config = Get-PingPlusConfig }
    if ($Config.RetentionMode -eq 'none') { return }

    # Hold the write lock across the WHOLE read-modify-write. Otherwise a ping
    # run could append a record between our read and our rewrite, and the rewrite
    # (built from the stale snapshot) would silently drop it. The lock is
    # reentrant, so the inner Write-PingLogLines lock is a no-op re-entry.
    # If logging is disabled/locked-out (timeout), just skip retention quietly.
    try {
        Invoke-WithPingLogLock -Path $logFile -Action { Invoke-PingRetentionLocked -Config $Config -LogFile $logFile }
    } catch [System.TimeoutException] {
        Write-Verbose 'ping+: skipped retention (could not acquire log lock).'
    }
}

# The actual read-modify-write, always run while holding the log lock.
function Invoke-PingRetentionLocked {
    param([object] $Config, [string] $LogFile)
    $logFile = $LogFile

    $lines = Read-PingLogLines -Path $logFile
    if (-not $lines) { return }

    # Parse just what retention needs: the raw line, its run id, its timestamp.
    $items = foreach ($ln in $lines) {
        $o = $null
        try { $o = $ln | ConvertFrom-Json } catch { }
        if ($null -eq $o) { continue }
        $run = if ($o.PSObject.Properties.Name -contains 'run' -and $o.run) { [string]$o.run } else { 'legacy' }
        [pscustomobject]@{ raw = $ln; run = $run; t = (ConvertTo-PingTime $o.ts) }
    }
    $items = @($items)
    if ($items.Count -eq 0) { return }

    $mode = $Config.RetentionMode

    # Run-based limit: keep the most recent N runs (ordered by their latest ts).
    $keepRunSet = $null
    if ($mode -in 'runs', 'both', 'either' -and [int]$Config.KeepRuns -ge 1) {
        $keepRuns = $items | Group-Object run |
            ForEach-Object { [pscustomobject]@{ run = $_.Name; last = ($_.Group.t | Measure-Object -Maximum).Maximum } } |
            Sort-Object last | Select-Object -Last ([int]$Config.KeepRuns) | ForEach-Object { $_.run }
        $keepRunSet = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($r in $keepRuns) { [void]$keepRunSet.Add([string]$r) }
    }

    # Age-based limit: keep records newer than the cutoff.
    $cutoff = $null
    if ($mode -in 'days', 'both', 'either' -and [double]$Config.KeepDays -gt 0) {
        $cutoff = (Get-Date).AddDays(-[double]$Config.KeepDays)
    }

    $kept = foreach ($it in $items) {
        $okRuns = if ($null -ne $keepRunSet) { $keepRunSet.Contains($it.run) } else { $true }
        $okDays = if ($null -ne $cutoff) { ($null -eq $it.t) -or ($it.t -ge $cutoff) } else { $true }
        $keep = switch ($mode) {
            'runs'   { $okRuns }
            'days'   { $okDays }
            'both'   { $okRuns -and $okDays }
            'either' { $okRuns -or $okDays }
            default  { $true }
        }
        if ($keep) { $it.raw }
    }
    $kept = @($kept)

    # Only rewrite if something actually changed; do it atomically.
    if ($kept.Count -ne $items.Count) {
        Write-PingLogLines -Path $logFile -Lines $kept
        Write-Verbose "ping+ retention: kept $($kept.Count) of $($items.Count) records."
    }
}

# ----------------------------------------------------------------------------
#  Write-PingReportLink  —  print ONE clickable line pointing at the report.
#  Uses an OSC 8 terminal hyperlink on terminals that support it (Windows
#  Terminal, modern VS Code, ConEmu); elsewhere it prints the bare file:// URL,
#  which those terminals still make Ctrl+click-able. Never any escape noise.
# ----------------------------------------------------------------------------
function Write-PingReportLink {
    param([Parameter(Mandatory)][string] $Path)
    $uri = ([System.Uri] (Resolve-Path $Path).Path).AbsoluteUri  # file:///C:/ping+/reports/report.html
    $supportsOsc8 = $env:WT_SESSION -or ($env:TERM_PROGRAM -eq 'vscode') -or ($env:ConEmuANSI -eq 'ON')
    if ($supportsOsc8) {
        $esc = [char]27
        Write-Host ("$esc]8;;$uri$esc\View ping+ report$esc]8;;$esc\")
    }
    else {
        Write-Host $uri
    }
}

# ----------------------------------------------------------------------------
#  Invoke-PingPlus  —  the wrapper. Call it directly, or via the `ping` /
#  `ping+` / `pingplus` aliases (see PingPlus.psm1 export + Install.ps1).
# ----------------------------------------------------------------------------
function Invoke-PingPlus {
    # Deliberately a SIMPLE function using the automatic $args — NOT an advanced
    # function. Declaring [CmdletBinding()] OR any [Parameter()] attribute makes
    # PowerShell add common parameters (-WarningAction, -Verbose, ...), and then
    # a real ping flag like `-w 200` fails to bind with "parameter -w is
    # ambiguous (-WarningAction/-WarningVariable)" before it ever reaches the
    # passthrough. $args captures every token verbatim so all ping flags work.
    $PingArgs = [string[]]$args

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

    # Best-effort target = last token that isn't a -flag / /flag. Held on an
    # object so the parsed value is readable from the line processor and the
    # finally block below.
    $bestTarget = ($PingArgs | Where-Object { $_ -notmatch '^[-/]' } | Select-Object -Last 1)
    if (-not $bestTarget) { $bestTarget = 'unknown' }
    $state  = [pscustomobject]@{ target = $bestTarget; ip = $null }
    $logged = [System.Collections.Generic.List[string]]::new()

    # Load retention config and stamp this invocation with a sortable run id so
    # "keep last N runs" can group records. Retention failures must never break
    # ping, hence the try/catch around it.
    $cfg   = Get-PingPlusConfig
    $runId = (Get-Date).ToString('yyyyMMddHHmmssfff') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 4))
    if ($cfg.ApplyOn -eq 'start' -or $cfg.ApplyOn -eq 'both') {
        try { Invoke-PingRetention -Config $cfg } catch { }
    }

    # Process one raw ping line: echo it *verbatim* (so the on-screen experience
    # is identical to stock ping), then parse + log it silently. Defined as a
    # scriptblock so the live loop and the Ctrl+C drain share one code path.
    $processLine = {
        param([string] $line)
        # ping.exe writes the literal word "Control-C" to stdout when a
        # continuous (-t) run is interrupted. Swallow it so the terminal shows
        # only its own native "^C" indicator, matching the stock ping look.
        if ($line.Trim() -eq 'Control-C') { return }
        Write-Host $line
        $ts = (Get-Date).ToString('o'); $status = $null; $lat = $null; $subms = $false
        if ($line -match 'Pinging\s+(?<host>\S+)\s+\[(?<ip>[^\]]+)\]') {
            $state.target = $Matches['host']; $state.ip = $Matches['ip']
        }
        elseif ($line -match 'Pinging\s+(?<host>\S+)\s+with') {
            $state.target = $Matches['host']; if (-not $state.ip) { $state.ip = $Matches['host'] }
        }
        elseif ($line -match 'Request timed out')                          { $status = 'timeout' }
        elseif ($line -match 'Destination (host|net) unreachable')         { $status = 'unreachable' }
        elseif ($line -match 'could not find host|could not find')         { $status = 'dns_error' }
        elseif ($line -match 'General failure|transmit failed|TTL expired'){ $status = 'error' }
        elseif ($line -match 'Reply from (?<rip>[^:]+):.*time(?<op>[=<])(?<t>\d+)\s*ms') {
            $status = 'ok'
            $lat    = [int]$Matches['t']
            if ($Matches['op'] -eq '<') { $subms = $true }
            if (-not $state.ip) { $state.ip = ($Matches['rip']).Trim() }
        }
        if ($status) {
            $rec = [ordered]@{
                ts = $ts; run = $runId; target = $state.target; ip = $state.ip
                status = $status; latency_ms = $lat; sub_ms = $subms; raw = $line.Trim()
            }
            Add-PingLogLine -Path $logFile -Line ($rec | ConvertTo-Json -Compress)
            $logged.Add($status)
        }
    }
    # Per-stream buffer of bytes read but not yet terminated by a newline.
    # ReadLine() can't be used for live tailing: when the reader catches up to
    # ping mid-line (bytes written, newline not flushed yet) ReadLine returns the
    # PARTIAL line, so the rest arrives as a separate "line" -> the on-screen line
    # break bug. Instead we read raw chars and only emit COMPLETE (\n-terminated)
    # lines, holding any trailing fragment until its newline arrives.
    $pending = @{ out = ''; err = '' }
    $readBuf = [char[]]::new(8192)
    $pump = {
        param($rdr, $key)
        if (-not $rdr) { return }
        while (($n = $rdr.Read($readBuf, 0, $readBuf.Length)) -gt 0) {
            $pending[$key] += [string]::new($readBuf, 0, $n)
        }
        $nl = $pending[$key].IndexOf("`n")
        while ($nl -ge 0) {
            $line = $pending[$key].Substring(0, $nl).TrimEnd("`r")
            $pending[$key] = $pending[$key].Substring($nl + 1)
            & $processLine $line
            $nl = $pending[$key].IndexOf("`n")
        }
    }
    # After the process has exited, emit any final fragment that has no trailing
    # newline (rare for ping, whose output ends with one, but never drop it).
    $flushTail = {
        foreach ($key in 'out', 'err') {
            if ($pending[$key].Length -gt 0) {
                & $processLine ($pending[$key].TrimEnd("`r"))
                $pending[$key] = ''
            }
        }
    }

    # Run the REAL ping with stdout/stderr redirected to temp files, tail them
    # live for verbatim display, and drain the remainder in `finally`. This is
    # what lets us keep ping's final "Ping statistics" block when a continuous
    # (`-t`) run is ended with Ctrl+C: the old `| ForEach-Object` pipeline was
    # torn down by Ctrl+C *before* those last lines were read, so they vanished.
    # Here ping (sharing the console) gets the Ctrl+C too, writes its summary to
    # the temp file, and exits; we then read and display those lines.
    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
    $proc = $null; $rOut = $null; $rErr = $null
    try {
        $proc = Start-Process -FilePath $pingExe -ArgumentList $PingArgs -NoNewWindow -PassThru `
                    -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        $rOut = [System.IO.StreamReader]::new([System.IO.FileStream]::new(
                    $tmpOut, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite))
        $rErr = [System.IO.StreamReader]::new([System.IO.FileStream]::new(
                    $tmpErr, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite))

        while (-not $proc.HasExited) {
            & $pump $rOut 'out'
            & $pump $rErr 'err'
            Start-Sleep -Milliseconds 40
        }
        # Process exited: pump whatever it wrote last, then flush any final
        # newline-less fragment so nothing is dropped.
        & $pump $rOut 'out'
        & $pump $rErr 'err'
        & $flushTail
    }
    finally {
        # On Ctrl+C, ping is still flushing its statistics block — wait briefly,
        # then drain every remaining line so the final summary shows and logs
        # exactly like stock ping.
        try {
            if ($proc) { [void]$proc.WaitForExit(2000) }
            & $pump $rOut 'out'
            & $pump $rErr 'err'
            & $flushTail
            if ($rOut) { $rOut.Dispose() }
            if ($rErr) { $rErr.Dispose() }
        } catch { }
        Remove-Item $tmpOut, $tmpErr -ErrorAction SilentlyContinue

        # Apply log retention (per config) before building the report so the
        # report reflects exactly what's kept on disk.
        if ($cfg.ApplyOn -eq 'finish' -or $cfg.ApplyOn -eq 'both') {
            try { Invoke-PingRetention -Config $cfg } catch { }
        }
        # The one and only addition to stock ping: a single clickable link.
        if ($logged.Count -gt 0) {
            $reportPath = New-PingReportFile -Target $state.target
            if ($reportPath) { Write-PingReportLink -Path $reportPath }
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
        $run = if ($r.PSObject.Properties.Name -contains 'run' -and $r.run) { [string]$r.run } else { 'legacy' }
        [pscustomobject]@{ t = $t; ok = ($r.status -eq 'ok'); lat = $r.latency_ms; run = $run }
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

    # latency polyline (only over ok points). Break the line whenever the run
    # id changes (a new session) so separate sessions aren't joined by a
    # misleading diagonal across the idle gap. Each contiguous same-run stretch
    # becomes its own polyline; dots still mark every point.
    $allDots = New-Object System.Collections.Generic.List[string]
    $seg = New-Object System.Collections.Generic.List[string]
    $segRun = $null
    $flushSeg = {
        if ($seg.Count -ge 2) {
            [void]$sb.Append("<polyline fill='none' stroke='#58a6ff' stroke-width='1.5' points='$($seg -join ' ')'/>")
        }
        $seg.Clear()
    }
    foreach ($p in $points) {
        if ($p.ok -and $null -ne $p.lat) {
            $x = [math]::Round((& $xOf $p.t), 1)
            $y = [math]::Round((& $yOf $p.lat), 1)
            if ($null -ne $segRun -and $p.run -ne $segRun) { & $flushSeg }
            $segRun = $p.run
            $seg.Add("$x,$y")
            $allDots.Add("$x,$y")
        }
    }
    & $flushSeg
    foreach ($pt in $allDots) {
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
    $ordered = @($records | Sort-Object { ConvertTo-PingTime $_.ts })
    $n = $ordered.Count
    if ($n -lt 1) { return '' }
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

# Given records (already filtered to one target or many), return only those
# belonging to each target's most-recent run/session. "Latest" is decided by
# the run whose newest timestamp is greatest, so it's robust to legacy records
# that lack a run id.
function Select-PingLatestSession {
    param([object[]] $records)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($tg in ($records | Group-Object target)) {
        $byRun = $tg.Group | Group-Object {
            if ($_.PSObject.Properties.Name -contains 'run' -and $_.run) { [string]$_.run } else { 'legacy' }
        }
        $latest = $byRun |
            ForEach-Object { [pscustomobject]@{ grp = $_; last = ($_.Group | ForEach-Object { ConvertTo-PingTime $_.ts } | Measure-Object -Maximum).Maximum } } |
            Sort-Object last | Select-Object -Last 1
        if ($latest) { foreach ($r in $latest.grp.Group) { $out.Add($r) } }
    }
    return $out
}

# ----------------------------------------------------------------------------
#  New-PingReportFile  —  build the HTML report silently and return its path
#  (or $null when there's nothing to report). No console output, no browser.
#  This is what the live `ping` wrapper calls to refresh the report.
# ----------------------------------------------------------------------------
function New-PingReportFile {
    [CmdletBinding()]
    param(
        [string] $Target,            # filter to one host
        [int]    $Last = 0,          # 0 = all records
        [switch] $AllHistory         # include every session (default: latest session only)
    )

    $paths = Get-PingPlusPaths
    if (-not (Test-Path $paths.LogFile)) { return $null }
    if (-not (Test-Path $paths.ReportDir)) {
        New-Item -ItemType Directory -Path $paths.ReportDir -Force | Out-Null
    }

    $records = Read-PingLogLines -Path $paths.LogFile |
        ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } |
        Where-Object { $_ }

    if ($Target) { $records = $records | Where-Object { $_.target -eq $Target } }
    # By default show only each host's most-recent session, so re-pinging the
    # same target doesn't visually merge separate runs. -AllHistory opts into
    # the full cross-session view (useful for "how often does it drop overall").
    if (-not $AllHistory) { $records = Select-PingLatestSession $records }
    if ($Last -gt 0) { $records = $records | Select-Object -Last $Last }
    if (-not $records) { return $null }

    $generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $scopeLabel = if ($AllHistory) { 'all sessions' } else { 'latest session' }
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
    [void]$sb.Append("<h1>ping+ report</h1><div class='muted'>Generated $generated &middot; scope: $scopeLabel &middot; source: $(ConvertTo-HtmlText $paths.LogFile)</div>")

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

        $outages = @(Get-PingOutages $recs)
        $tFirst  = ConvertTo-PingTime ($recs | Sort-Object { ConvertTo-PingTime $_.ts } | Select-Object -First 1).ts
        $tLast   = ConvertTo-PingTime ($recs | Sort-Object { ConvertTo-PingTime $_.ts } | Select-Object -Last 1).ts
        $elapsed = if ($tFirst -and $tLast) { Format-PingSpan ($tLast - $tFirst) } else { '-' }

        $rateCls = if ($rate -eq 0) { 'good' } else { 'bad' }

        [void]$sb.Append("<h2>$(ConvertTo-HtmlText $g.Name)</h2>")
        [void]$sb.Append("<div class='muted'>$($tFirst.ToString('yyyy-MM-dd HH:mm:ss')) &rarr; $($tLast.ToString('yyyy-MM-dd HH:mm:ss'))</div>")
        [void]$sb.Append("<div class='cards'>")
        [void]$sb.Append("<div class='card'><div class='v'>$total</div><div class='k'>Pings</div></div>")
        [void]$sb.Append("<div class='card'><div class='v'>$elapsed</div><div class='k'>Elapsed</div></div>")
        [void]$sb.Append("<div class='card good'><div class='v'>$okN</div><div class='k'>OK</div></div>")
        [void]$sb.Append("<div class='card bad'><div class='v'>$drops</div><div class='k'>Dropped</div></div>")
        [void]$sb.Append("<div class='card $rateCls'><div class='v'>$rate%</div><div class='k'>Loss</div></div>")
        [void]$sb.Append("<div class='card'><div class='v'>$lAvg</div><div class='k'>Avg ms</div></div>")
        [void]$sb.Append("<div class='card'><div class='v'>$lMin/$lMax</div><div class='k'>Min/Max ms</div></div>")
        [void]$sb.Append("<div class='card'><div class='v'>$lP50/$lP95</div><div class='k'>p50/p95 ms</div></div>")
        $outClass = if ($outages.Count) { 'bad' } else { 'good' }
        [void]$sb.Append("<div class='card $outClass'><div class='v'>$($outages.Count)</div><div class='k'>Outages</div></div>")
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
    $html = $sb.ToString()
    $html | Set-Content -Path $outFile -Encoding utf8

    # Keep a bounded number of timestamped snapshots for history, then prune the
    # oldest so reports\ can't grow without limit. KeepReports comes from config.
    $keepReports = 10
    try { $keepReports = [int](Get-PingPlusConfig).KeepReports } catch { }
    if ($keepReports -gt 0) {
        $html | Set-Content -Path (Join-Path $paths.ReportDir "report-$stamp.html") -Encoding utf8
    }
    $snaps = @(Get-ChildItem -Path $paths.ReportDir -Filter 'report-*.html' -ErrorAction SilentlyContinue |
        Sort-Object Name)
    if ($snaps.Count -gt $keepReports) {
        $snaps | Select-Object -First ($snaps.Count - $keepReports) |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    return $outFile
}

# ----------------------------------------------------------------------------
#  Show-PingReport  —  interactive command: build the report, print where it
#  went, and open it in the browser (unless -NoOpen).
# ----------------------------------------------------------------------------
function Show-PingReport {
    [CmdletBinding()]
    param(
        [string] $Target,          # filter to one host
        [int]    $Last = 0,        # 0 = all records
        [switch] $AllHistory,      # include all sessions (default: latest only)
        [switch] $NoOpen           # don't auto-open the browser
    )
    $outFile = New-PingReportFile -Target $Target -Last $Last -AllHistory:$AllHistory
    if (-not $outFile) {
        Write-Warning "No matching ping data yet. Run some pings first (e.g. 'ping google.com')."
        return
    }
    Write-Host "Report written to $outFile" -ForegroundColor Green
    if (-not $NoOpen) { Start-Process $outFile }
}

# ----------------------------------------------------------------------------
#  Quick stats in the terminal (no browser)
# ----------------------------------------------------------------------------
function Get-PingStats {
    [CmdletBinding()]
    param([string] $Target, [int] $Last = 0, [switch] $AllHistory)
    $paths = Get-PingPlusPaths
    if (-not (Test-Path $paths.LogFile)) { Write-Warning 'No log yet.'; return }
    $records = Read-PingLogLines -Path $paths.LogFile |
        ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_ }
    if ($Target) { $records = $records | Where-Object { $_.target -eq $Target } }
    # Match the report: default to each host's latest session unless -AllHistory.
    if (-not $AllHistory) { $records = Select-PingLatestSession $records }
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

Export-ModuleMember -Function Invoke-PingPlus, Show-PingReport, Get-PingStats, Get-PingPlusPaths,
    Get-PingPlusConfig, Edit-PingPlusConfig, Invoke-PingRetention
