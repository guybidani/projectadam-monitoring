# Vixy - External Uptime Monitor (BACKUP source)

External (off-VPS) uptime monitoring for the live production products, running
on **GitHub Actions**. **Since 2026-08-12 this is the BACKUP source, hourly.**
The primary is the Cloudflare Worker `vixy-worker-monitor` (true 5-min cron,
JSON-field checks, alerts to `support@vixy.co.il`; code in the vixy repo under
`infra/uptime-worker/`). This repo stays alive because it is the one vantage
that shares fate with **neither** the VPS **nor** Cloudflare, and because it
carries the deploy-drift check.

## The monitoring stack (who watches what)

| # | Source | Cadence | Vantage / blind spot | Alerts to |
|---|---|---|---|---|
| 1 - primary | Cloudflare Worker `vixy-worker-monitor` | every 5 min (real) | dies only with Cloudflare | `support@vixy.co.il` |
| 2 - on-host | VPS cron `vixy-health-monitor.sh` | every 5 min | dies with the VPS | Guy's gmail |
| 3 - backup | this repo (GitHub Actions) | hourly (`7 * * * *`) | dies with GitHub; some runner subnets are blackholed toward Hostinger (below) | `ALERT_TO` secret |

## Root cause of the HTTP 000 noise - diagnosed 2026-08-12

All seven targets resolve to **one origin IP** (`72.62.89.64`, Hostinger; plain
A records - no Cloudflare proxy, no AAAA). The false episodes were a **TCP
blackhole between some GitHub runner subnets and Hostinger's edge**:

- Every failed curl burned its **full 20 s `--max-time`** - probe spacing in the
  logs is exactly 180 s = 5 x 20 s timeouts + 4 x 20 s waits. SYNs silently
  dropped. Not DNS (fails fast; the zone is on Cloudflare DNS), not
  connection-refused (instant), not TLS (seconds).
- The **egress canary was UP in every blind record** (`google.com -> 204`) - the
  runner had internet, just not a path to that one IP.
- The VPS is clean: `ufw` inactive, `INPUT` policy ACCEPT, no fail2ban/crowdsec,
  conntrack 34/262144 - the drop is **upstream of the VPS**.
- Entire runs were blind start-to-finish (run `31453538743`: 02:49-05:55 UTC,
  every probe 000) while adjacent runs on other runners saw everything UP, and
  a home connection got `200` throughout - **vantage-specific**, i.e. specific
  runner subnets.

Timeouts, retries and IPv4-forcing cannot fix a path that is dead for hours
from that vantage. The fix is structural: the Worker (a vantage that works) is
primary, this monitor is an hourly backup behind the correlation gate, and
every future transport failure now self-documents (curl exit code + message +
runner egress IP in the `monitor-blind` log).

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

## Cadence - hourly backup, single pass

The cron is `7 * * * *` - one probing pass per hour. History for context: at
`*/5` GitHub throttled the schedule to a measured median gap of **56.8 min**
between run starts (96 h to 2026-08-09, 82 runs), which this repo once
compensated for with a 170-min in-job probe loop. That loop is gone: it pinned
a single runner for ~3 h, so one blackholed runner (see root cause above)
meant ~3 h of `HTTP 000` noise per episode. As a backup behind a true-5-min
primary, an hourly single pass from a fresh runner each time is strictly
better: coverage comes from the Worker, independence comes from here.

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

## The "second source" recommendation - CLOSED 2026-08-11/12

The independent off-GitHub prober this section used to ask for exists: the
Cloudflare Worker `vixy-worker-monitor` (deployed 11.8, negative-control
verified to the monitored inbox). On 12.8 it was made the **primary** and this
repo became the hourly backup - see the stack table at the top.
