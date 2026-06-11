# Changelog

All notable changes to ping+ are documented here.
This project adheres to [Semantic Versioning](https://semver.org/).

## [1.1.2] - 2026-06-11

Hardening pass over the 1.1.1 install/profile work (code-review findings).
Fully backward compatible; re-run `Install.ps1` to get the new profile block.

### Fixed
- **Profile block survives hostile paths** — the baked module path is now
  apostrophe-escaped and all existence checks use `-LiteralPath`, so install
  dirs containing `'`, `[`, or `]` can no longer produce a profile that fails
  to parse (which killed the *entire* profile on every shell) or a guard that
  claims ping+ isn't installed when it is.
- **No more red error wall from half-synced installs** — the profile block now
  imports inside `try/catch`: a manifest whose `.psm1` is missing (OneDrive
  partial sync / Files-On-Demand, AV quarantine) prints one quiet line instead
  of erroring on every new shell.
- **Synced-profile path mismatch** — if the path baked by the last machine to
  run the installer doesn't exist locally, the block falls back to this
  machine's default install location (`%LOCALAPPDATA%\ping-plus`), so machines
  with different usernames/install dirs no longer silently deactivate ping+.
- **Installer honesty** — `Install.ps1` now requires both `PingPlus.psd1` and
  `PingPlus.psm1` up front (no silent fallback to the version-less `.psm1`)
  and warns instead of silently swallowing a failed import check.
- **`. $PROFILE` hint pointed at the wrong file** — the block is written to
  `$PROFILE.CurrentUserAllHosts` (`profile.ps1`), but the docs/install output
  said `. $PROFILE`, which is a *different* file (`Microsoft.PowerShell_profile.ps1`).
  All hints now reference the actual file.
- **Hint noise in automation** — the "not installed" hint only prints in
  interactive, non-redirected sessions, keeping stdout clean for scripts that
  load profiles.
- Stale "imports PingPlus.psm1" comment in `Install.ps1`; duplicated "imports
  the module" bullet in the README; `Test-PingPlus.ps1` now imports the
  manifest like everything else (so it no longer resets `Get-Module`'s version
  to 0.0 for the session).
- **`get.ps1` failed to parse when run from disk on Windows PowerShell 5.1**
  (pre-existing, found while validating this release) — the repo's scripts
  were BOM-less UTF-8 with em dashes inside double-quoted strings; PS 5.1
  decodes BOM-less files as ANSI, which turns `—` into a smart quote that
  terminates the string early. All `.ps1`/`.psd1`/`.psm1` files are now saved
  as UTF-8 **with BOM**. (The documented `irm … | iex` path was unaffected.)

### Changed
- **Aliases now live in the module** (exported via `AliasesToExport`) instead
  of being frozen into each profile at install time — future commands arrive
  with a module update, no reinstall needed. The profile block shrinks to
  guard + import + the optional `ping` shadow.
- **Version is single-sourced** — the module reads its version from
  `PingPlus.psd1` at load, so the update check can never disagree with
  `Get-Module` after a release that forgets to bump one of the copies.
- `pingupdate`'s "git pull" tip now reminds clone users to re-run `Install.ps1`
  so profile-block fixes actually reach them.

## [1.1.1] - 2026-06-11

Install/profile robustness. Fully backward compatible.

### Fixed
- **Synced-profile error wall** — the profile block is now guarded with
  `Test-Path`. If your PowerShell profile is synced across machines (e.g. via
  OneDrive) to one where ping+ isn't installed, new shells no longer throw a red
  "module not loaded" error every time; ping+ just stays inactive and prints a
  one-line install hint.
- **`Get-Module` showed version `0.0`** — the installer now imports the module
  via its manifest (`PingPlus.psd1`) instead of the bare `.psm1`, so
  `Get-Module PingPlus` reports the real version. `FunctionsToExport` also now
  includes `Get-PingPlusUpdate` / `Test-PingPlusUpdate`.

## [1.1.0] - 2026-06-11

Adds a lightweight, no-hosting update check. Fully backward compatible.

### Added
- **Update check** — `pingupdate` checks GitHub for a newer version, and a ping
  run prints one quiet line if an update is available. Cached to at most once
  per 24h and fully fail-silent (offline/error → does nothing). Requires no
  hosting; reads the version published in the repo.

## [1.0.1] - 2026-06-11

Hardens concurrent logging and fixes two display/usage bugs found after the
first release. Fully backward compatible.

### Fixed
- **Concurrent-log crash** — back-to-back runs (or a report/retention read
  racing a still-writing run) no longer fail with "Stream was not readable" /
  "being used by another process". Log I/O now uses shared-mode file handles
  with brief retries.
- **Lost log lines under true concurrency** — two simultaneous `ping` runs
  appending to the shared log could silently clobber each other; writes are now
  serialized with a per-log named mutex.
- **Retention race (TOCTOU)** — log retention now holds the lock across its
  whole read-modify-write, so a record appended mid-retention is no longer
  dropped.
- **Portability** — replaced the MD5-based mutex name (threw under Windows FIPS
  policy, taking down all logging) with a non-crypto hash, and moved the mutex
  from the `Global\` to the `Local\` namespace (no longer needs admin /
  SeCreateGlobalPrivilege).
- **Retention robustness** — a failed log rewrite no longer leaves an orphaned
  `.tmp` or reports false success; it cleans up and warns.
- **Random line breaks in live output** — a single ping reply could be split
  across two printed lines when the output reader caught the writer mid-line;
  the tailer now emits only complete lines.
- **Ping flags being intercepted** — flags like `-w` (and `-?`, `-Verbose`,
  etc.) were swallowed by PowerShell's common-parameter binding and failed with
  "parameter is ambiguous". `Invoke-PingPlus` is now a simple function, so the
  entire Windows `ping` flag set passes through verbatim.

## [1.0.0] - 2026-06-01

First public release.

### Features
- **Non-destructive `ping` wrapper** — calls the real `ping.exe`, shows its
  output verbatim, and adds a single clickable "View ping+ report" link at the
  end. The built-in ping binary is never modified.
- **Silent logging** — every reply / timeout / DNS error is timestamped and
  appended to `logs/ping-log.jsonl` (one JSON object per line), tagged with a
  per-run id so history persists across sessions.
- **Local HTML report** (`pingreport`) — fully offline, zero dependencies, pure
  inline SVG: latency graph over time, availability strip, outage table
  ("between these timestamps all pings failed"), and summary cards including
  total elapsed time.
- **Sessions** — the report and `pingstats` default to the latest session per
  host; `-AllHistory` shows every session (with the latency line broken per
  session so idle gaps aren't bridged).
- **Configurable retention** (`config.psd1`, edit with `pingconfig`) — prune the
  log by last-N-runs, by age in days, both, either, or never; plus a bound on
  how many timestamped report snapshots are kept.
- **Ctrl+C handling** — a continuous `ping -t` stopped with Ctrl+C still prints
  and logs its final statistics block, and ping's literal "Control-C" line is
  suppressed for a clean stock-ping look.
- **Easy install** — one-line web installer (`get.ps1`) or clone + `Install.ps1`
  (`-NoShadow` / `-Uninstall` supported). Location-independent.
