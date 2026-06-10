<#
  Install.ps1  —  wire ping+ into your PowerShell session.

  What it does (all reversible, nothing destructive):
    * Adds a block to your PowerShell profile that imports PingPlus.psm1
      and defines convenient commands.
    * By default it also defines a `ping` FUNCTION that shadows the built-in
      ping for interactive sessions ONLY. PowerShell resolves functions before
      external .exe files, so `ping google.com` runs the enhanced version while
      C:\Windows\System32\PING.EXE stays completely untouched. Other programs,
      scripts, and cmd.exe still get the real ping.

  Usage:
    pwsh -File C:\ping+\Install.ps1            # installs, shadows `ping`
    pwsh -File C:\ping+\Install.ps1 -NoShadow  # installs, does NOT shadow `ping`
    pwsh -File C:\ping+\Install.ps1 -Uninstall # removes the ping+ block

  After installing, open a NEW terminal (or run: . $PROFILE).
#>
[CmdletBinding()]
param(
    [switch] $NoShadow,
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'
$moduleDir  = $PSScriptRoot
# Import the MANIFEST (.psd1), not the bare .psm1, so Get-Module reports the real
# version and PowerShell module tooling works. Falls back to the .psm1 only if a
# manifest somehow isn't present.
$manifestPath = Join-Path $moduleDir 'PingPlus.psd1'
$psm1Path     = Join-Path $moduleDir 'PingPlus.psm1'
$modulePath   = if (Test-Path $manifestPath) { $manifestPath } else { $psm1Path }
$startTag   = '# >>> ping+ >>>'
$endTag     = '# <<< ping+ <<<'

if (-not (Test-Path $psm1Path)) {
    throw "Cannot find PingPlus.psm1 next to Install.ps1 (looked in $moduleDir)."
}

# Ensure profile file exists.
$profilePath = $PROFILE.CurrentUserAllHosts
if (-not $profilePath) { $profilePath = $PROFILE }
$profileDir = Split-Path $profilePath -Parent
if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
if (-not (Test-Path $profilePath)) { New-Item -ItemType File -Path $profilePath -Force | Out-Null }

# Strip any existing ping+ block so install/uninstall is idempotent.
$content = Get-Content -Path $profilePath -Raw -ErrorAction SilentlyContinue
if ($null -eq $content) { $content = '' }
$pattern = [regex]::Escape($startTag) + '.*?' + [regex]::Escape($endTag)
$content = [regex]::Replace($content, $pattern, '', 'Singleline').TrimEnd()

if ($Uninstall) {
    Set-Content -Path $profilePath -Value $content -Encoding utf8
    Write-Host "ping+ removed from $profilePath" -ForegroundColor Green
    Write-Host "Open a new terminal for it to take effect." -ForegroundColor Yellow
    return
}

$shadowLine = if ($NoShadow) {
    "# (ping not shadowed; use 'pingplus' or 'ping+')"
} else {
    "function ping { Invoke-PingPlus @args }"
}

# The block is guarded by Test-Path: this profile may be SYNCED (e.g. via
# OneDrive) to a machine where ping+ was never installed, in which case the
# module file won't exist there. Without the guard, every new shell on that
# machine throws a red "module not found" error. With it, ping+ just stays
# inactive and prints one quiet hint, leaving the rest of the profile working.
$block = @"
$startTag
if (Test-Path '$modulePath') {
    Import-Module '$modulePath' -Force
    Set-Alias -Name pingplus  -Value Invoke-PingPlus -Scope Global
    Set-Alias -Name 'ping+'   -Value Invoke-PingPlus -Scope Global
    Set-Alias -Name pingreport -Value Show-PingReport     -Scope Global
    Set-Alias -Name pingstats  -Value Get-PingStats       -Scope Global
    Set-Alias -Name pingconfig -Value Edit-PingPlusConfig -Scope Global
    Set-Alias -Name pingclean  -Value Invoke-PingRetention -Scope Global
    Set-Alias -Name pingupdate -Value Get-PingPlusUpdate   -Scope Global
    $shadowLine
} else {
    Write-Host "ping+ is configured in this profile but not installed on this machine. Install: irm https://raw.githubusercontent.com/Feenixu/ping-plus/master/get.ps1 | iex" -ForegroundColor DarkGray
}
$endTag
"@

$newContent = ($content + "`r`n`r`n" + $block).TrimStart()
Set-Content -Path $profilePath -Value $newContent -Encoding utf8

Write-Host "ping+ installed into $profilePath" -ForegroundColor Green
Write-Host ""
Write-Host "Commands now available in a NEW terminal:" -ForegroundColor Cyan
if (-not $NoShadow) {
    Write-Host "  ping <host> [opts]   enhanced ping (shadows built-in, logs everything)"
}
Write-Host "  pingplus <host>      enhanced ping (always available)"
Write-Host "  ping+ <host>         same thing"
Write-Host "  pingreport           build + open the HTML report"
Write-Host "  pingstats            quick loss/latency table in the terminal"
Write-Host "  pingconfig           open the config file (retention settings)"
Write-Host "  pingclean            apply log retention now"
Write-Host "  pingupdate           check GitHub for a newer version"
Write-Host ""

# Materialize the config file now so it's ready to edit immediately.
try {
    Import-Module $modulePath -Force
    $null = Get-PingPlusConfig
    Write-Host "Config file: $((Get-PingPlusPaths).ConfigFile)" -ForegroundColor Cyan
    Write-Host ""
} catch { }

Write-Host "Load it now without reopening:  . `$PROFILE" -ForegroundColor Yellow
