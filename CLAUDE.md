# ping+ - project guidance

## HARD REQUIREMENT: pure ASCII source files

Every PowerShell source file in this repo (`*.ps1`, `*.psd1`, `*.psm1`) MUST
contain only ASCII bytes (0x00-0x7F) and MUST NOT have a BOM. This is enforced
by an ASCII guard at the top of `Test-PingPlus.ps1` - run it before committing.

Why (both failure modes shipped in real releases):

- **No BOM allowed:** `get.ps1` is consumed via `irm ... | iex`. A UTF-8 BOM
  arrives as a literal U+FEFF character in the downloaded string, `iex` then
  fails to tokenize the opening `<#`, and the parser reports nonsense errors
  inside the header comment (broke the public installer in v1.1.2).
- **No non-ASCII allowed:** without a BOM, Windows PowerShell 5.1 decodes
  files from disk as ANSI. A UTF-8 em dash (U+2014) inside a double-quoted
  string decodes as `a-hat euro "` where the final byte becomes a smart quote
  (U+201D) - which PS treats as a string TERMINATOR, breaking the parse
  (latent in `get.ps1` from day one, found in the v1.1.2 review).
- Pure ASCII with no BOM is the only encoding that parses identically under
  every decode path: PS 5.1 ANSI, PS 5.1/7 UTF-8, and `iex` on a string.

Practical rules: use `-` instead of em dashes; if non-ASCII output is ever
genuinely needed, build it at runtime with `[char]0xNNNN` so the source stays
ASCII. Markdown files (README/CHANGELOG) are exempt - they are never parsed
by PowerShell.

## Compatibility

Target Windows PowerShell 5.1 AND PowerShell 7. No PS7-only syntax: no
ternary, no `??`, no `&&`/`||` pipeline chains, no `-LiteralPath` on cmdlets
that lack it in 5.1 (e.g. `Import-PowerShellDataFile`).

## Release process

1. Bump `ModuleVersion` in `PingPlus.psd1` (runtime single source of truth).
2. Keep in sync by hand: the fallback literal `$script:PingPlusVersion` and
   the header comment version in `PingPlus.psm1`.
3. Add a CHANGELOG entry; commit as `Release vX.Y.Z: <summary>`.
4. Run `Test-PingPlus.ps1` (includes the ASCII guard) before pushing.
5. After pushing, `raw.githubusercontent.com` caches for ~5 minutes - the
   update check (`pingupdate`) reads master's `PingPlus.psd1` from there.

## Things that bite

- Profile-block changes only reach users when `Install.ps1` re-runs; module
  file updates alone (e.g. plain `git pull`) never refresh the block.
- On the dev machine the install lives at `C:\ping+` - refresh the profile
  with `powershell -File C:\ping+\Install.ps1`, NOT the `irm | iex` one-liner
  (that would create a second install in `%LOCALAPPDATA%\ping-plus` and
  repoint the profile at it).
- The dev machine's PowerShell profile is OneDrive-synced; `Install.ps1`
  rewrites it. Treat profile changes with care.
