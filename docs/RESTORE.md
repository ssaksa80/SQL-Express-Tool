# Restoring a database

Backups exist to be restored. This is the procedure for doing that, written to be
followed by someone who did not set the tool up and is reading it under pressure.

Every command here has been run against a real backup produced by this tool. The
drill at the end records what was proven and when.

---

## Before you touch anything

Three things decide how this goes, so establish them first.

**What are you actually recovering from?** A dropped table is not a corrupt
database is not a dead host. If the database is still online and you only need one
table's contents, restore to a *new* name and copy the rows across. Do not restore
over a live database because one table is wrong.

**What will you lose?** These backups run on a fixed interval — six hours by
default. Everything written since the last one is gone. There is no point-in-time
recovery: every database on the instance is in SIMPLE recovery, which makes log
backups impossible. If you need to lose less than an interval, that is a decision
about recovery models, not a thing this procedure can give you.

**Do you have the rights?** You need `sysadmin` on the instance, or at minimum
`dbcreator` plus the ability to read the backup file.

---

## Step 1 — find the backup

Backups are laid out by host, instance, database and kind:

```
<share>\<HOST>\<INSTANCE>\<DATABASE>\hourly\<DATABASE>_<yyyyMMdd-HHmmss>.bak
<share>\<HOST>\<INSTANCE>\<DATABASE>\daily\<DATABASE>_<yyyyMMdd-HHmmss>.bak
```

`hourly` keeps the last few passes; `daily` keeps one archive per calendar day. The
timestamp is when the pass started, in local time on the host that took it.

```powershell
Get-ChildItem '\\FILESERVER\SqlBackups' -Recurse -Filter 'MYDB_*.bak' |
  Sort-Object LastWriteTime -Descending | Select-Object -First 5 Name, Length, LastWriteTime
```

Newest is usually right. It is not always right: if you are recovering from
corruption that may have been backed up, you want the newest backup from *before*
the corruption, which means checking more than one.

---

## Step 2 — the permission trap, which will bite you

**SQL Server reads the backup file as its own service account, not as you.** You
can open the file in Explorer and SQL still cannot read it. The error is:

```
Cannot open backup device '...'. Operating system error 5(Access is denied.).
```

This is not a corrupt backup. Check permissions before you conclude anything else.

Recent versions of the tool grant the SQL service read on the destination when they
create the share. Backups taken before that fix, or a share created by hand, will
not have it. To grant it:

```powershell
icacls '<backup folder>' /grant 'NT SERVICE\MSSQL$SQLEXPRESS:(OI)(CI)(RX)' /T
```

Substitute your instance — `Get-CimInstance Win32_Service -Filter "Name LIKE 'MSSQL%'"`
shows the real service name and account.

**Local share, over UNC, is a separate case.** Reaching `\\thishost\share` on the
same machine, the SQL service presents its own virtual account, *not* the computer
account — so granting the computer account does not help and the UNC path still
fails while the local path works. If UNC is denied and you are in a hurry, use the
local path (`C:\SqlBackups\...`). Reaching a *remote* share it presents as the
computer account, which is what that share must grant.

If you cannot fix permissions right now, copy the file somewhere SQL can already
read — its own data directory works — and restore from there.

---

## Step 3 — verify the file before you rely on it

Do this first. It is fast, it touches nothing, and it tells you whether you have a
recovery or a problem.

```sql
-- Is this the database and the point in time you think it is?
RESTORE HEADERONLY FROM DISK = N'<path to .bak>';

-- What files will it want to write, and how big?
RESTORE FILELISTONLY FROM DISK = N'<path to .bak>';

-- Is the file internally intact?
RESTORE VERIFYONLY FROM DISK = N'<path to .bak>' WITH CHECKSUM;
```

The tool already ran `VERIFYONLY` when it took the backup — a file that failed
never counted as a success. Running it again checks the copy in front of you now,
which is the one you are about to bet on.

---

## Step 4 — restore to a NEW name

**Never restore straight over a live database.** Restore beside it, prove it, then
cut over. The original stays untouched and available the whole time, which means a
failed restore costs you nothing.

```sql
RESTORE DATABASE [MYDB_Restore]
  FROM DISK = N'<path to .bak>'
  WITH MOVE N'MYDB'     TO N'<data dir>\MYDB_Restore.mdf',
       MOVE N'MYDB_log' TO N'<data dir>\MYDB_Restore_log.ldf',
       RECOVERY, STATS = 5;
```

Use the logical names `FILELISTONLY` reported in step 3 — they are the names inside
the backup, not the file names on disk. `<data dir>` must be a directory the SQL
service can write; its own data directory always is:

```sql
SELECT SERVERPROPERTY('InstanceDefaultDataPath');
```

---

## Step 5 — prove it, before anyone depends on it

A restore that completed is not a restore that worked.

```sql
DBCC CHECKDB('MYDB_Restore') WITH NO_INFOMSGS;   -- silence is success
```

Then compare row counts against whatever you still have:

```sql
SELECT s.name + '.' + t.name AS tbl, SUM(p.rows) AS rows
FROM MYDB_Restore.sys.tables t
JOIN MYDB_Restore.sys.schemas s ON s.schema_id = t.schema_id
JOIN MYDB_Restore.sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
GROUP BY s.name, t.name ORDER BY rows DESC;
```

If the original is still online, run the same query against it and compare. Expect
the restored copy to be *behind* by up to one backup interval — that is the data
loss window, and seeing it confirms you restored the backup rather than the live
database by accident.

---

## Step 6 — cut over

This is the only destructive step. Everything above is reversible; this is not.

```sql
ALTER DATABASE [MYDB]         SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
ALTER DATABASE [MYDB]         MODIFY NAME = [MYDB_Old];
ALTER DATABASE [MYDB_Restore] MODIFY NAME = [MYDB];
ALTER DATABASE [MYDB]         SET MULTI_USER;
```

Renaming rather than dropping means the old database is still there if the restore
turns out to be wrong. **Keep `MYDB_Old` until someone has actually used the
application and confirmed it is right** — not until the restore finishes. Drop it
later, deliberately:

```sql
DROP DATABASE [MYDB_Old];
```

Stop the application before the cut-over and start it after. `ROLLBACK IMMEDIATE`
kills open transactions, which is fine for a dead database and rude for a live one.

---

## Step 7 — afterwards

- Take a backup immediately. The next scheduled pass may be hours away, and the
  restored database has no backup of its own yet.
- Check the schedule survived. `Get-ScheduledTask` — if the restore involved
  rebuilding the host, the task may not exist any more.
- Write down what you lost. The gap between the backup timestamp and the failure is
  real data somebody needs to know about.

---

## What this cannot do

Stated plainly, so nobody discovers it mid-incident:

- **No point-in-time recovery.** SIMPLE recovery on every database means no log
  chain. You restore to a backup, never to a moment.
- **The interval is the loss.** Six hours by default.
- **A local share is not disaster recovery.** If the backup destination is a share
  on the machine running SQL, a dead host takes both. Point the destination at
  another server.
- **Restore is not automated.** Deliberately. Automated restore over a live
  database is how a bad backup destroys a good database.

---

## Drill record

| Date | Database | Source | Result |
|---|---|---|---|
| 2026-08-31 | APPDB (72 MB) | `hourly` copy on the share, taken 18:55 that day | Restored to a new name. `DBCC CHECKDB` clean. All 10 tables compared against live, row counts matched exactly, 0 mismatches. Drill database dropped, original untouched and online. |

That drill found the permission fault in step 2: every pass was green, every backup
verified, and `RESTORE FILELISTONLY` still failed with operating system error 5. The
backups were good and nobody could have restored them. Nothing but an actual restore
would have shown it.

Run one after any change to the share, the service account, or the host. A backup
you have never restored is a backup you do not have.
