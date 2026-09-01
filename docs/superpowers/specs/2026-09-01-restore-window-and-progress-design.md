# Restore window, and honest progress

Two changes, specified together because the second is built on the first, and
sequenced apart because they carry very different risk.

**Phase 1** rewrites the progress readout. Contained, one class, immediately
visible, cannot lose data.

**Phase 2** adds a restore window. New form, new engine modes, and the most
dangerous thing this tool will ever do.

Phase 1 ships and is proven before Phase 2 starts. Phase 2 reuses its progress
plumbing, so it wants that settled anyway.

---

## Phase 1 — progress that tells the truth

### The fault

`ProgressPanel` tracks percentage *within the current database*. SQL Server only
reports that during `BACKUP ... WITH STATS`. During verify, during copy, and after
the pass finishes there is no percentage, so the bar is blank — a completed job
renders identically to a job that never started.

Observed: `APPDB 8 of 8 [finished] — 2.3 MB/s — 9m 09s elapsed`, with an empty
bar.

### The change

The bar becomes **overall job progress**, not per-database progress:

```
overall = (completed + fraction_of_current) / total
```

`fraction_of_current` is derived from the stage, because that is the only thing
known at every moment:

| Stage | Fraction | Why |
|---|---|---|
| `starting` | 0.00 | nothing has happened yet |
| `backup` | `pct/100 × 0.75` | SQL's own STATS, occupying the bulk of the work |
| `verify` | 0.85 | RESTORE VERIFYONLY, no percentage available |
| `copy` | 0.95 | file copy to the destination |
| done | 1.00 | |

Two properties are load-bearing:

**Monotonic.** The computed value is clamped so it never decreases. Without this,
starting database 4 of 8 briefly reports less than finishing database 3 of 8, and a
bar that goes backwards destroys trust in the whole readout.

**`[finished]` is 100%.** A full green bar. This is the specific bug being fixed and
should be asserted directly, not left to follow from the arithmetic.

### The glow

A sheen band drawn over the fill, offset each tick. The panel's timer drops from
500 ms to roughly 60 ms while a job is active and returns to idle afterwards —
a repaint every 60 ms on a bar is cheap; leaving it running when nothing is
happening is not.

The sheen is **not decoration, it is a liveness signal**, so it inherits the rule
the current design already gets right:

- throughput above zero → sheen moves, fill is green
- throughput at zero for more than 5 seconds during `backup` or `copy` → **sheen
  stops and the fill turns amber**
- finished → full, green, no sheen

A stall must look like a stall. An animation that keeps playing while nothing
happens is worse than no animation, because it actively asserts progress.

### Testing

Pure functions, asserted directly and mutation-verified:

- overall progress arithmetic, including the monotonic clamp
- stage-to-fraction mapping
- `[finished]` producing exactly 1.0
- stall detection at the 5-second threshold

---

## Phase 2 — the restore window

### Shape

A second top-level window, opened non-modally from a `Restore` button on the main
window. Layout: backup-set tree on the left, restore sequence and options on the
right, progress across the bottom.

Windows 11 native styling, following the OS light/dark setting as the main window
already does.

### Where the logic lives

**In the engine, as new modes — not reimplemented in C#.**

The engine already performs `RESTORE HEADERONLY`, `RESTORE FILELISTONLY` and
`RESTORE DATABASE ... WITH MOVE` inside its self-test, and that code is exercised on
every run. Writing a second restore implementation in the window would create two
things that must agree forever about file relocation and recovery state. The same
argument settled the backup path and settles this one.

The window drives:

| Mode | Does |
|---|---|
| `-RestoreList` | enumerate backup sets under the configured destination |
| `-RestoreInspect <file>` | HEADERONLY + FILELISTONLY + readability pre-check |
| `-RestoreVerify <file>` | RESTORE VERIFYONLY WITH CHECKSUM |
| `-RestoreRun ...` | execute the sequence, emitting Phase 1 progress markers |
| `-RestoreSwap ...` | the guarded rename cut-over |

Progress works for free: `-RestoreRun` emits the same `[PROGRESS]` / `[STAGE]` /
`[JOB]` markers the backup path already emits, and Phase 1 already parses them.

### Terminology

The window uses SQL Server's vocabulary, not invented product language. A
**backup set** is what `RESTORE HEADERONLY` enumerates. A **restore sequence** is the
ordered set of `RESTORE` statements that reaches a recovery point. **Recovery state**
is `RECOVERY` / `NORECOVERY` / `STANDBY`. Relocation is `MOVE`.

This matters because the operator's other tools — SSMS, `sqlcmd`, every article they
will find while under pressure — use these words. A window that calls a restore
sequence a "plan" forces a translation step at the worst moment.

### What it can restore

Settled by decision, informed by how Veeam and NetWorker scope the same problem:

- **The catalogue this tool writes**, browsed as backup sets per database.
- **Any `.bak` file the operator points at** — including one produced by another
  server or another product. If its header shows a differential or log chain, the
  sequence is ordered correctly with `NORECOVERY` on all but the last.
- **A different instance or host.** Veeam calls this restoring to another server;
  NetWorker calls it directed or copy recovery. Both treat it as first class,
  because it is the case that matters when the original host is what died. Neither
  permits directed recovery onto the source location, and neither does this.

### What it deliberately cannot do

Shown in the window, **greyed with the reason stated** rather than hidden. Veeam does
this and it is the right call: a disabled control that explains itself teaches the
operator why their situation is what it is.

| Unavailable | Reason surfaced |
|---|---|
| Recovery point (`STOPAT`) | no log chain — SIMPLE recovery |
| Tail-log backup before restore | impossible under SIMPLE recovery |
| Preserve replication (`KEEP_REPLICATION`) | database is not published |
| Table-level restore | needs a staging instance and an export step; even Veeam does not do this in one gesture |
| Instant recovery / mount | needs image-based backups, not `.bak` files |

### Restore options offered

The applicable subset of the SSMS restore dialog:

- Recovery state — `RECOVERY`, `NORECOVERY`, `STANDBY`
- Relocate files (`MOVE`) — **two-folder shortcut**: all data files to one folder,
  log to another, with per-file override and logical-name editing underneath. Taken
  from NetWorker, which is markedly better than editing one `MOVE` row per file.
- Overwrite existing database (`REPLACE`)
- Restrict access after restore (`RESTRICTED_USER`)
- Close existing connections to the destination

### The readability pre-check

Not from either product. It exists because a restore drill on 2026-08-31 found that
SQL Server could not read the backups this tool produced — the engine copied them to
the destination and the SQL service account was never granted there. Every pass was
green and `RESTORE FILELISTONLY` failed with operating system error 5.

The window checks this **before** the operator commits, names the service account,
and prints the exact `icacls` command. The symptom reads as a corrupt backup and is
not; discovering that mid-incident costs time nobody has.

### The destructive path

Overwriting a live database is permitted, guarded two ways.

**Typed confirmation.** The operator types the database name. Nothing else enables
the button.

**Rename, never drop:**

```
1  RESTORE DATABASE [<db>_Restore] ... WITH RECOVERY
2  ALTER DATABASE [<db>] SET SINGLE_USER WITH ROLLBACK IMMEDIATE
3  ALTER DATABASE [<db>] MODIFY NAME = [<db>_Old]
4  ALTER DATABASE [<db>_Restore] MODIFY NAME = [<db>]
```

`<db>_Old` is retained. Removing it is a separate, deliberate act. A restore that
turns out to be wrong therefore costs nothing, which is the entire point — the
failure this guards against is a bad backup destroying a good database.

This mirrors the procedure already written in `docs/RESTORE.md`, so the window and
the runbook cannot drift into disagreeing.

### Error handling

Most of the value of this window is in refusing clearly rather than failing late.

| Condition | Behaviour |
|---|---|
| operator is not `sysadmin` | say so on open, disable restore — do not fail after the operator has committed |
| SQL cannot read the media | detected pre-flight, exact `icacls` command shown |
| target `.mdf`/`.ldf` already exists | refuse; never silently clobber a file on disk |
| chain incomplete or out of order | refuse, and name the missing backup set |
| restore fails part-way | the database is left `RESTORING`; the window states plainly how to leave that state, because it is a condition that reliably confuses people |
| destination database in use | offer to close connections; never force it silently |

### Testing

Pure functions, asserted and mutation-verified:

- restore sequence ordering for a full / differential / log chain
- `MOVE` clause construction, including the two-folder shortcut and per-file override
- target name validation, and refusal when target files exist
- recovery-state selection for chained versus single-set restores
- the greyed-option reasons being derived from actual database state, not hardcoded

One end-to-end test: back up a scratch database, restore it under a new name,
compare row counts, drop it. That is the drill from `docs/RESTORE.md`, run by the
suite rather than by hand.

---

## What is explicitly not in scope

- Log backups or a change of recovery model. That is a decision for whoever owns
  these databases, and it changes their storage behaviour. It is not a side effect
  of a tool upgrade.
- Scheduling restores. Restore is a human decision, deliberately.
- Automatic restore over a live database with no confirmation. Never.
