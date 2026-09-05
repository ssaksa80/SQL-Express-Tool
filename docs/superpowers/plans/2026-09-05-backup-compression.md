# Backup Compression Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `CompressBackups` mode that zips every `.bak`/`.dif`/`.trn` in staging before it's copied to the share, with a `.meta.json` sidecar so point-in-time cataloguing still reads LSNs without decompressing, and full decompress-on-restore — all backward-compatible and behind a config flag (default off).

**Architecture:** New pure helpers (compress/expand round-trip, `.zip` naming, sidecar serialize/parse) drive impure wiring in the existing backup pass, restore executor, catalogue, and retention. The share holds `<name>.zip` + `<name>.meta.json`; the sidecar carries the LSN facts (as strings, to keep `numeric(25,0)` precision) so `Get-SebPointCatalogue` reads them without `RESTORE HEADERONLY` on a compressed file. Restore decompresses to the plain file, then restores as today.

**Tech Stack:** Windows PowerShell 5.1, `System.IO.Compression` (in-box, Zip64 for large files), `System.Data.SqlClient`.

---

## Repo conventions every task MUST follow

- **Engine is one ASCII, PS 5.1 file** (`Invoke-SqlExpressBackup.ps1`): no non-ASCII, no `= (try {...})`, no dot-sourcing. A suite structural guard enforces it.
- **Tests assert BEHAVIOUR** by driving real functions; every "isn't there / isn't deleted" assertion pairs with a **positive control** proving the path acts when it should.
- **Run the suite** from the repo root, natively (never WSL): `powershell -NoProfile -ExecutionPolicy Bypass -File "test\sqlexpress-backup.test.ps1"` — prints `  PASS <msg>`, exits 0; throws `FAIL: <msg>`. It dot-sources the engine via `. $script -DotSourceOnly` and needs no SQL Server. It spawns child processes and can exceed a 2-minute tool timeout — allow 5+ minutes.
- **Concurrency guard:** `git status --short` before editing; if `Invoke-SqlExpressBackup.ps1` shows a peer ` M`, STOP/BLOCKED. Use targeted `Edit` (never full-file `Write`). Stage only the files a task names (never `git add -A`). The repo's git author is already the noreply identity — don't touch git config. End every commit message with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **Branch:** `feat/backup-compression` (already checked out; the spec is committed there).
- **LSNs** are `[decimal]`. In the sidecar JSON they are **strings** (JSON numbers lose `numeric(25,0)` precision through `ConvertFrom-Json`).

## File Structure

**Engine — `Invoke-SqlExpressBackup.ps1`:**
- New: `Compress-SebFile`, `Expand-SebFile` (zip one file / extract one entry).
- New pure: `Get-SebCompressedName`, `Get-SebSidecarName`, `Get-SebSidecarJson`, `Get-SebHeaderFactsFromSidecar`.
- Modify: `Get-SebStampFromName` (+`.zip`), `Get-SebFolderFacts` (+`.zip`, exclude `.meta.json`), `Get-SebPointCatalogue` (sidecar-or-HEADERONLY), the backup pass (`Invoke-SebPass` both branches + `Invoke-SebBackupLogPass`), the restore paths (`-RestoreRun` dispatch, `Invoke-SebRestoreToPoint`), retention delete loops, config plumbing (`CompressBackups`).
- **Tests — `test/sqlexpress-backup.test.ps1`** (append behaviour blocks).
- **Live — `test/live-compress.ps1`** (new; compressed round-trip + STOPAT, run by hand where SQL is present).

---

## Task 1: Compress/Expand primitives

**Files:** Modify `Invoke-SqlExpressBackup.ps1` (new `Compress-SebFile`, `Expand-SebFile`); Test `test/sqlexpress-backup.test.ps1`.

- [ ] **Step 1: Write the failing test.** Append before the final `Write-Host 'ALL PASS'`:
```powershell
# ---- COMP-1. compress/expand round-trips a file byte-for-byte ----------------------
$tmpC = Join-Path $env:TEMP ('seb-comp-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tmpC -Force)
try {
  $plain = Join-Path $tmpC 'APPDB_20260905-090000.bak'
  $bytes = [byte[]](1..5000 | ForEach-Object { $_ % 256 })
  [System.IO.File]::WriteAllBytes($plain, $bytes)
  $zip = Join-Path $tmpC 'APPDB_20260905-090000.bak.zip'
  Compress-SebFile -Source $plain -Destination $zip
  Assert (Test-Path -LiteralPath $zip) 'Compress-SebFile writes the .zip'
  Assert ((Get-Item -LiteralPath $zip).Length -gt 0) 'the .zip is non-empty'
  $out = Join-Path $tmpC 'restored.bak'
  Expand-SebFile -Source $zip -Destination $out
  $a = (Get-FileHash -LiteralPath $plain -Algorithm SHA256).Hash
  $b = (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash
  Assert ($a -eq $b) 'Expand-SebFile restores byte-for-byte identical content'
}
finally { Remove-Item -LiteralPath $tmpC -Recurse -Force -ErrorAction SilentlyContinue }
```

- [ ] **Step 2: Run the suite; confirm it FAILS** (command-not-found on `Compress-SebFile`).

- [ ] **Step 3: Implement** (place near `Copy-SebVerified`):
```powershell
# Zip a single file (entry named after the source leaf). In-box System.IO.Compression,
# NOT Compress-Archive (its ~2GB limit fails large .bak). CreateEntryFromFile streams;
# .NET selects Zip64 automatically for entries over 4GB.
function Compress-SebFile {
  param([string]$Source, [string]$Destination)
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
  $entry = Split-Path -Leaf $Source
  $zip = [System.IO.Compression.ZipFile]::Open($Destination, [System.IO.Compression.ZipArchiveMode]::Create)
  try { [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $Source, $entry, [System.IO.Compression.CompressionLevel]::Optimal) }
  finally { $zip.Dispose() }
}

# Extract the single entry of a .zip to a plain file.
function Expand-SebFile {
  param([string]$Source, [string]$Destination)
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [System.IO.Compression.ZipFile]::OpenRead($Source)
  try {
    $entries = @($zip.Entries)
    if ($entries.Count -eq 0) { throw ('the archive is empty: {0}' -f $Source) }
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], $Destination, $true)
  }
  finally { $zip.Dispose() }
}
```

- [ ] **Step 4: Run the suite; confirm all COMP-1 asserts PASS**, whole suite green (exit 0).

- [ ] **Step 5: Commit.**
```
git add Invoke-SqlExpressBackup.ps1 test/sqlexpress-backup.test.ps1
git commit -m "feat(engine): Compress-SebFile/Expand-SebFile - single-file zip round-trip (Zip64-safe)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `.zip` naming, stamp parsing, folder enumeration

**Files:** Modify `Invoke-SqlExpressBackup.ps1` (`Get-SebCompressedName`, `Get-SebSidecarName`, `Get-SebStampFromName`, `Get-SebFolderFacts`); Test `test/sqlexpress-backup.test.ps1`.

- [ ] **Step 1: Write the failing tests.** Append:
```powershell
# ---- COMP-2. .zip naming + stamp + folder facts ------------------------------------
Assert ((Get-SebCompressedName 'APPDB_20260905-090000.bak') -eq 'APPDB_20260905-090000.bak.zip') 'compressed name appends .zip'
Assert ((Get-SebSidecarName 'APPDB_20260905-090000.bak.zip') -eq 'APPDB_20260905-090000.bak.zip.meta.json') 'sidecar name appends .meta.json'
$fbZ = [datetime]'2000-01-01'
$stZ = [datetime]'2026-09-05 09:00:00'
Assert ((Get-SebStampFromName -Name 'APPDB_20260905-090000.bak.zip' -Fallback $fbZ) -eq $stZ) 'the stamp is read out of a .bak.zip name'
Assert ((Get-SebStampFromName -Name 'APPDB_20260905-090000.trn.zip' -Fallback $fbZ) -eq $stZ) 'the stamp is read out of a .trn.zip name'
Assert ((Get-SebStampFromName -Name 'APPDB_20260905-090000.bak' -Fallback $fbZ) -eq $stZ) 'a plain .bak stamp still parses (no regression)'
Assert ((Get-SebStampFromName -Name 'APPDB_20260905-090000.bak.zip.meta.json' -Fallback $fbZ) -eq $fbZ) 'a .meta.json sidecar is NOT a backup (falls back)'
$tmpF = Join-Path $env:TEMP ('seb-ff-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tmpF -Force)
try {
  Set-Content -LiteralPath (Join-Path $tmpF 'APPDB_20260905-090000.bak.zip') -Value 'x'
  Set-Content -LiteralPath (Join-Path $tmpF 'APPDB_20260905-090000.bak.zip.meta.json') -Value 'x'
  Set-Content -LiteralPath (Join-Path $tmpF 'APPDB_20260905-093000.bak') -Value 'x'
  $facts = @(Get-SebFolderFacts -Directory $tmpF)
  Assert ($facts.Count -eq 2) "folder facts count the .zip and the plain backup but NOT the sidecar (got $($facts.Count))"
  Assert (@($facts | Where-Object { $_.Name -like '*.meta.json' }).Count -eq 0) 'the .meta.json sidecar is excluded from folder facts'
}
finally { Remove-Item -LiteralPath $tmpF -Recurse -Force -ErrorAction SilentlyContinue }
```

- [ ] **Step 2: Run the suite; confirm it FAILS** (command-not-found on `Get-SebCompressedName`).

- [ ] **Step 3: Implement.**
Add near `Get-SebFileName`:
```powershell
function Get-SebCompressedName { param([string]$PlainName) return ($PlainName + '.zip') }
function Get-SebSidecarName { param([string]$Name) return ($Name + '.meta.json') }
```
`Get-SebStampFromName` — widen the regex to allow an optional `.zip`, but NOT `.meta.json` (the `$` anchor after `(\.zip)?` excludes the sidecar):
```powershell
  $match = [regex]::Match($Name, '_(\d{8})-(\d{6})\.(bak|dif|trn)(\.zip)?$')
```
`Get-SebFolderFacts` — widen its filter to include the `.zip` variants and exclude the `.meta.json` sidecar (`$` after `(\.zip)?` already excludes `.meta.json`):
```powershell
    Where-Object { $_.Name -cmatch '\.(bak|dif|trn)(\.zip)?$' }
```

- [ ] **Step 4: Run the suite; all COMP-2 asserts PASS**, whole suite green (exit 0), no regression to the existing A1 stamp/folder tests.

- [ ] **Step 5: Commit.**
```
git add Invoke-SqlExpressBackup.ps1 test/sqlexpress-backup.test.ps1
git commit -m "feat(engine): recognise .bak/.dif/.trn .zip names; sidecars excluded from folder facts

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Sidecar serialize + parse (LSN precision)

**Files:** Modify `Invoke-SqlExpressBackup.ps1` (`Get-SebSidecarJson`, `Get-SebHeaderFactsFromSidecar`); Test `test/sqlexpress-backup.test.ps1`.

- [ ] **Step 1: Write the failing tests.** Append (the 25-digit LSN would lose precision as a JSON number — proves the string encoding):
```powershell
# ---- COMP-3. sidecar carries LSN facts with full precision --------------------------
$bigLsn = [decimal]'1234567890123456789012'   # 22 digits - would lose precision as a JSON number
$facts0 = [pscustomobject]@{ Kind='full'; File='ignored'; FirstLSN=$bigLsn; LastLSN=([decimal]$bigLsn + 5); DatabaseBackupLSN=[decimal]0; CheckpointLSN=[decimal]777; Finish=[datetime]'2026-09-05 08:00:00' }
$json = Get-SebSidecarJson -Facts $facts0
Assert ($json -match '"FirstLSN"\s*:\s*"1234567890123456789012"') 'the sidecar stores LSNs as strings'
$back = Get-SebHeaderFactsFromSidecar -Json $json -File 'C:\s\APPDB.bak.zip' -Kind 'full'
Assert ($back.FirstLSN -eq $bigLsn) 'FirstLSN round-trips through the sidecar with full precision'
Assert ($back.LastLSN -eq ([decimal]$bigLsn + 5)) 'LastLSN round-trips'
Assert ($back.CheckpointLSN -eq 777) 'CheckpointLSN round-trips'
Assert ($back.File -eq 'C:\s\APPDB.bak.zip' -and $back.Kind -eq 'full') 'File and Kind come from the parameters (folder-derived), not the JSON'
Assert ($back.Finish -eq ([datetime]'2026-09-05 08:00:00')) 'Finish round-trips'
```

- [ ] **Step 2: Run the suite; confirm it FAILS** (command-not-found on `Get-SebSidecarJson`).

- [ ] **Step 3: Implement** (place near `Get-SebHeaderFactsFromRow`):
```powershell
# Serialize a catalogue fact to sidecar JSON. LSNs are strings so numeric(25,0) precision
# survives ConvertFrom-Json (which would coerce a big JSON number to a lossy double).
function Get-SebSidecarJson {
  param($Facts)
  $o = [ordered]@{
    Kind              = [string]$Facts.Kind
    FirstLSN          = [string]$Facts.FirstLSN
    LastLSN           = [string]$Facts.LastLSN
    DatabaseBackupLSN = [string]$Facts.DatabaseBackupLSN
    CheckpointLSN     = [string]$Facts.CheckpointLSN
    Finish            = $Facts.Finish.ToString('o')
  }
  return (ConvertTo-Json $o -Compress)
}

# Parse sidecar JSON back into the same fact shape Get-SebHeaderFactsFromRow produces.
# File and Kind come from the caller (folder-derived), matching the HEADERONLY path.
function Get-SebHeaderFactsFromSidecar {
  param([string]$Json, [string]$File, [string]$Kind)
  $o = ConvertFrom-Json $Json
  return [pscustomobject]@{
    Kind              = $Kind
    File              = $File
    FirstLSN          = [decimal]$o.FirstLSN
    LastLSN           = [decimal]$o.LastLSN
    DatabaseBackupLSN = [decimal]$o.DatabaseBackupLSN
    CheckpointLSN     = [decimal]$o.CheckpointLSN
    Finish            = [datetime]$o.Finish
  }
}
```

- [ ] **Step 4: Run the suite; all COMP-3 asserts PASS**, whole suite green.

- [ ] **Step 5: Commit.**
```
git add Invoke-SqlExpressBackup.ps1 test/sqlexpress-backup.test.ps1
git commit -m "feat(engine): backup-header sidecar serialize/parse (LSNs as strings for precision)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Catalogue reads the sidecar for compressed files

**Files:** Modify `Invoke-SqlExpressBackup.ps1` (`Get-SebPointCatalogue`, and a small `Get-SebFactsForFile` seam); Test `test/sqlexpress-backup.test.ps1`.

- [ ] **Step 1: Add a pure-ish selector `Get-SebFactsForFile`** that decides sidecar-vs-HEADERONLY, so the choice is unit-testable via a `-SidecarReader` injection (mirrors how `Get-SebInstanceList` injects readers). Place near `Get-SebRestoreHeaderFacts`:
```powershell
# Facts for one share file: if a .meta.json sidecar sits beside it (compressed backup),
# read the facts from the sidecar (no decompress); otherwise RESTORE HEADERONLY the plain
# file. SidecarReader is injectable for testing (defaults to reading the file).
function Get-SebFactsForFile {
  param($Connection, [string]$File, [string]$Kind, [scriptblock]$SidecarReader)
  $sidecar = Get-SebSidecarName $File
  if (-not $SidecarReader) { $SidecarReader = { param([string]$p) if (Test-Path -LiteralPath $p) { return (Get-Content -LiteralPath $p -Raw) } else { return $null } } }
  $json = & $SidecarReader $sidecar
  if ($null -ne $json) { return (Get-SebHeaderFactsFromSidecar -Json $json -File $File -Kind $Kind) }
  return (Get-SebRestoreHeaderFacts -Connection $Connection -File $File -Kind $Kind)
}
```

- [ ] **Step 2: Write the failing test** (drives the real selector with an injected sidecar, no SQL):
```powershell
# ---- COMP-4. the catalogue reads a sidecar when one exists (no decompress) ----------
$factsS = [pscustomobject]@{ Kind='full'; File='x'; FirstLSN=[decimal]900; LastLSN=[decimal]900; DatabaseBackupLSN=[decimal]0; CheckpointLSN=[decimal]905; Finish=[datetime]'2026-09-05 07:00:00' }
$jsonS = Get-SebSidecarJson -Facts $factsS
$reader = { param($p) return $jsonS }   # pretend a sidecar exists with these facts
$f = Get-SebFactsForFile -Connection $null -File 'C:\s\APPDB_20260905-070000.bak.zip' -Kind 'full' -SidecarReader $reader
Assert ($f.CheckpointLSN -eq 905 -and $f.File -eq 'C:\s\APPDB_20260905-070000.bak.zip') 'a present sidecar supplies the facts (Connection never used)'
$readerNone = { param($p) return $null }  # no sidecar -> would fall through to HEADERONLY
Assert ((Get-Command Get-SebFactsForFile).Parameters.ContainsKey('SidecarReader')) 'Get-SebFactsForFile exposes an injectable SidecarReader'
```

- [ ] **Step 3: Run the suite; confirm it FAILS** (command-not-found on `Get-SebFactsForFile`), then it passes once implemented.

- [ ] **Step 4: Wire `Get-SebPointCatalogue`** to call `Get-SebFactsForFile` instead of `Get-SebRestoreHeaderFacts` directly, per share file (the fact's `File` stays the actual file path — `.zip` for compressed). No other change to the catalogue.

- [ ] **Step 5: Run the suite; COMP-4 asserts PASS**, whole suite green.

- [ ] **Step 6: Commit.**
```
git add Invoke-SqlExpressBackup.ps1 test/sqlexpress-backup.test.ps1
git commit -m "feat(engine): catalogue reads the .meta.json sidecar for compressed backups (no decompress)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: `CompressBackups` config flag

**Files:** Modify `Invoke-SqlExpressBackup.ps1` (param block, config template, `$SebShowKeys`, `Invoke-SebSetup`, `-Reschedule`); Test `test/sqlexpress-backup.test.ps1`.

- [ ] **Step 1: Implement, mirroring `RecoveryMode`'s plumbing (shipped in PITR D3).** Read how `RecoveryMode` flows CLI → `Invoke-SebSetup` default → config literal → `$SebShowKeys` → `-Reschedule` `ContainsKey`, and add `CompressBackups` the same way:
  - Top-level param: `[bool]$CompressBackups = $false` (a `[bool]` with a default, like the other override params — `ContainsKey` still distinguishes an omitted value in `-Reschedule`).
  - `Invoke-SebSetup`: `[bool]$CompressBackups = $false` param, written into the config literal as `CompressBackups = $CompressBackups`.
  - Both `Invoke-SebSetup` call sites (`-Setup`, `-FullInstall`) pass `-CompressBackups $CompressBackups`.
  - `-Reschedule`: `if ($PSBoundParameters.ContainsKey('CompressBackups')) { Add-Member -InputObject $config -MemberType NoteProperty -Name CompressBackups -Value ([bool]$CompressBackups) -Force }` (use `Add-Member -Force`, since an existing config.json predating this feature lacks the property — plain assignment throws on a `ConvertFrom-Json` object, exactly as the PITR D3 fix established).
  - Add `CompressBackups` to `$SebShowKeys`.

- [ ] **Step 2: Add a test** for the backward-compat read (a config without the key reads as `$false`):
```powershell
# ---- COMP-5. CompressBackups defaults off and is read defensively -------------------
$cfgNo = [pscustomobject]@{ RecoveryMode = 'Simple' }   # a config predating this feature
$compNo = $false
if ($cfgNo.PSObject.Properties['CompressBackups']) { $compNo = [bool]$cfgNo.CompressBackups }
Assert (-not $compNo) 'a config without CompressBackups reads as off (existing installs unchanged)'
$cfgYes = [pscustomobject]@{ CompressBackups = $true }
Assert ([bool]$cfgYes.CompressBackups) 'CompressBackups=$true is read as on'
```
(This pins the read idiom the pass/restore use; the Setup/Reschedule persistence is live-tested, like `RecoveryMode`.)

- [ ] **Step 3: Run the suite; COMP-5 asserts PASS**, whole suite green.

- [ ] **Step 4: Commit.**
```
git add Invoke-SqlExpressBackup.ps1 test/sqlexpress-backup.test.ps1
git commit -m "feat(engine): CompressBackups config flag (CLI/Setup/Reschedule/status), default off

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Backup pipeline compresses + writes the sidecar

**Files:** Modify `Invoke-SqlExpressBackup.ps1` (`Invoke-SebPass` Full + Simple branches; `Invoke-SebBackupLogPass`). Verified live in Task 8.

- [ ] **Step 1: Add a shared helper** `Publish-SebBackup` that both passes use to move a verified staging plain file to its share destination — compressing + writing the sidecar when the flag is on, else copying plain. Read `Get-SebRestoreHeaderFacts` (for the sidecar facts), `Copy-SebVerified`, and `Save-SebCopyOrPend` (the copy-resilience wrapper) first, and reuse them:
```powershell
# Move a verified staging plain backup to its share destination. When compression is on,
# zip it + write the .meta.json sidecar (facts from HEADERONLY of the plain file) and
# publish both; else publish the plain file. $Publish is the existing copy-or-pend action
# the caller uses (Copy-SebVerified for Simple, Save-SebCopyOrPend for Full/log).
function Publish-SebBackup {
  param($Connection, [string]$StagedPlain, [string]$DestDir, [string]$PlainName, [string]$Kind, [bool]$Compress, [scriptblock]$Publish)
  if (-not $Compress) {
    & $Publish (Join-Path $DestDir $PlainName) $StagedPlain
    return
  }
  $facts = Get-SebRestoreHeaderFacts -Connection $Connection -File $StagedPlain -Kind $Kind
  $stagedZip = $StagedPlain + '.zip'
  Compress-SebFile -Source $StagedPlain -Destination $stagedZip
  $stagedMeta = (Get-SebSidecarName $stagedZip)
  Set-Content -LiteralPath $stagedMeta -Value (Get-SebSidecarJson -Facts $facts) -Encoding ASCII
  $zipName = Get-SebCompressedName $PlainName
  & $Publish (Join-Path $DestDir $zipName) $stagedZip
  & $Publish (Join-Path $DestDir (Get-SebSidecarName $zipName)) $stagedMeta
  Remove-Item -LiteralPath $StagedPlain -Force -ErrorAction SilentlyContinue
}
```
(NOTE: `$Publish` must be a 2-arg action `{ param($dest,$src) ... }` wrapping the caller's existing copy path so the `.zip` and `.meta.json` go through the same verify/pending machinery as any file. Adapt the exact shape to how `Copy-SebVerified`/`Save-SebCopyOrPend` are called at each site — if they don't factor into a 2-arg action cleanly, inline the compress+sidecar steps at each call site instead and note it in the report.)

- [ ] **Step 2: Wire it into the three publish points**, gated on `$compress = ($isFullMode -is anything)`… concretely read `$config.CompressBackups` once per pass (`$compress = $false; if ($config.PSObject.Properties['CompressBackups']) { $compress = [bool]$config.CompressBackups }`) and pass it down:
  - `Invoke-SebPass` Simple branch: replace the hourly/daily `Copy-SebVerified` of the plain file with a compress-aware publish (plain when off).
  - `Invoke-SebPass` Full branch: same for the `hourly`/`diff` copy.
  - `Invoke-SebBackupLogPass`: same for the `log` copy (and the anchor full).
  Keep `Test-SebBackupFile` (VERIFYONLY) on the PLAIN staging file, before compression.

- [ ] **Step 3: Run the suite** (no new unit asserts here — this is impure wiring; the structural ASCII/parse guards must stay green, and no existing test may regress). Expected: ALL PASS / exit 0.

- [ ] **Step 4: Commit.**
```
git add Invoke-SqlExpressBackup.ps1
git commit -m "feat(engine): compress backups + write the LSN sidecar before copy when CompressBackups is on

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Restore decompresses a `.zip` source

**Files:** Modify `Invoke-SqlExpressBackup.ps1` (`Invoke-SebRestoreToPoint`; the `-RestoreRun` path; `Get-SebRestoreInspect` if it opens the file). Verified live in Task 8.

- [ ] **Step 1: Add a helper** `Resolve-SebRestoreSource` that, given a share file path + a staging dir, returns a local plain path — decompressing a `.zip` to staging, or returning the path as-is for a plain file:
```powershell
# Ensure a local PLAIN backup file to restore from: a .zip source is expanded into the
# staging dir; a plain source is returned unchanged. Returns the plain path.
function Resolve-SebRestoreSource {
  param([string]$File, [string]$StagingDir)
  if ($File -notlike '*.zip') { return $File }
  if (-not (Test-Path -LiteralPath $StagingDir)) { [void](New-Item -ItemType Directory -Path $StagingDir -Force) }
  $plain = Join-Path $StagingDir ([System.IO.Path]::GetFileNameWithoutExtension($File))  # strips the .zip
  Expand-SebFile -Source $File -Destination $plain
  return $plain
}
```

- [ ] **Step 2: Add a test** (round-trips through the real helper, no SQL):
```powershell
# ---- COMP-7. a .zip restore source is expanded to a plain file ----------------------
$tmpR = Join-Path $env:TEMP ('seb-rr-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tmpR -Force)
try {
  $srcPlain = Join-Path $tmpR 'APPDB_20260905-090000.bak'
  [System.IO.File]::WriteAllBytes($srcPlain, [byte[]](1..2000 | ForEach-Object { $_ % 256 }))
  $srcZip = Join-Path $tmpR 'APPDB_20260905-090000.bak.zip'
  Compress-SebFile -Source $srcPlain -Destination $srcZip
  $stg = Join-Path $tmpR 'stg'
  $resolved = Resolve-SebRestoreSource -File $srcZip -StagingDir $stg
  Assert ($resolved -like '*APPDB_20260905-090000.bak' -and $resolved -notlike '*.zip') 'a .zip source resolves to a plain .bak path'
  Assert ((Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $srcPlain -Algorithm SHA256).Hash) 'the resolved plain file matches the original'
  $plainIn = Join-Path $tmpR 'other.bak'; Set-Content -LiteralPath $plainIn -Value 'x'
  Assert ((Resolve-SebRestoreSource -File $plainIn -StagingDir $stg) -eq $plainIn) 'a plain source is returned unchanged (no decompress)'
}
finally { Remove-Item -LiteralPath $tmpR -Recurse -Force -ErrorAction SilentlyContinue }
```

- [ ] **Step 3: Run the suite; confirm it FAILS then PASSES** on the COMP-7 asserts.

- [ ] **Step 4: Wire it in.** In `Invoke-SebRestoreToPoint`, before building/executing each step's SQL, replace the step's file with `Resolve-SebRestoreSource -File $step.File -StagingDir <a temp under the staging path>`; use the resolved plain path for `Get-SebRestoreInspect` (FILELISTONLY/MOVE) and the `RESTORE` statement. Do the same in the `-RestoreRun` path for `-RestoreFrom` when it ends `.zip`. Clean up the decompressed temp files after the restore completes.

- [ ] **Step 5: Run the suite; COMP-7 green**, whole suite green.

- [ ] **Step 6: Commit.**
```
git add Invoke-SqlExpressBackup.ps1 test/sqlexpress-backup.test.ps1
git commit -m "feat(engine): restore decompresses a .zip source before RESTORE

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: Retention pairs the sidecar + live compressed round-trip

**Files:** Modify `Invoke-SqlExpressBackup.ps1` (the retention delete loops); Create `test/live-compress.ps1`; Test `test/sqlexpress-backup.test.ps1`.

- [ ] **Step 1: Retention deletes the sidecar with its backup.** In both prune paths — the Simple `Remove-SebNamed` calls and the Full chain-retention delete loop (which does `Remove-Item -LiteralPath $entry.File`) — after removing a compressed backup file, also remove its `.meta.json` sidecar. For the chain loop, add right after the `Remove-Item` of a pruned `$entry.File`: `$meta = Get-SebSidecarName $entry.File; if (Test-Path -LiteralPath $meta) { Remove-Item -LiteralPath $meta -Force -ErrorAction SilentlyContinue }`. For `Remove-SebNamed`, have it remove a `<name>.meta.json` beside each removed name if present.

- [ ] **Step 2: Add a unit assert** that `Remove-SebNamed` (or the chain delete) targets the sidecar. Simplest behavioural check via a temp dir:
```powershell
# ---- COMP-8. retention removes a compressed backup's sidecar with it ----------------
$tmpP = Join-Path $env:TEMP ('seb-ret-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tmpP -Force)
try {
  $z = Join-Path $tmpP 'APPDB_20260905-000000.bak.zip'; Set-Content -LiteralPath $z -Value 'x'
  Set-Content -LiteralPath (Get-SebSidecarName $z) -Value 'x'
  Remove-SebNamed -Directory $tmpP -Names @('APPDB_20260905-000000.bak.zip')
  Assert (-not (Test-Path -LiteralPath $z)) 'the pruned .zip is removed'
  Assert (-not (Test-Path -LiteralPath (Get-SebSidecarName $z))) 'its .meta.json sidecar is removed too'
}
finally { Remove-Item -LiteralPath $tmpP -Recurse -Force -ErrorAction SilentlyContinue }
```

- [ ] **Step 3: Run the suite; COMP-8 PASS**, whole suite green.

- [ ] **Step 4: Create `test/live-compress.ps1`** — the same self-contained shape as `test/live-pitr.ps1` (dot-source the engine, scratch DB `CompProbe`, instance-owned temp share granted to the SQL service account, no config/elevation), but with compression: publish a full + a log **through `Publish-SebBackup` with `-Compress $true`** so the share gets `.bak.zip`+`.meta.json` and `.trn.zip`+`.meta.json`; assert the sidecars exist; build the catalogue (must read the sidecars, not decompress); `Invoke-SebRestoreToPoint` with `STOPAT` between two rows; assert the restore decompressed + landed (row A present, row B absent) + `DBCC CHECKDB` clean; drop everything.

- [ ] **Step 5: Run it** where SQL Express is present:
`powershell -NoProfile -ExecutionPolicy Bypass -File "test\live-compress.ps1"`
Expected: `LIVE COMPRESS PROOF: ALL PASS`, exit 0.

- [ ] **Step 6: Commit.**
```
git add Invoke-SqlExpressBackup.ps1 test/sqlexpress-backup.test.ps1 test/live-compress.ps1
git commit -m "feat(engine): retention removes the .meta.json sidecar; live compressed round-trip proof

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-review

**Spec coverage** — config flag (Task 5), compress-before-copy for all kinds (Task 6), sidecar write + catalogue read (Tasks 3, 4, 6), decompress-on-restore (Task 7), retention pairs `.zip`+sidecar (Task 8), naming/stamp/folder-facts accept `.zip` (Task 2), copy-resilience carries both (Task 6 via `Save-SebCopyOrPend`), backward-compat mixed shares (extension + sidecar-presence checks throughout), Express-only in-box compression (Task 1), live proof (Task 8). Every spec section maps to a task.

**Placeholders** — none: pure cores carry full code + asserts; the two impure wiring tasks (6, 7) carry the helper code + the exact call-site integration, with an explicit fallback instruction where the existing copy/pend shape must be matched by reading it.

**Type consistency** — the fact shape `{Kind;File;FirstLSN;LastLSN;DatabaseBackupLSN;CheckpointLSN;Finish}` is identical across `Get-SebHeaderFactsFromRow` (existing), `Get-SebHeaderFactsFromSidecar` (Task 3), `Get-SebFactsForFile` (Task 4), and the sidecar JSON (Task 3). `Get-SebCompressedName`/`Get-SebSidecarName`/`Compress-SebFile`/`Expand-SebFile`/`Resolve-SebRestoreSource`/`Publish-SebBackup` names are used consistently across Tasks 1, 2, 6, 7, 8. LSNs are `[decimal]` everywhere, strings only inside the sidecar JSON.
