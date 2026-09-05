# Backup Compression — Design Spec

- **Date:** 2026-09-05
- **Status:** Design approved; pending spec review
- **Component:** SQL-Express-Tool — `Invoke-SqlExpressBackup.ps1` (engine); `wpf/` later
- **Feature:** Roadmap feature 2 ("Protect the backups"), **increment 1 of 3** — COMPRESSION. Encryption-at-rest and immutability/WORM are separate later increments.

## 1. Goal

Optionally compress every backup file (`.bak`/`.dif`/`.trn`) to a `.zip` on the share, since SQL Express has no native `BACKUP … WITH COMPRESSION`. Cuts share storage and offsite-copy time several-fold. Opt-in (default off), works in both Simple and Full (point-in-time) modes, fully reversible on restore, and backward-compatible — a share may hold a mix of compressed and plain files.

## 2. Scope

**In:** a `CompressBackups` config flag; compress-in-staging-before-copy for all backup kinds; a `.meta.json` sidecar so the point-in-time catalogue reads LSNs without decompressing; decompress-on-restore; retention and copy-resilience that handle the `.zip`+sidecar as a unit; naming/stamp/folder-facts that accept `.zip`.

**Out (later increments of feature 2):** AES encryption-at-rest; immutability/retention-lock (WORM). **Out (other features):** offsite/cloud replication (feature 3), alerting (feature 4). This increment deliberately leaves the pipeline *wrappable* — encryption slots in **after** compression (compress → encrypt → copy), since encrypted data doesn't compress.

## 3. Config & default

- New key `CompressBackups` (bool, default `$false`) in the config template, `$SebShowKeys`, and public.json (via the shared allow-list, exactly as `RecoveryMode` does).
- CLI `[switch]$CompressBackups`; Setup and `-Reschedule` persist it (`$PSBoundParameters.ContainsKey`-gated), mirroring `RecoveryMode`'s plumbing shipped in PITR D3.
- Default off ⇒ existing installs unchanged until opt-in.

## 4. Compression primitive

Use in-box **`System.IO.Compression`** — NOT `Compress-Archive`, whose ~2 GB limit and full-buffer memory use fail on large `.bak` files. `Add-Type -AssemblyName System.IO.Compression.FileSystem`; `[System.IO.Compression.ZipFile]::Open($zip,'Create')` + `[System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$plain,$entryLeaf,[System.IO.Compression.CompressionLevel]::Optimal)` — streams the file (no full-buffer), and .NET auto-selects Zip64 for entries > 4 GB.

Two wrappers: `Compress-SebFile -Source -Destination` (zip one file; entry name = the plain leaf) and `Expand-SebFile -Source -Destination` (extract the single entry). Round-trip tested (compress → expand → SHA-256 identical).

## 5. Sidecar (the point-in-time bridge)

The restore planner reads each share file's LSNs via `RESTORE HEADERONLY`, which can't read a `.zip`. So at backup time, **before zipping**, read the plain file's facts once (the shape `Get-SebRestoreHeaderFacts` already produces) and write `<name>.meta.json` beside the `.zip` on the share.

- LSNs are stored **as strings** in the sidecar: `numeric(25,0)` LSNs lose precision if serialized as JSON numbers and re-read via `ConvertFrom-Json`. Shape: `{ "Kind":"full", "FirstLSN":"…", "LastLSN":"…", "DatabaseBackupLSN":"…", "CheckpointLSN":"…", "Finish":"2026-09-05T08:00:00" }`.
- New pure `Get-SebHeaderFactsFromSidecar -Json -File -Kind` → the SAME facts object `Get-SebHeaderFactsFromRow` returns (`[decimal]` LSNs parsed from the strings, `[datetime]` Finish). Tested with fake JSON including a 25-digit LSN (precision preserved) and a missing field.
- `Get-SebRestoreHeaderFacts` / `Get-SebPointCatalogue`: for a share file, if a paired `.meta.json` exists → read facts from it; else `RESTORE HEADERONLY` on the plain file. The fact's `File` is the `.zip` path (restore decompresses it). The planner never decompresses to catalogue.

## 6. Backup pipeline

When `$config.CompressBackups`, the per-database path (`Invoke-SebPass` Full and Simple branches, `Invoke-SebBackupLogPass`) becomes:
1. `BACKUP` to a staging plain file (unchanged).
2. `Test-SebBackupFile` (`VERIFYONLY`) on the **plain** file (unchanged — SQL can't verify a `.zip`).
3. Read `RESTORE HEADERONLY` facts from the plain staging file (for the sidecar).
4. `Compress-SebFile` plain → staging `.zip`; write the sidecar `.meta.json`.
5. `Copy-SebVerified` the `.zip` to the share, and copy the `.meta.json` alongside. In Full mode and the log pass, route through `Save-SebCopyOrPend` so a share outage queues the `.zip`+sidecar together (the Pending entry carries both).
6. Staging cleanup (plain + `.zip`) via the existing keep-if-still-pending logic.

When off: the current plain path, byte-for-byte unchanged.

## 7. Restore pipeline

- `-RestoreRun` / `-RestoreToPoint`: a source/step whose `File` ends `.zip` → copy from the share to staging → `Expand-SebFile` to the plain file → `FILELISTONLY` (`Get-SebRestoreInspect`) + MOVE (`Get-SebRestoreMoveClauses`) + `RESTORE` on the plain file. Plain sources restore as today (detected by extension). The `-RestoreToPoint` executor decompresses each chain step's `.zip` before its `RESTORE`.
- `Get-SebRestoreInspect` / any restore-time `VERIFYONLY` run on the decompressed plain file.

## 8. Naming & retention

- `Get-SebFileName` keeps producing the plain name; a small helper appends `.zip` (compressed) and `.meta.json` (sidecar).
- `Get-SebStampFromName` regex extended to allow an optional `.zip`: `_(\d{8})-(\d{6})\.(bak|dif|trn)(\.zip)?$`. `.meta.json` is deliberately NOT matched (it's a sidecar, not a backup).
- `Get-SebFolderFacts` enumerates `.bak`/`.dif`/`.trn` and their `.zip` variants; excludes `.meta.json`.
- Retention (`Get-SebRetentionPlan` and the `Get-SebChainRetentionPlan` delete loop) removes a pruned backup's `.zip` **and** its `.meta.json` together. `Get-SebChainFactsFromCatalogue` is unchanged (it consumes catalogue facts, which now come from sidecars for compressed files).

## 9. Backward compatibility

Default off. A share may hold a mix — legacy plain `.bak` beside new `.bak.zip`+`.meta.json`. Restore, catalogue, and retention handle both (extension + sidecar-presence checks). Turning `CompressBackups` on compresses only new backups; existing plain files stay restorable and are pruned by their own name. Turning it off resumes plain backups; existing `.zip` files stay restorable.

## 10. Testing

**Pure/unit** (dot-sourced, mutation-checked, with positive controls):
- `Compress-SebFile`/`Expand-SebFile` round-trip: temp file → zip → expand → SHA-256 identical.
- `Get-SebStampFromName`: `.bak.zip`/`.dif.zip`/`.trn.zip` parse to the same stamp as the plain name; `.meta.json` is not matched; plain `.bak` still parses (no regression).
- `Get-SebHeaderFactsFromSidecar`: fake JSON incl. a 25-digit LSN string → facts with `[decimal]` LSNs precision-preserved + `[datetime]` Finish; a missing field → handled.
- `Get-SebFolderFacts`: a dir with `.bak.zip` + `.meta.json` + a plain `.bak` → exactly the two backups enumerated, the sidecar excluded.
- Retention pairing: a pruned compressed backup's delete set includes its `.meta.json`.

**Live** (`test/live-compress.ps1`, same self-contained shape as `test/live-pitr.ps1`): with `CompressBackups` on, take a full + logs (→ `.zip` + `.meta.json` on the share), then `-RestoreToPoint` with `STOPAT` between two rows → the restore decompresses, lands correctly (row A, not row B), and `DBCC CHECKDB` is clean. Proves the compressed round-trip end-to-end.

## 11. Rollout / order within the increment

(a) config flag + `Compress-SebFile`/`Expand-SebFile` (pure round-trip); (b) sidecar write + `Get-SebHeaderFactsFromSidecar` + catalogue sidecar-read; (c) backup pipeline (compress + sidecar + copy, both modes + log pass); (d) restore pipeline (decompress); (e) naming/retention (`.zip`+sidecar); (f) live compressed round-trip test. Each behind `CompressBackups`; Simple and Full both covered.

## Open questions

None blocking. The two defaults — opt-in (default off) and compress all kinds including the 15-minute logs — were approved. Encryption-at-rest and immutability are deferred to feature-2 increments 2 and 3; the pipeline is left wrappable (compress → [encrypt] → copy) so encryption slots after compression.
