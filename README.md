# Project Adam — External Uptime Monitor

External (off-VPS) uptime monitoring for the four production products.
Runs on **GitHub Actions** so it keeps watching even when the VPS itself is down.

## What it watches (every 5 minutes)

| Product | Endpoint | Check |
|---|---|---|
| Project Adam | `https://projectadam.co.il/` | HTTP 200 + real HTML `<title>` |
| Vixy | `https://vixy.projectadam.co.il/api/health` | 200 + no failed JSON field |
| Vixy CRM | `https://crm.projectadam.co.il/health` | 200 + `db`/`redis` not down |
| Kolio | `https://kolio.projectadam.co.il/api/health` | 200 + `app`/`db`/`redis`/`workers` not down |

## How alerting works

- A failure is **retried 3× (15s apart)** before it counts — kills false positives
  from zero-downtime deploys and momentary blips.
- On a real outage: opens a GitHub Issue labelled `outage` **and** emails Guy
  (via Resend, `noreply@projectadam.co.il`).
- The open issue is the dedup state: **one email per outage**, not one every 5 min.
- On recovery: closes the issue and sends a "back up" email.

## Config

Secrets (Settings → Secrets → Actions):
- `RESEND_API_KEY` — Resend API key (domain `projectadam.co.il`, verified).
- `ALERT_TO` — recipient (`guy.bidaniii@gmail.com`).

`GITHUB_TOKEN` is auto-provided; the workflow grants it `issues: write`.

## Why this repo is public

GitHub Actions minutes are **unlimited on public repos**, metered (2000/mo) on
private ones — a 5-minute cron would blow the private quota. This repo holds
**no secrets** (only public domain names + health paths; the API key lives in
encrypted Actions Secrets), so public is safe and free. Product repos stay private.

## Manual run / self-test

Actions → `uptime-monitor` → **Run workflow** → set `selftest = true`
to send one clearly-marked test email and confirm delivery.
