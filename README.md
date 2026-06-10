# ping+

**Log Windows `ping` results to a file and chart packet loss & latency over
time.** ping+ wraps the built-in Windows `ping` command so it works exactly as
before, but silently **timestamps and logs every reply, timeout and DNS error**
to a file — then turns that history into a local HTML report with a **latency
graph**, an **availability strip**, and explicit **outage windows** ("between
*these* timestamps every ping failed").

It answers the question stock ping can't: *how often does my connection
actually drop, when, and for how long?*

Nothing replaces `C:\Windows\System32\PING.EXE`. ping+ is a thin PowerShell
wrapper that calls the real binary by absolute path. Removing ping+ leaves your
system exactly as it was.

- **No dependencies** — pure PowerShell + inline SVG. No internet, no JS
  libraries, no modules to install.
- **Non-destructive** — never touches the real ping; install is just a profile
  edit, fully reversible.

### Good for

- Catching **intermittent internet drops** that stock ping forgets the moment
  it exits.
- Seeing **packet loss and latency trends** over minutes, hours, or days.
- Keeping a **persistent ping history** across reboots and sessions.
- Diagnosing flaky Wi-Fi, VPN, or DNS without leaving the terminal.

### Requirements

Windows · PowerShell 5.1 or 7+ · English-language ping output. No admin needed.

---

## Install

### One-liner (easiest)

```powershell
irm https://raw.githubusercontent.com/Feenixu/ping-plus/master/get.ps1 | iex
```

This downloads ping+ to `%LOCALAPPDATA%\ping-plus` and wires it into your
PowerShell profile. Then open a new terminal (or run `. $PROFILE`).

### Or clone it yourself (anywhere)

```powershell
git clone https://github.com/Feenixu/ping-plus.git
pwsh -File .\ping-plus\Install.ps1   # or: powershell -File ...
. $PROFILE                            # then reload, or open a new terminal
```

Either way, `Install.ps1` adds a small, clearly-tagged block to your PowerShell
profile that:

- imports the module,
- defines a `ping` function that **shadows** the built-in ping in interactive
  PowerShell only (functions win over `.exe`), and
- adds the aliases `pingplus`, `ping+`, `pingreport`, `pingstats`, `pingconfig`,
  `pingclean`.

Don't want to shadow `ping`? Install with `-NoShadow` and just use `pingplus`.

To remove everything: `pwsh -File <install-dir>\Install.ps1 -Uninstall`
(the profile block is tagged, so uninstall is clean).

> ⚠️ If `pwsh` (PowerShell 7) isn't installed, use `powershell` instead — the
> tool works on Windows PowerShell 5.1 too. If you get an execution-policy
> error, run once:
> `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned`.

---

## Use

Exactly like ping — every normal flag passes straight through:

```powershell
ping google.com            # 4 pings, logged
ping -t 8.8.8.8            # continuous; Ctrl+C any time, nothing is lost
ping -n 100 1.1.1.1        # 100 pings
pingplus github.com        # if you didn't shadow `ping`
```

The on-screen output is **identical to stock ping** — same live reply lines,
same final sent/received/lost summary, nothing reformatted. All the logging and
analysis happens silently in the background. The only addition is **one extra
line at the very end: a clickable link to the report** for that run. In Windows
Terminal / VS Code it shows as a tidy "View ping+ report" hyperlink (OSC 8); in
other terminals it prints the plain `file://` URL, which stays Ctrl+click-able.

### See the report

Every run already prints a link, but you can also open it on demand:

```powershell
pingreport                 # builds + opens reports\report.html, then launches it
pingreport -Target 8.8.8.8 # just one host
pingreport -AllHistory     # include every past session, not just the latest
pingreport -Last 500       # only the most recent 500 records
pingreport -NoOpen         # build but don't launch the browser
```

**Sessions:** by default the report shows only each host's **most recent
session** (one `ping …` run). So re-pinging the same target doesn't visually
merge separate runs into one. To see the full long-term picture across every
session — useful for "how often does this connection drop over days?" — add
**`-AllHistory`**; the latency graph then draws each session as its own line
(no misleading diagonal bridging the idle gaps between runs).

The report (per host) shows:

- **Cards:** total pings, **elapsed time**, OK, dropped, loss %, avg / min /
  max / p50 / p95 latency, number of outages.
- **Latency graph:** inline SVG line chart over real time; red ticks mark drops.
- **Availability strip:** one bar per ping, green = reply, red = drop, oldest →
  newest — instantly shows clustering of failures.
- **Outage table:** each contiguous run of failures with its start/end
  timestamp, duration, number of failed pings, and failure type. This is the
  "between these timestamps all pings failed" view.

### Quick terminal stats (no browser)

```powershell
pingstats
pingstats -Target google.com -Last 1000
```

### Updates

ping+ checks GitHub for a newer version at most once a day, in the background,
and prints a single quiet line after a ping run if one is available. The check
is fail-silent — offline or any error just skips it, nothing blocks your ping.
To check on demand:

```powershell
pingupdate          # check now and show how to update
```

Updating is just re-running the installer (`irm …/get.ps1 | iex`) or, for a
clone, `git -C <install-dir> pull`.

---

## Configuration & log retention

So the log can't grow forever, ping+ prunes old data automatically based on a
small, self-documented config file named **`config.psd1`** in the install
folder. It's created on first use; open it any time with:

```powershell
pingconfig          # opens config.psd1 in $EDITOR / VS Code / Notepad
```

Default contents:

```powershell
@{
    RetentionMode = 'both'   # 'runs' | 'days' | 'both' | 'either' | 'none'
    KeepRuns      = 50       # keep only the last N ping runs
    KeepDays      = 30       # delete records older than N days
    ApplyOn       = 'finish' # 'start' | 'finish' | 'both'
    KeepReports   = 10       # how many timestamped HTML report snapshots to keep
}
```

| Option | Meaning |
|---|---|
| `RetentionMode` | Which strategy to apply (see below). |
| `KeepRuns` | Keep only the last **N runs**. One "run" = one `ping …` command you ran. `0` = no run limit. |
| `KeepDays` | Delete records older than **N days**. `0` = no age limit. |
| `ApplyOn` | When cleanup runs automatically: when a ping `start`s, when it `finish`es, or `both`. |
| `KeepReports` | How many dated report snapshots (`report-*.html`) to keep. The latest `report.html` is always kept. `0` = keep only the latest. |

**RetentionMode values**

- `runs` — keep only the last `KeepRuns` runs, delete older runs.
- `days` — keep only records from the last `KeepDays` days.
- `both` — keep a record only if it passes **both** limits (bounds size *and* age). *(default)*
- `either` — keep a record if it passes **either** limit (most lenient).
- `none` — never delete anything.

Cleanup happens silently in the background. You can also trigger it on demand:

```powershell
pingclean                 # apply the current policy right now
pingclean -Verbose        # ...and report how many records were kept
Get-PingPlusConfig        # show the effective (validated) settings
```

Bad or missing values fall back to the defaults, so a typo in the config can
never accidentally wipe your history. Each log record is tagged with a `run` id,
which is what makes "keep last N runs" possible.

---

## Where things live

```
<install-dir>\
  PingPlus.psm1            the wrapper + report engine
  PingPlus.psd1            module manifest (version/metadata)
  Install.ps1              profile wiring (install / -NoShadow / -Uninstall)
  get.ps1                  one-line web installer
  config.psd1              retention settings (edit with `pingconfig`; not tracked)
  README.md                this file
  LICENSE                  MIT
  CHANGELOG.md             version history
  logs\ping-log.jsonl      append-only history (one JSON object per event)
  reports\report.html      latest report (+ bounded timestamped snapshots)
```

(`<install-dir>` is wherever you cloned it, or `%LOCALAPPDATA%\ping-plus` if you
used the one-liner.)

### The log format (JSONL)

One JSON object per line, e.g.:

```json
{"ts":"2026-05-31T14:03:01.1234567-07:00","run":"20260531140301123-9af2","target":"google.com","ip":"142.250.80.46","status":"ok","latency_ms":14,"sub_ms":false,"raw":"Reply from 142.250.80.46: bytes=32 time=14ms TTL=117"}
{"ts":"2026-05-31T14:03:02.2345678-07:00","run":"20260531140301123-9af2","target":"google.com","ip":null,"status":"timeout","latency_ms":null,"sub_ms":false,"raw":"Request timed out."}
```

`run` groups records from the same `ping` invocation (used by the
"keep last N runs" retention policy).

`status` is one of `ok`, `timeout`, `unreachable`, `dns_error`, `error`.
Because it's plain JSONL you can also analyze it with anything (Excel via
import, `jq`, Python, etc.). The file grows over time; delete it to reset, or
trim it if it gets large.

---

## Notes & caveats

- Parsing assumes **English-language** Windows ping output. Other display
  languages would need the regexes in `Invoke-PingPlus` adjusted.
- `time<1ms` replies are logged as `latency_ms` = 1 with `sub_ms` = true.
- The report uses **pure inline SVG** — no internet, no JS libraries, fully
  offline and self-contained.
