# Backup Encryption at Rest — Design Spec

- **Date:** 2026-09-25
- **Status:** Design decisions approved (key recovery model, existing backups). Increment 1 (engine) and increment 2 (app: Encryption window, one-time recovery-key reveal, elevated restore of encrypted sets) implemented.
- **Component:** SQL-Express-Tool — `Invoke-SqlExpressBackup.ps1` (engine, increment 1); `wpf/` (increment 2)
- **Feature:** Roadmap feature 2 ("Protect the backups"), **increment 2 of 3** — ENCRYPTION. Compression (increment 1) shipped; immutability/WORM is increment 3.

## 1. Goal

Anyone who can read the share should not be able to read the databases. SQL Server Express cannot encrypt backups itself (`BACKUP … WITH ENCRYPTION` is not supported on Express), so the tool encrypts each file after SQL writes it, in the slot the compression spec left for it: **compress → encrypt → copy**. Opt-in, default off.

The risk that shapes everything: **encryption done wrong makes every backup unrestorable.** A rebuilt server has a new DPAPI machine key, so a key sealed only to the old machine is gone with it. Key recovery is the design's centre, not an afterthought.

## 2. Decisions (approved)

| Question | Decision |
|---|---|
| Key recovery | **Passphrase escrow + recovery key.** Unattended runs use a machine-sealed data key. The same data key is also stored on the share, wrapped by an operator passphrase (PBKDF2-SHA256, 600,000 rounds) **and** by a one-time recovery key printed for offline safekeeping. A rebuilt host restores with either. |
| Existing backups | **Leave them, encrypt new ones.** The share holds a mix; restore, catalogue and retention handle both; old plain files age out through retention. |

## 3. Keys

- **Data key (DEK):** 32 random bytes. **Key id:** the first 8 bytes of SHA-256(DEK), hex — written in every file header so the right key is found, never guessed.
- **Keyring** (`keyring.dat` in the config folder): `{ keyId: DEK }` for every key this host can use (its own, and any imported), sealed with the existing machine master key (DPAPI LocalMachine + AES-256-CBC/HMAC-SHA256) and ACL'd SYSTEM/Administrators. `ActiveKeyId` in config names the key new backups use.
- **Escrow** (`encryption-key.json`, plaintext JSON, but only wrapped keys in it): `{ Version, KeyId, Kdf: "PBKDF2-SHA256", Iterations, Salt, PassphraseWrapped, RecoveryWrapped, CreatedUtc, Host, Instance }`. Each `*Wrapped` value is the DEK sealed with `Protect-SebBytes` under a key-encryption key: from the passphrase via PBKDF2, or from the recovery key via HMAC-SHA256 (it is 256 random bits already, so no stretching is needed). Written to the config folder at setup, then **copied by every data pass** to `<share>\<HOST>\<INSTANCE>\encryption-key.json` if it is missing or different there. The pass runs as SYSTEM and can already write the share; the operator running setup may not be able to.
- **Recovery key:** 32 random bytes shown once as 64 hex characters in groups of 8. It is never stored anywhere.
- **Passphrase:** at least 12 characters, entered twice, never stored. It is used only to wrap and unwrap.

## 4. File format (`.enc`)

`X.bak` → `X.bak.enc`, or `X.bak.zip` → `X.bak.zip.enc` when compressing too (compression first, because ciphertext does not compress).

```
magic "SEBENC01" (8) | keyId (16 ASCII hex) | IV (16) | AES-256-CBC ciphertext (PKCS7) | HMAC-SHA256 (32)
```

Encrypt-then-MAC over everything before the tag, with separate encryption and MAC keys derived from the DEK (`seb-file-enc-v1` / `seb-file-mac-v1`, via the existing `Get-SebSubKey`). The file is streamed in 1 MB chunks, pure PowerShell and .NET: no `Add-Type`, which application-control policies can block. Decryption **verifies the tag over the whole file first** and only then decrypts, so a tampered or truncated backup is refused instead of being handed to `RESTORE`. A `.meta.json` sidecar is written for every encrypted backup (`RESTORE HEADERONLY` cannot read ciphertext). It holds LSNs, kind and finish time only — no data.

## 5. Pipeline

- **Backup:** `Get-SebPublishSet` gains `-Encrypt`. It reads the header facts from the plain staged file, optionally zips, encrypts, and names the sidecar after the final file. Pending/copy resilience, orphan adoption and staging sweeps accept `.enc`.
- **Naming and retention:** the stamp, folder-facts, catalogue, sweep and orphan patterns accept an optional `.enc` after the optional `.zip`. Sidecar pairing already works by name.
- **Restore:** `Resolve-SebRestoreSource` decrypts a `.enc` into the SQL-readable temp folder (then unzips a `.zip` if needed). `-RestoreRun`, `-RestoreToPoint`, `-RestoreInspect`, `-RestoreVerify` and the restore test all work through it. The key comes from the keyring by the header's key id. A missing key is a clear error naming the key id and pointing at `-ImportEncryptionKey`. The keyring is admin-only, so restoring an encrypted backup needs an elevated console; the error says so.

## 6. CLI

| Mode | Does |
|---|---|
| `-SetupEncryption` | Elevated, interactive, or `-EncryptionSecretsFile` (DPAPI-CurrentUser JSON from the app). Creates a DEK, takes the passphrase (twice), prints the recovery key once, seals the keyring, writes the escrow, sets `ActiveKeyId`, turns `EncryptBackups` on. Refuses if a key already exists unless `-RotateKey` (new key, old keys stay in the keyring for old backups). |
| `-ImportEncryptionKey [-EncryptionKeyFile <path>]` | On a rebuilt host: reads the escrow from the share (or the given file), asks for the passphrase **or** the recovery key, and adds the DEK to this machine's keyring. |
| `-Reschedule -EncryptBackups On\|Off` | Turns encryption on or off for new backups (keys are kept either way). `On` without a key is refused with a pointer to `-SetupEncryption`. |
| `-Status` | Encryption on/off, active key id, keys in the keyring, whether the escrow is on the share. |

## 7. Alerting

- `encryption-escrow-missing` (warning, data pass): encryption is on but the escrow could not be put on the share. Without it, a lost server means lost backups unless the recovery key was kept.
- A backup that fails to encrypt fails that database, like any other backup failure, and raises the existing alerts.

## 8. Security notes (stated honestly)

- An administrator or SYSTEM on the host can read the keyring, as with the SQL credential. Encryption protects the **share** and anything copied off it, not the running host.
- The escrow on the share is only as strong as the passphrase. Hence the 12-character minimum and 600,000 PBKDF2 rounds (about 1 second per guess on this hardware).
- Sidecars reveal backup times and LSNs, not data.
- No authenticated encryption primitive (`AesGcm`) exists on .NET Framework 4.8. AES-CBC + HMAC-SHA256 encrypt-then-MAC with independent keys is the in-box equivalent and matches the credential seal.

## 9. Testing

**Unit:** file encrypt/decrypt round trip (SHA-256 identical, including a multi-chunk file and an empty file); tamper detection (a flipped byte in the body, the header or the tag, and a truncated file, are all refused before decryption); a wrong key id is refused; escrow unwrap by passphrase and by recovery key, and a wrong passphrase is refused; the recovery key's format; name patterns with `.enc` (stamp, facts, catalogue, sweep, orphans); the publish-set names for plain/zip × enc.

**Live** (`test/live-encrypt.ps1`): with encryption and compression on, a full + logs → `.zip.enc` + sidecars on the share, and no plaintext backup there; point-in-time restore lands correctly; the restore test passes; after wiping the keyring and importing from the share escrow with the passphrase (and separately the recovery key), the restore works again.

## 10. Increment 2 (app)

A setup-wizard/Protection option that runs `-SetupEncryption` through the secrets hand-off. It shows the recovery key once, with a copy button and a must-tick "I have stored it" confirmation. The restore window elevates for encrypted sets.
