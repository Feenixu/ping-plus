<#
  get.ps1  -  one-line web installer for ping+.

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

# Everything runs inside a child scope (& { ... }) because this script is
# consumed via `irm ... | iex`, which executes in the CALLER's session. Without
# the wrapper, $ErrorActionPreference='Stop', the forced TLS setting, and every
# local variable below would leak into and permanently alter the user's shell.
& {
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Write-Host "Installing ping+ to $Dir" -ForegroundColor Cyan
    $parent = Split-Path $Dir -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    # Preserve the user's data (ping history, reports, config) across a reinstall
    # or update - README calls re-running the installer the way to update, and
    # the clone/zip paths below delete $Dir. Stash these aside, restore after,
    # and never clobber a file the new version ships.
    $preserve = @('logs', 'reports', 'config.psd1')
    $stash = $null
    if (Test-Path $Dir) {
        $stash = Join-Path $env:TEMP ('pingplus-stash-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $stash -Force | Out-Null
        foreach ($item in $preserve) {
            $src = Join-Path $Dir $item
            if (Test-Path -LiteralPath $src) { Move-Item -LiteralPath $src -Destination (Join-Path $stash $item) -Force }
        }
    }

    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        if (Test-Path (Join-Path $Dir '.git')) {
            Write-Host "Existing clone found - updating (git pull)..." -ForegroundColor DarkGray
            & $git.Source -C $Dir pull --ff-only
            if ($LASTEXITCODE -ne 0) { throw "git pull failed (exit $LASTEXITCODE). Resolve the clone at $Dir, then retry." }
        }
        else {
            if (Test-Path $Dir) { Remove-Item -Recurse -Force $Dir }
            & $git.Source clone --depth 1 $Repo $Dir
            if ($LASTEXITCODE -ne 0) { throw "git clone failed (exit $LASTEXITCODE)." }
        }
    }
    else {
        Write-Host "git not found - downloading zip instead..." -ForegroundColor DarkGray
        $tmpZip = Join-Path $env:TEMP ('pingplus-' + [guid]::NewGuid().ToString('N') + '.zip')
        Invoke-WebRequest -Uri $ZipUrl -OutFile $tmpZip
        $tmpDir = Join-Path $env:TEMP ('pingplus-' + [guid]::NewGuid().ToString('N'))
        Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
        $inner = Get-ChildItem $tmpDir -Directory | Select-Object -First 1
        if (Test-Path $Dir) { Remove-Item -Recurse -Force $Dir }
        Move-Item -Path $inner.FullName -Destination $Dir
        Remove-Item $tmpZip, $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Restore preserved data (only where the fresh install didn't ship its own).
    if ($stash) {
        foreach ($item in $preserve) {
            $saved = Join-Path $stash $item
            $dest  = Join-Path $Dir $item
            if ((Test-Path -LiteralPath $saved) -and -not (Test-Path -LiteralPath $dest)) {
                Move-Item -LiteralPath $saved -Destination $dest -Force
            }
        }
        Remove-Item $stash -Recurse -Force -ErrorAction SilentlyContinue
    }

    $installer = Join-Path $Dir 'Install.ps1'
    if (-not (Test-Path $installer)) { throw "Install.ps1 not found in $Dir after download." }

    & $installer -NoShadow:$NoShadow
    Write-Host ""
    Write-Host "ping+ is installed. Open a new terminal (or run '. `$PROFILE.CurrentUserAllHosts') to start using it." -ForegroundColor Green
}
