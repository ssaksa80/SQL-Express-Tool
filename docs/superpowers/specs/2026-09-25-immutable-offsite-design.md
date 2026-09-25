# Immutable Offsite Copy (WORM) — Design Spec

- **Date:** 2026-09-25
- **Status:** Design decisions approved (model, retention). Increment 1 (engine) implemented; tested against AWS's SigV4 examples and a loopback fake S3. The live MinIO test was not run: MinIO no longer publishes public images, and the operator chose to skip it. `-ConfigureOffsite` proves a locked upload against the real bucket. Increment 2 (app: Offsite window, overview tile) implemented.
- **Component:** SQL-Express-Tool — `Invoke-SqlExpressBackup.ps1` (engine, increment 1); `wpf/` (increment 2)
- **Feature:** Roadmap feature 2 ("Protect the backups"), **increment 3 of 3** — IMMUTABILITY. It also delivers the offsite copy the README lists as missing.

## 1. Why not WORM on the share

A Windows file share cannot be write-once. Whatever writes the backups — SYSTEM, the server's machine account — owns them, and an owner can always change the permissions back. Ransomware that gets SYSTEM on the server can therefore delete everything the tool can write. Deny-delete ACLs would stop accidents and non-admin malware, not the attack that matters. **Immutability has to be enforced by storage the server cannot command.** That rules out anything done on the share itself.

## 2. Decisions (approved)

| Question | Decision |
|---|---|
| Model | **An immutable offsite copy** in S3-compatible object storage with **Object Lock** (AWS S3, Wasabi, Backblaze B2, MinIO, …). The store refuses to delete or overwrite a locked object until its retain-until date — even with the server's own credentials. |
| Retention | **Its own, longer lock**, default **30 days**. This is the copy you fall back to when the share is gone or encrypted, so it reaches further back than the share's 7 days. Expired objects are cleaned up by a lifecycle rule on the bucket, **never by the tool**. |

## 3. Shape

- **Source is the share, not staging.** A separate SYSTEM task, `SqlExpressBackup-Offsite` (every 30 minutes, plus at boot), runs `-SyncOffsite`. It lists this host/instance's backups, sidecars and key escrows on the share, and uploads whatever is not yet offsite, oldest first so a chain arrives in order.
- **It does not take the backup mutex.** A 10 GB upload inside a data pass would make every log backup stand down for its duration. The sync has its own mutex, so two syncs never overlap. If retention removes a file mid-upload, that upload fails and the file is skipped next time.
- **What is uploaded is exactly what is on the share:** `.bak/.dif/.trn`, optionally `.zip`/`.enc`, their `.meta.json` sidecars, and `encryption-key-*.json`. So if encryption is on, the offsite copy is ciphertext too, and the escrow travels with it. A rebuilt server can import the key from offsite.
- **Object key:** `<prefix>/<HOST>/<INSTANCE>/<database>/<kind>/<file>`, mirroring the share (default prefix `sqlexpress-backup`).
- **State:** `offsite-state.json` in the config folder — `{ key: { Size, UploadedUtc, RetainUntilUtc, ETag } }` plus `LastRunUtc` / `LastResult` / `LastError`. It is separate from `state.json`, because the sync runs outside the backup mutex.

## 4. Protocol (pure PowerShell, no SDK)

- **Signing:** AWS Signature Version 4 over `HttpWebRequest`, verified against AWS's published test vectors.
- **Addressing:** virtual-hosted style for `*.amazonaws.com`, path style otherwise (MinIO, Wasabi, B2).
- **Upload:** one streamed `PUT` up to 64 MB; multipart above that (`CreateMultipartUpload` → `UploadPart` → `CompleteMultipartUpload`, 64 MB parts, which covers SQL Express's 10 GB limit).
- **Every upload carries:**
  - `x-amz-object-lock-mode` (**COMPLIANCE** by default; `GOVERNANCE` configurable);
  - `x-amz-object-lock-retain-until-date` (now + `OffsiteLockDays`);
  - `Content-MD5` (Object Lock requires it);
  - `x-amz-content-sha256` (the payload hash).
- **Verified:** after each upload, a `HEAD` must show the lock mode and a retain-until date at least as late as requested. A bucket without Object Lock refuses a locked `PUT`, so misconfiguration fails **loudly**; it never produces an unlocked copy that looks fine.
- **TLS 1.2, https only.** Plain `http://` is allowed only to a loopback endpoint, for tests.

## 5. Credentials and least privilege

- **What's stored:** the access key id and secret key, sealed in `offsite.dat` like the other secrets, never printed, and URLs and keys stripped from logged errors.
- **What the key needs:** `s3:PutObject`, `s3:PutObjectRetention`, `s3:GetObject`, `s3:GetObjectRetention`, `s3:ListBucket`, and for multipart, `s3:AbortMultipartUpload`. **No delete, and no `s3:BypassGovernanceRetention`.** With a key like that, a compromised server can add new objects but cannot remove or shorten the locked ones. The README ships the policy.

## 6. Restore from offsite

`-FetchOffsite -Destination <folder> [-Database <name>]` downloads the objects for this host/instance into `<folder>`, laid out exactly like the share. The restore modes accept `-SharePath <folder>` to read from there instead of the configured share, so the catalogue, point-in-time restore and decryption work unchanged. On a rebuilt server with encryption, `-ImportEncryptionKey -EncryptionKeyFile <folder>\…\encryption-key-*.json` comes first.

## 7. Configuration and CLI

- **Config keys (allow-listed):** `OffsiteEnabled`, `OffsiteEndpoint`, `OffsiteRegion`, `OffsiteBucket`, `OffsitePrefix`, `OffsiteLockDays` (30), `OffsiteLockMode` (Compliance|Governance).
- **`-ConfigureOffsite`** (elevated): the settings, plus secrets from `-OffsiteSecretsFile` (DPAPI-CurrentUser JSON from the app) or prompts. It test-uploads a small locked probe object and verifies its lock before enabling. Also reconciles the task.
- **`-DisableOffsite`:** stops syncing. Locked objects stay locked, by design.
- **`-SyncOffsite`:** one sync now; the task runs it.
- **`-FetchOffsite`:** see §6.
- **`-Status`:** endpoint, bucket, lock, last sync, backlog.

## 8. Alerting

| Key | Severity | When |
|---|---|---|
| `offsite-failed` | warning | a sync run failed (auth, network, bucket) |
| `offsite-backlog` | critical | the oldest backup on the share not yet offsite is older than `OffsiteBacklogHours` (default 24) |
| `offsite-lock-missing` | critical | an uploaded object came back without the requested lock |

The watchdog adds `offsite-task-missing` when offsite is enabled but its task is absent or disabled.

## 9. Testing

**Unit:**
- the SigV4 signer against AWS's published test vectors;
- canonical URI encoding;
- the upload plan (single vs multipart, part boundaries);
- which share files are candidates and in what order;
- the backlog computation and lock verification from headers.

**Transport (loopback fake S3):**
- a `TcpListener` server that checks the lock headers, `Content-MD5` and the multipart sequence;
- a bucket that refuses locks surfaces as a failure.

**Live:** against MinIO with Object Lock, in Docker, **only with the operator's go-ahead to pull the image**:
- a data pass, then a sync, puts every share file offsite, locked;
- deleting a locked object is refused;
- `-FetchOffsite` then `-SharePath` restores the database.
