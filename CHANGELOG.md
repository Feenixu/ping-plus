# Changelog

All notable changes to ping+ are documented here.
This project adheres to [Semantic Versioning](https://semver.org/).

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
