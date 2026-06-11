<#
  get.ps1  —  one-line web installer for ping+.

  Usage (in PowerShell):
      irm https://raw.githubusercontent.com/Feenixu/ping-plus/master/get.ps1 | iex

  What it does:
    * Downloads the latest ping+ into  %LOCALAPPDATA%\ping-plus  (override with
      $env:PINGPLUS_DIR before running).
    * Prefers `git clone` (so you can `git pull` to update); falls back to
      downloading + extracting the GitHub zip if git isn't available.
    * Runs Install.ps1 to wire it into your PowerShell profile.

  Nothing requires admin. Uninstall any time with:
      pwsh -File "$env:LOCALAPPDATA\ping-plus\Install.ps1" -Uninstall
#>
[CmdletBinding()]
param(
    [string] $Repo    = 'https://github.com/Feenixu/ping-plus.git',
    [string] $ZipUrl  = 'https://github.com/Feenixu/ping-plus/archive/refs/heads/master.zip',
    [string] $Dir     = $(if ($env:PINGPLUS_DIR) { $env:PINGPLUS_DIR } else { Join-Path $env:LOCALAPPDATA 'ping-plus' }),
    [switch] $NoShadow
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "Installing ping+ to $Dir" -ForegroundColor Cyan
$parent = Split-Path $Dir -Parent
if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) {
    if (Test-Path (Join-Path $Dir '.git')) {
        Write-Host "Existing clone found — updating (git pull)..." -ForegroundColor DarkGray
        & $git.Source -C $Dir pull --ff-only
    }
    else {
        if (Test-Path $Dir) { Remove-Item -Recurse -Force $Dir }
        & $git.Source clone --depth 1 $Repo $Dir
    }
}
else {
    Write-Host "git not found — downloading zip instead..." -ForegroundColor DarkGray
    $tmpZip = Join-Path $env:TEMP ('pingplus-' + [guid]::NewGuid().ToString('N') + '.zip')
    Invoke-WebRequest -Uri $ZipUrl -OutFile $tmpZip
    $tmpDir = Join-Path $env:TEMP ('pingplus-' + [guid]::NewGuid().ToString('N'))
    Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
    $inner = Get-ChildItem $tmpDir -Directory | Select-Object -First 1
    if (Test-Path $Dir) { Remove-Item -Recurse -Force $Dir }
    Move-Item -Path $inner.FullName -Destination $Dir
    Remove-Item $tmpZip, $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

$installer = Join-Path $Dir 'Install.ps1'
if (-not (Test-Path $installer)) { throw "Install.ps1 not found in $Dir after download." }

& $installer -NoShadow:$NoShadow
Write-Host ""
Write-Host "ping+ is installed. Open a new terminal (or run '. `$PROFILE.CurrentUserAllHosts') to start using it." -ForegroundColor Green
