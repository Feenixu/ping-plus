<#
  Install.ps1  —  wire ping+ into your PowerShell session.

  What it does (all reversible, nothing destructive):
    * Adds a block to your PowerShell profile that imports the PingPlus module
      (via its manifest, PingPlus.psd1) and defines convenient commands.
    * By default it also defines a `ping` FUNCTION that shadows the built-in
      ping for interactive sessions ONLY. PowerShell resolves functions before
      external .exe files, so `ping google.com` runs the enhanced version while
      C:\Windows\System32\PING.EXE stays completely untouched. Other programs,
      scripts, and cmd.exe still get the real ping.

  Usage:
    pwsh -File C:\ping+\Install.ps1            # installs, shadows `ping`
    pwsh -File C:\ping+\Install.ps1 -NoShadow  # installs, does NOT shadow `ping`
    pwsh -File C:\ping+\Install.ps1 -Uninstall # removes the ping+ block

  After installing, open a NEW terminal (or run: . $PROFILE.CurrentUserAllHosts).
#>
[CmdletBinding()]
param(
    [switch] $NoShadow,
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'
$moduleDir  = $PSScriptRoot
# The profile block imports the MANIFEST (.psd1), not the bare .psm1, so
# Get-Module reports the real version and PowerShell module tooling works.
$manifestPath = Join-Path $moduleDir 'PingPlus.psd1'
$psm1Path     = Join-Path $moduleDir 'PingPlus.psm1'
$modulePath   = $manifestPath
$startTag   = '# >>> ping+ >>>'
$endTag     = '# <<< ping+ <<<'

# Both files are required (-LiteralPath so dirs containing [brackets] work).
foreach ($required in @($manifestPath, $psm1Path)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Cannot find $(Split-Path $required -Leaf) next to Install.ps1 (looked in $moduleDir)."
    }
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

# The block is generated from a single-quoted template (placeholders swapped in
# below) so nothing expands at install time by accident, and apostrophes in the
# baked path are doubled so they can't break the generated single-quoted
# literal. At profile time the block:
#   * resolves the module path: the path baked at install time, falling back to
#     this machine's default get.ps1 install dir — so a profile synced (e.g.
#     via OneDrive) from a machine that installed elsewhere still finds a
#     local install;
#   * imports inside try/catch, so a half-synced or corrupt install prints one
#     quiet line instead of a red error on every shell;
#   * if ping+ isn't on this machine at all, prints one install hint — and only
#     in interactive non-redirected sessions, so automation keeps clean stdout.
# Aliases are NOT set here: the module exports them (see AliasesToExport), so
# they update with the module instead of being frozen into the profile.
$blockTemplate = @'
# >>> ping+ >>>
$pingPlusModule = '__MODULE_PATH__'
if (-not (Test-Path -LiteralPath $pingPlusModule) -and $env:LOCALAPPDATA) {
    $pingPlusModule = Join-Path $env:LOCALAPPDATA 'ping-plus\PingPlus.psd1'
}
if (Test-Path -LiteralPath $pingPlusModule) {
    try {
        Import-Module $pingPlusModule -Force -ErrorAction Stop
        __SHADOW_LINE__
    } catch {
        Write-Host "ping+ found at $pingPlusModule but failed to load: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
} elseif ([Environment]::UserInteractive -and -not [Console]::IsOutputRedirected) {
    Write-Host "ping+ is configured in this profile but not installed on this machine. Install: irm https://raw.githubusercontent.com/Feenixu/ping-plus/master/get.ps1 | iex" -ForegroundColor DarkGray
}
Remove-Variable -Name pingPlusModule -ErrorAction SilentlyContinue
# <<< ping+ <<<
'@
$block = $blockTemplate.Replace('__MODULE_PATH__', $modulePath.Replace("'", "''")).Replace('__SHADOW_LINE__', $shadowLine)

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
    Import-Module $modulePath -Force -ErrorAction Stop
    $null = Get-PingPlusConfig
    Write-Host "Config file: $((Get-PingPlusPaths).ConfigFile)" -ForegroundColor Cyan
    Write-Host ""
} catch {
    Write-Warning "ping+ was wired into the profile, but importing the module failed: $($_.Exception.Message)"
}

Write-Host "Load it now without reopening:  . `"$profilePath`"" -ForegroundColor Yellow
