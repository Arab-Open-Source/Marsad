# Marsad — Requested Features / Roadmap

> Status: **requested** — these are approved feature requests, not yet committed work.
> Each item is tracked as a GitHub issue with the `enhancement` and `roadmap` labels.

Last updated: 2026-11-17 · Baseline: v0.10.0

---

## A — Alerting & Notification Channels — [#7](https://github.com/Arab-Open-Source/Marsad/issues/7)

**Problem.** Marsad shows metrics, SSL expiry and activity, but only reacts when an operator is looking at the page. Teams need proactive detection delivered where they already work.

**Scope**
- Alert rules on metric thresholds (CPU/RAM/disk), server offline, SSL expiry (warn ≤30d, critical ≤14d), failed runbook runs and pending security updates (feature G).
- Severity levels, cooldown/dedup to avoid spam, and automatic "resolved" notifications.
- Persistent in-app notification center with unread state.
- Notification channels routed per rule:
  - **Email** via the configured `Swoosh` adapter.
  - **Telegram** via Bot API (`sendMessage` + chat id).
  - **WhatsApp** via WhatsApp Business Cloud API (Meta Graph) or Twilio — pluggable provider.
- Channel management UI with add/edit/test/disable and severity routing.
- Channel credentials encrypted at rest with `Marsad.Fleet.CredentialVault`, never logged.

**Acceptance criteria**
- A rule has a condition, severity, cooldown and one or more channels.
- A trigger fires once per cooldown window and emits "resolved" when the condition clears.
- Delivery to all enabled channels; a failure in one channel does not block the others.
- Each of Telegram, email and WhatsApp has a working "send test notification" action.
- Credentials are encrypted at rest and redacted from logs/UI.
- Alert history appears in the notification center and Activity Timeline.

---

## C — Runbook Scheduler — [#1](https://github.com/Arab-Open-Source/Marsad/issues/1)

**Problem.** Runbooks can only be executed manually. Repetitive operational work (nightly backups, daily certificate checks, weekly log cleanup) still needs a human.

**Scope**
- Cron-like schedules attached to a saved runbook (e.g. `0 2 * * *`), with timezone.
- Optional target servers and variable values stored with the schedule.
- Execution history: start/finish time, per-server result, rendered command.
- Pause/resume and manual "run now".
- Follow-up integration: Oban-based workers, reusing `Marsad.Snippets.render/2` and `Fleet.exec/3`.

**Acceptance criteria**
- A schedule can be created, edited, paused and deleted from the UI.
- Every execution produces an Activity Timeline entry and an in-app notification on failure.
- Overlapping runs of the same schedule are prevented.
- Schedules survive a restart of the release / container.

---

## E — Incident Mode / War Room — [#2](https://github.com/Arab-Open-Source/Marsad/issues/2)

**Problem.** During an incident the operator jumps between Overview, Metrics, Docker, systemd, nginx and Runbooks. There is no single view for a live incident.

**Scope**
- "Start incident" from any server or from Overview: pin a set of servers, set a title and severity.
- Single view combining: live metrics, recent Activity Timeline events, terminal shortcuts and suggested runbooks.
- Free-text incident notes persisted with timestamps and author.
- Timeline markers for actions taken during the incident (runbook runs, restarts).
- "Resolve incident" writes a summary to the Activity Timeline.

**Acceptance criteria**
- An incident can be started, annotated and resolved without leaving the page.
- Notes and linked events remain after a browser reload or LiveView reconnect.
- The incident is visible from Overview while active.

---

## F — Terminal Session Recording — [#3](https://github.com/Arab-Open-Source/Marsad/issues/3)

**Problem.** Terminal work is ephemeral; there is no way to review or share what happened in a session.

**Scope**
- Optional recording toggle per terminal window (off by default).
- Persist raw PTY output chunks (respecting the existing byte cap policy) to disk or DB, keyed by server/window/session id.
- Browser-based player: replay with timing, scrubbing and speed control.
- Retention policy (e.g. 7/30 days) and delete action.
- Recording state surfaced in the terminal toolbar pill.

**Acceptance criteria**
- Enabling recording does not add perceptible lag to the live terminal.
- A finished session can be replayed from the Activity Timeline or Runbooks area.
- Secrets typed into the terminal are not redacted automatically — the UI must warn before recording starts.

---

## G — Security Update Manager — [#4](https://github.com/Arab-Open-Source/Marsad/issues/4)

**Problem.** There is no way to see whether managed servers have pending security updates without opening a terminal on each one.

**Scope**
- Read-only scan across selected/all servers (`apt`/`yum` update lists) with a per-server count of available and security updates.
- Severity badges on Overview server cards.
- "Upgrade" is **not** automatic here — it is delegated to a Runbook with an explicit confirmation step.
- Cache scan results (e.g. 6h TTL) and support manual "rescan".

**Acceptance criteria**
- Scan never installs packages and never elevates privileges beyond the configured SSH user.
- Results include a timestamp and the package list for each server.
- A failed scan is reported per server without blocking the others.

---

## H — Reports & Export — [#5](https://github.com/Arab-Open-Source/Marsad/issues/5)

**Problem.** There is no shareable summary of fleet health for stakeholders or compliance.

**Scope**
- Weekly/monthly report generated from stored metrics snapshots, Activity Timeline and certificate expiry data.
- Formats: HTML (printable), CSV and PDF.
- Scheduled email delivery via the already-configured `Swoosh` adapter.
- Manual "generate now" with a date range picker.
- Report stored as a downloadable artifact with an audit entry.

**Acceptance criteria**
- A report contains uptime/status summary, alert-worthy metrics, audit events and SSL expiry table.
- Email delivery failures are surfaced in the Activity Timeline.
- Exports are read-only and cannot mutate server state.

---

## J — Multi-user & RBAC — [#6](https://github.com/Arab-Open-Source/Marsad/issues/6)

**Problem.** Marsad currently has a single local admin. Teams cannot share it safely: every user gets full SSH power and actions are indistinguishable in the audit log.

**Scope**
- Multiple local accounts (username + PBKDF2 hash, reusing `Marsad.Accounts`).
- Roles: **viewer** (read-only, no terminal/file write), **operator** (run runbooks, manage containers/services, terminal), **admin** (everything incl. server CRUD and user management).
- Per-action authorization in LiveView event handlers and download controllers.
- Session/login/logout already exist; extend `RequireAdmin` into a role-aware plug and keep `LiveAuth` in sync.
- Every audit entry records the acting user id.

**Acceptance criteria**
- A viewer cannot open a writable terminal, edit files, or change server/service state — server-side enforced, not just hidden in UI.
- Role changes take effect on the next request.
- Existing single-admin installations keep working after migration (admin role backfilled).

---

## Suggested delivery order

| Order | Feature | Why |
|---|---|---|
| 1 | **C — Scheduler** | Compounds the Runbooks feature shipped in 0.10.0 |
| 2 | **G — Security Update Manager** | High security value, read-only, reuses existing exec path |
| 3 | **A — Alerting + Channels** ([#7](https://github.com/Arab-Open-Source/Marsad/issues/7)) | Turns monitoring into proactive detection |
| 4 | **E — Incident Mode** | Needs alerts + Activity Timeline to be most useful |
| 5 | **F — Session Recording** | Benefits from RBAC + retention policy |
| 6 | **H — Reports** | Consumes data produced by the earlier features |
| 7 | **J — RBAC** | Cross-cutting; best designed before F/H expose more data |

> RBAC (J) should be designed before F and H if multiple users will share the instance, since both expose more data and new actions.
