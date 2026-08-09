# Vixy - External Uptime Monitor

External (off-VPS) uptime monitoring for the live production products.
Runs on **GitHub Actions** so it keeps watching even when the VPS itself is down.
That is also why it stays on GitHub: a monitor hosted on the server it watches
reports nothing at the only moment that matters.

## What it watches - 7 targets

Customers are on `vixy.co.il` since the 29.7 rebrand; the old
`*.projectadam.co.il` subdomains are only an OAuth safety net and are not watched.

| Target | Endpoint | Check |
|---|---|---|
| Project Adam | `https://projectadam.co.il/` | 200 + real HTML `<title>` |
| Vixy Ads | `https://vixy.co.il/api/health` | 200 + no failed JSON field |
| Vixy CRM | `https://crm.vixy.co.il/health` | 200 + no failed JSON field |
| Vixy Coach | `https://coach.vixy.co.il/api/health` | 200 + no failed JSON field |
| Vixy Ads login | `https://vixy.co.il/login` | 200 + real HTML `<title>` |
| Vixy CRM login | `https://crm.vixy.co.il/login` | 200 + real HTML `<title>` |
| Vixy Coach login | `https://coach.vixy.co.il/login` | 200 + real HTML `<title>` |

The `/login` routes are watched because a green `/health` can sit in front of an
app route that 5xxs.

## How often it really runs - measured, not claimed

The cron line says `*/5`. **GitHub does not honour it**, and it cannot be forced.
Measured over the 96 h to 2026-08-09 20:13 UTC (82 probing runs):

| | measured |
|---|---|
| median gap between scheduled run **starts** | **56.8 min** (mean 71.8, worst 350) |
| wall-clock **coverage** before the fix (50-min probing window) | **71.6 %** |
| blind windows in those 96 h | **31** - median 31 min, p90 116 min, worst **5.6 h** |

So the honest claim is **not** "every 5 minutes". What is true: *while a job is
running* it probes every 5 minutes; the gaps are GitHub's scheduler.

The fix is the in-job probing window (`PROBE_WINDOW_MIN`, currently **170 min**):
one job keeps probing on a 5-min loop for ~3 h, and because the concurrency group
is never cancelled in-progress, GitHub parks the next run behind it and starts it
the moment this one ends. Replaying the same real start times:

| probing window | wall-clock coverage | blind windows | worst |
|---|---|---|---|
| 50 min (old) | 65 % | 56 | 300 min |
| 110 min | 89 % | 8 | 240 min |
| **170 min (now)** | **95 %** | **5** | 180 min |
| 230 min | 98 % | 2 | 120 min |
| 350 min | 100 % | 0 | - |

170 was chosen over 350 because a pushed fix only reaches production when the
running job ends - 350 would mean a ~6 h lag on every change.

**Full coverage needs a second, independent source** (an off-GitHub prober).
That requires opening an account, which is Guy's call - see the recommendation
at the bottom.

## Correlation gate - why alerts are trustworthy again

Measured 9.8: **70 outage issues since 5.8 - exactly 10 per target, all seven
always falling together.** On 9.8 alone, 28 issues → 56 emails in one day, every
one of them false. Run `31321711799` saw `HTTP 000` on all seven for 56 minutes
straight; the next run found all seven UP in 21 seconds; and the same seven URLs
answered `200` from a home connection the whole time. The failure was the
runner's network, not the products.

A monitor that cries wolf 56 times a day is not a monitor - it trains its reader
to ignore it, so the first real outage looks exactly like the 56 before it. The
gate:

1. **Every target failing, all of them transport-class (`HTTP 000`) → no product
   alert.** Products do not fail in perfect lockstep with no HTTP response at
   all; a runner's network does. The run is logged on the rolling
   `monitor-blind` issue and sends **no** outage mail.
   - This is deliberately **not** "N of 7". A **subset** failing is a real outage
     and is always alerted. A gate that also silences real failures would be far
     worse than the noise.
   - All seven failing with **app**-class codes (5xx / degraded - the server did
     answer) is **not** suppressed: that is a real full-stack failure.
2. **Transport vs app are different states.**
   `HTTP 000` (no response: DNS/connect/TLS/timeout) gets a bigger retry budget
   (5 × 20 s vs 3 × 15 s) **and** is cross-checked against an independent **egress
   canary** - three unrelated hosts. If none of them answers, the runner has no
   network and an `HTTP 000` says nothing about our products, so transport
   failures are suppressed. App-class failures still alert even then.
3. **One grouped email per run, never one per target.** Seven mails about one
   event are seven reasons to delete unread. The subject carries the blast radius:
   `🔴 תקלה (3/7): Vixy CRM, Vixy CRM login, Vixy Coach` - how many, and who.
   Recovery is grouped the same way: `✅ חזרו לפעול (2): …`.

GitHub Issues stay the dedup state: one email per outage, one on recovery. A
blind run never closes an open outage issue - no measurement is not evidence of
recovery.

## Deploy-drift check

Also compares the commit each app **serves** at `/health` (`SOURCE_COMMIT`,
injected by Coolify at deploy time) against its repo HEAD - a green `/health`
does not prove a deploy landed (two swaps silently failed on 2026-07-22).
Alerts only after `DRIFT_MAX_AGE_MIN` (60) so normal deploy lag stays quiet.
Needs the optional `REPO_HEAD_TOKEN` secret; unset → the whole check is a no-op.

## Config

Secrets (Settings → Secrets → Actions):
- `RESEND_API_KEY` - Resend key. Send-only; `GET /emails` returns 401, so
  delivery cannot be verified through the API - verify over IMAP on the mailbox.
- `ALERT_TO` - recipient.
- `REPO_HEAD_TOKEN` - optional, read-only PAT for the drift check.

Sender is `noreply@vixy.co.il`: `projectadam.co.il` lost Resend verification in
the 29.7 rebrand and mail from it was silently rejected.

`GITHUB_TOKEN` is auto-provided; the workflow grants it `issues: write`.

## Drill mode - how to re-verify the gate without touching production

Both sides of the gate must be re-provable at any time, against synthetic
targets, without mailing Guy:

```bash
export ALERT_TO="a-test-mailbox@example.com"       # never Guy's address
export RESEND_API_KEY="…"
export MONITOR_DRY_RUN=1                            # decide + print, send nothing
export MONITOR_TARGETS_FILE=./drill-targets.txt     # "name|url|type" per line
bash check.sh
```

- `MONITOR_TARGETS_FILE` - replaces the target list (`name|url|type`). Use
  `*.invalid` hostnames for guaranteed `HTTP 000`.
- `MONITOR_DRY_RUN=1` - prints the decision and the subject it *would* send;
  creates no issue, sends no mail.
- `EGRESS_CANARIES` - point at unreachable hosts to simulate a blind runner.
- `RETRIES` / `RETRY_WAIT` / `TRANSPORT_RETRIES` / `TRANSPORT_RETRY_WAIT` -
  shorten the waits so a drill finishes in seconds.
- `MONITOR_BLIND_NOTIFY=1` - opt in to a blind-runner notice by mail. Off by
  default: it is worded as "no measurement", never as a product outage.

The four cases that must keep holding:

| drill | expected |
|---|---|
| 7/7 targets `HTTP 000` | **no** issue, **no** mail, one `monitor-blind` entry |
| subset fails, canary UP | **one** grouped mail naming them |
| 7/7 fail with 404/5xx | alert **is** sent (transport worked) |
| canary DOWN + mixed | transport suppressed, app-class **still** alerts |

## Manual run / self-test

Actions → `uptime-monitor` → **Run workflow** → set `selftest = true`
to send one clearly-marked test email and confirm delivery.

## Why this repo is public

GitHub Actions minutes are **unlimited on public repos**, metered (2000/mo) on
private ones. This repo holds **no secrets** (only public domain names + health
paths; the API key lives in encrypted Actions Secrets), so public is safe and
free. Product repos stay private.

## Open recommendation - the second source

Coverage is capped at ~95 % because everything here depends on one scheduler on
one network. A second independent prober would both close the remaining gap and
turn the egress canary into a real cross-check. It needs an account, so it is
Guy's decision, not the fleet's - see the handover note.
