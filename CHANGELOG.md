# Changelog

All notable changes to ping+ are documented here.
This project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.1] - 2026-06-11

Hardens concurrent logging, fixes two display/usage bugs found after the first
release, and adds a lightweight update check. Fully backward compatible.

### Added
- **Update check** — `pingupdate` checks GitHub for a newer version, and a ping
  run prints one quiet line if an update is available. Cached to at most once
  per 24h and fully fail-silent (offline/error → does nothing). Requires no
  hosting; reads the version published in the repo.

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
