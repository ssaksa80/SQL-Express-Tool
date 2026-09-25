# Alerting — Design Spec

- **Date:** 2026-09-25
- **Status:** Design decisions approved (channels, dead-man detection, noise policy). Increment 1 (engine) implemented and tested; increment 2 (app: Alerts window, secret hand-off, overview banner) implemented.
- **Component:** SQL-Express-Tool — `Invoke-SqlExpressBackup.ps1` (engine, increment 1); `wpf/` (increment 2)
- **Feature:** Roadmap feature 4 — Alerting. Brought forward ahead of automated restore testing: on an unattended SQL Express box the worst failure is the one nobody sees, and alerting is what every later signal (restore tests, chain health, log growth) reports through.

## 1. Goal

When backups stop protecting the data, a person finds out — by email, by a Teams/Slack/generic webhook, and in the Windows event log — once when it starts, as a reminder while it lasts, and once when it clears. A host that stops running backups entirely (task disabled, service dead, box powered off) is caught too.

## 2. Decisions (approved)

| Question | Decision |
|---|---|
| Channels | **All three:** SMTP email, HTTPS webhook (Teams / Slack / generic JSON), Windows Event Log with a distinct event ID per notification type. |
| Dead-man detection | **Both:** an in-engine watchdog task (catches a broken/disabled task, stale backups, a broken chain) **and** an optional success-ping URL for an external monitor such as healthchecks.io or Uptime Kuma (catches a dead or powered-off host). |
| Noise | **Once per problem + resolved:** alert when a condition starts, remind every `AlertRemindHours` (default 24) while it persists, one "resolved" message when it clears. |

## 3. Scope

**Increment 1 (engine):** conditions, alert state, the three channels, the heartbeat ping, the watchdog task, `-ConfigureAlerts` / `-TestAlert` modes, `-Status` output, uninstall. Pure evaluation logic unit-tested; transports tested against local listeners.

**Increment 2 (app):** an Alerts section (settings, secrets entered through the elevated job, "Send test alert"), and active alerts on the Modern view.

**Out:** SMS/pager integrations (use a webhook into the pager's inbound URL), per-database routing, alert on success.

## 4. Conditions

Each condition has a stable **key**, a **severity** (`warning` | `critical`), an **owner** (the pass that evaluates it), and a message. A condition is only *resolved* by its owner's evaluation — a data pass never clears a log-pass alert just because it did not look at logs.

| Key | Severity | Owner | Raised when |
|---|---|---|---|
| `data-pass-failed` | critical | data pass | the pass backed up nothing (exit 2) |
| `data-pass-partial` | warning | data pass | some databases failed (names listed) |
| `copy-pending` | warning | data pass, log pass | copies have been pending (share unreachable) for ≥ `AlertPendingMinutes` (default 60) |
| `log-pass-failed` | critical | log pass | a log pass had a database fail |
| `log-growth` | warning | data pass | `Get-SebLogGrowthWarning` fires for a database |
| `log-unmanaged` | warning | data pass | a FULL-recovery database has no log backups (`Get-SebUnmanagedFullLogWarnings`) |
| `backup-stale` | critical | watchdog | no successful data pass for `AlertStaleHours` (default `2 × IntervalHours + 1`) |
| `log-stale` | critical | watchdog | Full mode, no successful log pass for `4 × LogIntervalMinutes` |
| `task-missing` | critical | watchdog | the backup task (or, in Full mode, the log task) is absent or disabled, and no service is installed |

A per-database condition's key carries the database (`log-growth:AppDb`), so each clears independently.

State needed for staleness: `state.json` gains `LastSuccessUtc` (data pass) and `LastLogSuccessUtc` (log pass). `Write-SebState` is changed to **preserve fields the caller did not set**, so the data pass, log pass and watchdog cannot erase each other's alert state.

## 5. Alert state and the notification decision

`state.json` gains `Alerts`: `{ "<key>": { Severity, Owner, Message, SinceUtc, LastSentUtc } }`.

A pure function `Update-SebAlertState -Previous -Current -Owner -Now -RemindHours` returns the new map plus the notifications to send:

- key in `Current`, not in `Previous` → **raised** (sent now);
- in both, `Now - LastSentUtc ≥ RemindHours` → **reminder**;
- in `Previous` with this `Owner`, not in `Current` → **resolved** (sent, then dropped);
- another owner's keys pass through untouched.

If every configured channel fails to deliver, `LastSentUtc` is **not** advanced, so the next evaluation retries. Alerting never throws into a backup pass: all delivery is wrapped and logged as `WARN`.

## 6. Channels

- **Event log** (always on; needs no config): source `SqlExpressBackup`, **9100** raised, **9101** reminder, **9102** resolved; `Error` entry type for critical, `Warning` for warning, `Information` for resolved. Existing 9001 log-line events are unchanged. Existing monitoring (SCOM, Wazuh, Datadog) can key on the IDs.
- **Email:** `System.Net.Mail.SmtpClient`, STARTTLS on by default (port 587). Implicit TLS on 465 is not supported by `SmtpClient` — documented. Anonymous relay if no user is configured. One message per evaluation (all raised/reminded/resolved conditions batched), subject `[SQL Express Backup] <HOST>\<INSTANCE>: <n> problem(s)` or `... resolved`.
- **Webhook:** HTTPS `POST`, TLS 1.2 forced. `AlertWebhookKind`:
  - `teams` — a Power Automate "Workflows" webhook (Office 365 connectors are retired), Adaptive Card payload;
  - `slack` — `{ "text": ... }`;
  - `generic` — `{ host, instance, event, severity, key, message, sinceUtc, timeUtc }` per notification.
- **Heartbeat:** after each successful data pass, `GET` `AlertHeartbeatUrl` (healthchecks.io / Uptime Kuma push URL). The external service alerts when pings stop. Failure is logged, never fatal.

## 7. Configuration

Non-secret keys (config.json; added to the `SebShowKeys` allow-list so `-Status`/public.json show them): `AlertEmailTo` (comma list), `AlertEmailFrom`, `AlertSmtpHost`, `AlertSmtpPort` (587), `AlertSmtpTls` (true), `AlertSmtpUser`, `AlertWebhookKind` (`''|teams|slack|generic`), `AlertRemindHours` (24), `AlertStaleHours` (0 = derive), `AlertPendingMinutes` (60).

Secrets — the SMTP password, the webhook URL and the heartbeat URL (webhook and ping URLs embed their own tokens) — are sealed in **`alert.dat`** with the same DPAPI-machine key + AES-256-CBC/HMAC scheme as `cred.dat`, and ACL'd SYSTEM/Administrators only. They are never printed, never written to public.json, and never included in an alert.

**CLI:** `-ConfigureAlerts` (elevated) sets the non-secret keys from parameters (`-AlertEmailTo`, `-AlertSmtpHost`, …; unbound = unchanged, like `-Reschedule`) and the secrets from `-AlertSecretsFile <path>` — a JSON file protected with **DPAPI CurrentUser** (which the app's elevated job can read, since elevation is the same user) and deleted after reading — or, interactively, from `Read-Host -AsSecureString` prompts when `-AlertPromptSecrets` is given. `-ClearAlerts` removes all alert config and `alert.dat`. `-TestAlert` sends a test notification through every configured channel and reports per-channel success.

## 8. Watchdog task

`SqlExpressBackup-Watchdog`, SYSTEM, every 60 minutes plus at startup (+10 min delay), `-Watchdog` mode. Registered by `Install-SebTask`/`Install-SebService` whenever any alert channel or heartbeat is configured, removed by `-Uninstall`, `-ClearAlerts`, and `-Reschedule` when nothing is configured. Lightweight: reads config and state, checks the schedule, evaluates the watchdog conditions, sends. Takes the shared mutex with a zero wait — a pass running right now is not a dead pass — so it never contends with a backup. No SQL connection.

## 9. Security

- Secrets sealed as above; delivery errors are logged with the exception message only after stripping anything URL-shaped, so a webhook token cannot leak into the log or the event log.
- TLS on by default for SMTP and required for webhooks (an `http://` webhook URL is refused; heartbeat URLs may be `http://` for an internal Uptime Kuma).
- Messages name the host, instance, databases and the condition — never paths to secrets, connection strings or credentials.

## 10. Testing

**Unit (dot-sourced):** `Update-SebAlertState` (raise, remind boundary, resolve, owner isolation, failed-delivery retry); each condition detector (thresholds and boundaries, including `backup-stale` derivation from `IntervalHours`); payload builders for Teams/Slack/generic (valid JSON, no secret fields); `Write-SebState` field preservation; the URL-stripping sanitizer; secrets round-trip through `alert.dat` sealing.

**Transport (local, no internet):** webhook and heartbeat against an `HttpListener` on localhost (payload and method asserted); email against a minimal in-test SMTP listener that records the DATA section.

**Live:** run a data pass against a scratch database with a deliberately unreachable share → `copy-pending` raised once; fix the share → resolved sent once; event log entries 9100/9102 present.

## 11. Rollout within increment 1

(a) `Write-SebState` field preservation + `LastSuccessUtc`/`LastLogSuccessUtc`; (b) conditions + `Update-SebAlertState` (pure); (c) channels + sanitizer + sealing of `alert.dat`; (d) wiring into the data pass and log pass + heartbeat; (e) `-Watchdog` mode and task registration/removal; (f) `-ConfigureAlerts` / `-ClearAlerts` / `-TestAlert` / `-Status`; (g) tests at each step; docs.
