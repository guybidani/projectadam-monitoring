#!/usr/bin/env bash
# Vixy - external uptime monitor. BACKUP source since 2026-08-12.
# Runs from GitHub Actions (off-VPS), so it stays up even when the VPS is down.
# The PRIMARY uptime source is the Cloudflare Worker `vixy-worker-monitor`
# (true 5-min cron, JSON-field checks, alerts to support@vixy.co.il). This
# workflow is the independent second vantage (shares fate with neither the VPS
# nor Cloudflare) and carries the deploy-drift check.
#
# ROOT CAUSE of the HTTP 000 noise (diagnosed 2026-08-12): a TCP blackhole
# between some GitHub runner subnets and Hostinger's edge (72.62.89.64 - the
# single origin IP behind ALL targets: A records only, no Cloudflare proxy,
# no AAAA). Every failed curl burned its full 20s --max-time (probe spacing
# exactly 180s = 5x20s timeout + 4x20s wait), i.e. SYNs silently dropped -
# not DNS (fails fast; the zone is on Cloudflare DNS), not refused (instant),
# not TLS (seconds). Not the VPS either: INPUT policy ACCEPT, no
# fail2ban/crowdsec, ufw inactive, conntrack 34/262144. Entire runs are blind
# start-to-finish (run 31453538743: 02:49-05:55 UTC, every probe 000, canary
# UP) while adjacent runs see all UP - the drop is upstream of the VPS and
# vantage-specific. Unfixable from our side; hence backup role + the gate.
#
# Alerting rules (see README "Correlation gate" - do not soften these):
#   1. CORRELATION GATE. If *every* target fails in the same run and every one of
#      those failures is transport-class (HTTP 000 - no response at all), the
#      runner could not reach the network. That is not seven products failing in
#      lockstep. Measured 9.8: run 31321711799 saw HTTP 000 on all 7 targets for
#      56 min straight, the next run found all 7 UP in 21 s, and the same 7 URLs
#      answered 200 from a home connection throughout. 70 outage issues since
#      5.8 = exactly 10 per target, all falling together - all of them false.
#      Such a run is recorded (label `monitor-blind`) and sends NO product alert.
#      A SUBSET failing is a real outage and is always alerted.
#      All targets failing with *app*-class codes (5xx/degraded - transport
#      worked) is NOT suppressed: that is a real full-stack failure.
#      SECOND VANTAGE (added 12.8): a genuinely dead origin looks EXACTLY like a
#      blackhole from here - all 7 on one IP, every probe times out, canary UP.
#      So before suppressing, ask the Cloudflare Worker (independent network). If
#      it also sees the products down, the gate is overridden and we alert. Blind
#      is silent, and silence must never be the answer to a real outage.
#   2. ONE GROUPED EMAIL PER RUN. Never one per target. Seven mails about one
#      event are seven reasons to delete unread. The subject says how many and who.
#   3. Transport (HTTP 000) and app (5xx / degraded / error page) are different
#      states. Transport failures get a longer retry budget and are cross-checked
#      against an independent egress canary before they can become an event.
#
# GitHub Issues remain the dedup state: one email per outage, one on recovery.
#
# Usage:
#   bash check.sh              # normal monitoring run
#   bash check.sh selftest     # send one clearly-marked test email (proves the pipe)
#
# Drill / override env (all optional - production sets none of them):
#   MONITOR_TARGETS_FILE  file of "name|url|type" lines, replaces the target list
#   MONITOR_DRY_RUN=1     decide and print, but create no issue and send no email
#   ALERT_TO              recipient (drills point this at a test mailbox)
#   RETRIES / RETRY_WAIT / TRANSPORT_RETRIES / TRANSPORT_RETRY_WAIT
#   EGRESS_CANARIES       space-separated URLs used to prove the runner has network
#   WORKER_STATUS_URL     second-vantage endpoint (empty string disables the check)
#   MONITOR_BLIND_NOTIFY=1  also email (a distinctly-worded, non-outage) notice
#                           when the runner is blind; off by default on purpose
set -uo pipefail

REPO="${GITHUB_REPOSITORY:-guybidani/projectadam-monitoring}"
ALERT_TO="${ALERT_TO:?ALERT_TO not set}"
RESEND_API_KEY="${RESEND_API_KEY:?RESEND_API_KEY not set}"
# vixy.co.il is the Resend-verified sender domain (projectadam.co.il lost
# verification in the 29.7 rebrand - alerts from it were silently rejected).
FROM="Vixy Monitor <noreply@vixy.co.il>"

RETRIES="${RETRIES:-3}"
RETRY_WAIT="${RETRY_WAIT:-15}"
# A transport failure is the one that lies most often (see the gate above), so it
# earns a bigger, more patient retry budget than a clear app-level error code.
TRANSPORT_RETRIES="${TRANSPORT_RETRIES:-5}"
TRANSPORT_RETRY_WAIT="${TRANSPORT_RETRY_WAIT:-20}"
# Independent second source: three unrelated networks. If NONE of them answers,
# the runner itself has no egress and any HTTP 000 says nothing about our products.
EGRESS_CANARIES="${EGRESS_CANARIES:-https://www.google.com/generate_204 https://cloudflare.com/cdn-cgi/trace https://api.github.com/zen}"
MONITOR_DRY_RUN="${MONITOR_DRY_RUN:-0}"
MONITOR_BLIND_NOTIFY="${MONITOR_BLIND_NOTIFY:-0}"
BLIND_RECORD_COOLDOWN_MIN="${BLIND_RECORD_COOLDOWN_MIN:-30}"
STATE_DIR="${MONITOR_STATE_DIR:-${RUNNER_TEMP:-/tmp}}"
BLIND_ISSUE_TITLE="🌐 MONITOR BLIND: runner could not reach the network"

# name | url | type(health|page)
# vixy.co.il domains are what customers use since the 29.7 rebrand; the old
# *.projectadam.co.il subdomains are only an OAuth safety net - not monitored.
TARGETS=(
  "Project Adam|https://projectadam.co.il/|page"
  "Vixy Ads|https://vixy.co.il/api/health|health"
  "Vixy CRM|https://crm.vixy.co.il/health|health"
  "Vixy Coach|https://coach.vixy.co.il/api/health|health"
  # Real app routes beyond /health: a 5xx / error page on the login route is an
  # app-level failure that a green /health can miss (5.8 gate, parameter 14).
  "Vixy Ads login|https://vixy.co.il/login|page"
  "Vixy CRM login|https://crm.vixy.co.il/login|page"
  "Vixy Coach login|https://coach.vixy.co.il/login|page"
)

# Drills replace the target list with synthetic hosts so both sides of the
# correlation gate can be exercised without touching the products.
if [ -n "${MONITOR_TARGETS_FILE:-}" ]; then
  [ -r "$MONITOR_TARGETS_FILE" ] || { echo "targets file unreadable: $MONITOR_TARGETS_FILE" >&2; exit 2; }
  TARGETS=()
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(printf '%s' "$line" | tr -d '\r')"
    case "$line" in ''|'#'*) continue ;; esac
    TARGETS+=("$line")
  done < "$MONITOR_TARGETS_FILE"
  [ "${#TARGETS[@]}" -gt 0 ] || { echo "targets file has no entries" >&2; exit 2; }
fi

# --- deploy-drift check -----------------------------------------------------
# Does the commit each app SERVES at /health match its repo HEAD? The /health
# "commit" field is process.env.SOURCE_COMMIT - Coolify injects the deployed git
# SHA as a runtime env on every deploy, so it reflects what is ACTUALLY running
# (= the image tag), not the source tree. A green /health does NOT prove a deploy
# landed (two swaps silently failed on 2026-07-22); this catches that.
# Alert only when a drift persists past DRIFT_MAX_AGE_MIN - a normal deploy lags
# a few minutes; a stuck/failed swap lingers. Needs REPO_HEAD_TOKEN (read-only
# PAT, contents:read) to read private-repo HEADs; unset -> whole check is a no-op.
# Per app: a missing / "unknown" commit = not yet instrumented -> skipped (safe
# rollout - each product lights up once it ships the /health commit field).
# name | health_url | repo | branch
DRIFT_TARGETS=(
  "Vixy Ads|https://vixy.co.il/api/health|guybidani/vixy|master"
  "Vixy CRM|https://crm.vixy.co.il/health|guybidani/vixy-crm|master"
  "Vixy Coach|https://coach.vixy.co.il/api/health|guybidani/kolio|master"
  "Project Adam|https://projectadam.co.il/api/health|guybidani/project-adam-website|main"
)
DRIFT_MAX_AGE_MIN="${DRIFT_MAX_AGE_MIN:-60}"

BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT

log()  { echo "$@"; }
summ() { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo -e "$1" >> "$GITHUB_STEP_SUMMARY" || true; }
esc()  { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# --- email via Resend -------------------------------------------------------
send_email() {
  local subject="$1" html="$2" resp payload
  if [ "$MONITOR_DRY_RUN" = "1" ]; then
    log "   [dry-run] WOULD SEND -> $ALERT_TO"
    log "   [dry-run] SUBJECT: $subject"
    return 0
  fi
  # Build the JSON with python3 (present on GitHub runners; correct escaping for
  # Hebrew/quotes/newlines). Values passed via env, never interpolated -> no injection.
  payload=$(SUBJECT="$subject" HTML="$html" MFROM="$FROM" MTO="$ALERT_TO" python3 -c 'import json,os
print(json.dumps({"from":os.environ["MFROM"],"to":[os.environ["MTO"]],"subject":os.environ["SUBJECT"],"html":os.environ["HTML"]}))')
  resp=$(curl -sS -X POST https://api.resend.com/emails \
    -H "Authorization: Bearer $RESEND_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload")
  if echo "$resp" | grep -q '"id"'; then
    log "   ✉️  email sent: $(echo "$resp" | sed -E 's/.*"id":"([^"]+)".*/\1/')"
    return 0
  fi
  log "   ⚠️  email FAILED: $resp"
  return 1
}

# --- one probe --------------------------------------------------------------
# Sets PROBE_CLASS (up|transport|app) and PROBE_DETAIL; returns 0 when UP.
#   transport = no HTTP response at all (DNS / connect / TLS / timeout) -> the
#               failure may be on OUR side of the wire, so it is never trusted alone
#   app       = the server answered and the answer is bad (5xx, 4xx, degraded
#               JSON, error page) -> transport worked, this is a real signal
PROBE_CLASS="up"; PROBE_DETAIL="UP"
probe() {
  local url="$1" type="$2" code rc curl_err
  curl_err="$(mktemp)"
  code=$(curl -sS -o "$BODY_FILE" -w "%{http_code}" --max-time 20 "$url" 2>"$curl_err"); rc=$?
  code="${code:-000}"
  if [ "$code" = "000" ]; then
    # Name the transport failure precisely: curl's exit code + message
    # (6=DNS, 7=refused, 28=timeout, 35=TLS). A bare "HTTP 000" hid the root
    # cause for a week - never discard this again (12.8 diagnosis).
    PROBE_CLASS="transport"
    PROBE_DETAIL="HTTP 000 (curl exit $rc: $(tr -d '\n' < "$curl_err" | head -c 160))"
    rm -f "$curl_err"; return 1
  fi
  rm -f "$curl_err"
  if [ "$code" != "200" ]; then
    PROBE_CLASS="app"; PROBE_DETAIL="HTTP $code"; return 1
  fi
  if [ "$type" = "health" ]; then
    # any JSON field explicitly reporting a failure state = degraded.
    # EXCEPT config-state fields: `phoneWall` reports whether the signup phone
    # wall is ARMED (a hand-set product decision, Guy 2026-09-02 - absent means
    # down BY DESIGN), not whether something broke. Coach serves it as the
    # string "down", which this grep read as an outage (false alarm #76).
    # Strip it before classifying; a real failure still has its own field.
    if sed -E 's/"phoneWall"[[:space:]]*:[[:space:]]*"[a-z]+"//Ig' "$BODY_FILE" \
       | grep -qiE '"[a-z_]+"[[:space:]]*:[[:space:]]*"(down|error|fail|failed|unhealthy|degraded)"'; then
      PROBE_CLASS="app"; PROBE_DETAIL="degraded $(tr -d '\n' < "$BODY_FILE" | head -c 160)"; return 1
    fi
  else
    # a page must look like real HTML, not a proxy error body
    if ! grep -qi "<title" "$BODY_FILE"; then
      PROBE_CLASS="app"; PROBE_DETAIL="200 but no HTML title (possible error page)"; return 1
    fi
  fi
  PROBE_CLASS="up"; PROBE_DETAIL="UP"; return 0
}

# --- probe with retries (kills false positives from deploy blips / momentary 5xx)
# The budget grows once we know the failure is transport-class.
probe_stable() {
  local url="$1" type="$2" i=1 budget="$RETRIES" wait="$RETRY_WAIT"
  while :; do
    if probe "$url" "$type"; then return 0; fi
    if [ "$PROBE_CLASS" = "transport" ]; then budget="$TRANSPORT_RETRIES"; wait="$TRANSPORT_RETRY_WAIT"; fi
    [ "$i" -ge "$budget" ] && return 1
    i=$((i + 1))
    sleep "$wait"
  done
}

# --- independent egress canary ---------------------------------------------
# UP if ANY unrelated host answers with any HTTP status. Only called when at
# least one target failed, so a healthy run costs no extra requests.
CANARY_HIT=""
canary_up() {
  local u code
  for u in $EGRESS_CANARIES; do
    code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 15 "$u" 2>/dev/null)
    code="${code:-000}"
    if [ "$code" != "000" ]; then CANARY_HIT="$u -> HTTP $code"; return 0; fi
  done
  CANARY_HIT="none of: $EGRESS_CANARIES"
  return 1
}

# --- independent SECOND VANTAGE: the Cloudflare Worker ---------------------
# The gap the correlation gate leaves open (found 12.8 by drill): a real total
# outage of the origin and a runner-side blackhole produce the IDENTICAL
# signature here - every target transport-class HTTP 000, egress canary UP. All
# 7 targets sit on one IP (72.62.89.64), so if that host or Hostinger's edge
# dies, every probe times out exactly like a blackhole and the gate suppresses
# it. Blind is silent by design, so a total outage would be SILENT in this
# monitor. Asking the Worker converts "no information" into information: it
# probes the same three products from Cloudflare's network - a vantage sharing
# fate with neither this runner nor the VPS.
#   products-down -> real outage: alert even though everything looks blind
#   products-ok   -> runner-side blindness confirmed: suppress (unchanged)
#   unavailable   -> no new information: suppress (unchanged)
# Can only ever ADD an alert where the monitor is silent today; it never
# suppresses anything that alerts today.
WORKER_STATUS_URL="${WORKER_STATUS_URL:-https://vixy-worker-monitor.vixy-infra.workers.dev/status}"
SECOND_OPINION="not-checked"; SECOND_OPINION_DETAIL=""
second_opinion() {
  local body rc parsed
  if [ -z "$WORKER_STATUS_URL" ]; then
    SECOND_OPINION="unavailable"; SECOND_OPINION_DETAIL="no worker URL configured"; return
  fi
  body=$(curl -sS --max-time 25 "$WORKER_STATUS_URL" 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$body" ]; then
    SECOND_OPINION="unavailable"; SECOND_OPINION_DETAIL="worker unreachable (curl exit $rc)"; return
  fi
  parsed=$(BODY="$body" python3 -c '
import json, os, sys
try:
    live = json.loads(os.environ["BODY"]).get("live")
except Exception:
    print("unavailable|worker answered unparseable JSON"); sys.exit()
if not isinstance(live, list) or not live:
    print("unavailable|worker answered without a live[] array"); sys.exit()
bad = [t.get("name", "?") for t in live if t.get("ok") is not True]
if bad:
    print("products-down|worker also sees DOWN: " + ", ".join(bad))
else:
    print("products-ok|worker sees all %d products UP from Cloudflare" % len(live))
' 2>/dev/null)
  if [ -z "$parsed" ]; then
    SECOND_OPINION="unavailable"; SECOND_OPINION_DETAIL="could not parse worker answer"; return
  fi
  SECOND_OPINION="${parsed%%|*}"; SECOND_OPINION_DETAIL="${parsed#*|}"
}

# --- open outage issues: fetched ONCE per run, matched locally -------------
# One API call instead of one per target. The workflow keeps a single job alive
# for hours probing on a loop, so per-target calls added up against the
# GITHUB_TOKEN hourly rate limit for no benefit.
OPEN_OUTAGES=""
load_open_outages() {
  OPEN_OUTAGES=$(gh issue list --repo "$REPO" --state open --label outage --limit 200 \
    --json number,title --jq '.[] | "\(.number)\t\(.title)"' 2>/dev/null)
}
find_issue() {
  [ -z "$OPEN_OUTAGES" ] && return 0
  printf '%s\n' "$OPEN_OUTAGES" | awk -F'\t' -v t="🔴 OUTAGE: $1" '$2==t {print $1; exit}'
}

# --- runner egress IP (fetched once, only on failure paths) ----------------
# Lets blind episodes be correlated by runner subnet across occurrences - the
# 12.8 diagnosis showed the blackhole is vantage-specific.
RUNNER_EGRESS_IP=""
runner_ip() {
  if [ -z "$RUNNER_EGRESS_IP" ]; then
    RUNNER_EGRESS_IP=$(curl -sS --max-time 10 https://api.ipify.org 2>/dev/null || true)
    RUNNER_EGRESS_IP="${RUNNER_EGRESS_IP:-unknown}"
  fi
  printf '%s' "$RUNNER_EGRESS_IP"
}

# --- record a blind run (no product alert, no email by default) ------------
# One rolling issue, one comment per episode, cooldown-limited. This is the
# evidence trail for fixing the runner's network - it is deliberately NOT mail.
record_blind() {
  local ts="$1" reason="$2" detail="$3" num now last f
  now=$(date -u +%s)
  f="$STATE_DIR/vixy-monitor-blind-last"
  last=$(cat "$f" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $(( now - last )) -lt $(( BLIND_RECORD_COOLDOWN_MIN * 60 )) ]; then
    log "   (blind episode already recorded $(( (now - last) / 60 ))m ago - ${BLIND_RECORD_COOLDOWN_MIN}m cooldown)"
    return 0
  fi
  if [ "$MONITOR_DRY_RUN" = "1" ]; then
    log "   [dry-run] WOULD RECORD blind episode: $reason"
    return 0
  fi
  echo "$now" > "$f" 2>/dev/null || true
  gh label create monitor-blind --repo "$REPO" --color 0E8A16 \
    --description "monitor runner had no network - NOT a product outage" >/dev/null 2>&1 || true
  num=$(gh issue list --repo "$REPO" --state open --label monitor-blind --json number,title \
        --jq "map(select(.title==\"$BLIND_ISSUE_TITLE\")) | .[0].number // empty" 2>/dev/null)
  if [ -z "$num" ]; then
    gh issue create --repo "$REPO" --label monitor-blind --title "$BLIND_ISSUE_TITLE" \
      --body "$(printf 'Rolling log of runs where the monitor could not reach the network.\nThese are NOT product outages and never send an outage email - see the correlation gate in check.sh.\n\n- %s - %s\n%s\n' "$ts" "$reason" "$detail")" \
      >/dev/null 2>&1 || log "   ⚠️  could not open blind-log issue"
  else
    gh issue comment "$num" --repo "$REPO" \
      --body "$(printf '%s - %s\n%s\n' "$ts" "$reason" "$detail")" >/dev/null 2>&1 || true
  fi
  if [ "$MONITOR_BLIND_NOTIFY" = "1" ]; then
    # Deliberately a different KIND of message: it never claims a product is down.
    send_email "🌐 הניטור לא הצליח לצאת לרשת (אין מדידה - לא תקלה במוצרים)" \
      "<div dir=rtl style='font-family:Arial'><h2 style='color:#555'>🌐 אין מדידה בריצה הזו</h2>
       <p>שרת הבדיקה של GitHub לא הצליח לצאת לרשת, ולכן <b>אין לנו מידע</b> על מצב המוצרים בריצה הזו.
       זו <b>אינה</b> הודעה על נפילת מוצר.</p>
       <p><b>זמן:</b> $(esc "$ts")<br><b>סיבה:</b> $(esc "$reason")</p></div>"
  fi
}

# --- drift helpers ---------------------------------------------------------
# the commit an app serves at /health (empty if absent / "unknown" / not JSON)
running_commit() {
  curl -sS --max-time 20 "$1" 2>/dev/null | python3 -c 'import sys,json
try:
  c=(json.load(sys.stdin).get("commit") or "").strip()
  print("" if c in ("","unknown") else c)
except Exception:
  print("")'
}
# HEAD sha of repo@branch via the GitHub API (empty on any error)
head_commit() {
  curl -sS --max-time 20 \
    -H "Authorization: Bearer $REPO_HEAD_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$1/commits/$2" 2>/dev/null | python3 -c 'import sys,json
try: print((json.load(sys.stdin).get("sha") or "").strip())
except Exception: print("")'
}
# commits are equal if the shorter (>=7 chars) is a prefix of the longer.
# Apps report SOURCE_COMMIT at different abbreviations (Vixy full 40-char, CRM
# 7-char); the GitHub API returns the full 40-char sha. Prefix match keeps the
# monitor correct no matter how each app truncates its commit field.
commits_match() {
  local a="$1" b="$2" short long
  { [ -z "$a" ] || [ -z "$b" ]; } && return 1
  if [ "${#a}" -le "${#b}" ]; then short="$a"; long="$b"; else short="$b"; long="$a"; fi
  [ "${#short}" -ge 7 ] || return 1
  case "$long" in "$short"*) return 0 ;; *) return 1 ;; esac
}
# open drift issue number for a target (empty if none)
find_drift_issue() {
  gh issue list --repo "$REPO" --state open --label drift --json number,title \
    --jq "map(select(.title==\"🟡 DRIFT: $1\")) | .[0].number // empty" 2>/dev/null
}
# minutes since an issue was created (0 if unknown)
issue_age_min() {
  local created
  created=$(gh issue view "$1" --repo "$REPO" --json createdAt --jq .createdAt 2>/dev/null)
  [ -z "$created" ] && { echo 0; return; }
  python3 -c 'import sys,datetime
try:
  c=datetime.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00"))
  print(int((datetime.datetime.now(datetime.timezone.utc)-c).total_seconds()//60))
except Exception:
  print(0)' "$created"
}
# has this issue already been emailed about?
issue_has_alerted() {
  gh issue view "$1" --repo "$REPO" --json labels \
    --jq 'any(.labels[]; .name=="drift-alerted")' 2>/dev/null | grep -q true
}

# --- self-test: prove the alert pipe reaches the recipient -----------------
if [ "${1:-}" = "selftest" ]; then
  log "=== SELF-TEST ==="
  # 1) prove DOWN detection works against a guaranteed-404 (no email)
  probe "https://projectadam.co.il/__uptime_selftest_should_404__" page || true
  log "detection check (expect app/HTTP 404): $PROBE_CLASS - $PROBE_DETAIL"
  # 2) prove Resend delivery end-to-end (one marked email)
  ts=$(date -u +"%Y-%m-%d %H:%M UTC")
  send_email "✅ [בדיקת מערכת] ניטור Vixy פעיל" \
    "<div dir=rtl style='font-family:Arial'><h2>✅ מערכת הניטור פעילה</h2>
     <p>זו הודעת בדיקה חד-פעמית שמאשרת שהתראות הניטור מגיעות אליך.</p>
     <p>נבדקים 7 יעדים על דומייני vixy.co.il החיים, מ-GitHub (מחוץ לשרת). קצב הבדיקה בפועל
     ומידת הכיסוי מתועדים ב-README - GitHub לא מריץ את התזמון בדיוק כל 5 דקות.</p>
     <p>תקבל מייל רק אם משהו נופל באמת, ומייל נוסף כשהוא חוזר. מייל אחד לריצה שמרכז את כל
     היעדים - לא מייל ליעד.</p>
     <p style='color:#888'>זמן: $ts · אפשר להתעלם מהודעה זו.</p></div>"
  log "=== SELF-TEST DONE ==="
  exit 0
fi

# --- main monitoring loop ---------------------------------------------------
# The outage label must exist or `gh issue create --label outage` fails and the
# whole dedup/recovery state machine silently never engages (bit us 5.8: three
# real alerts went out, zero issues created, no recovery emails).
if [ "$MONITOR_DRY_RUN" != "1" ]; then
  gh label create outage --repo "$REPO" --color B60205 --description "product is DOWN (auto-managed by uptime monitor)" >/dev/null 2>&1 || true
fi

RUN_TS=$(date -u +"%Y-%m-%d %H:%M UTC")

# ---- pass 1: probe everything, decide nothing -----------------------------
T_NAME=(); T_URL=(); T_CLASS=(); T_DETAIL=()
n_total=0; n_failed=0; n_transport=0; n_app=0
for entry in "${TARGETS[@]}"; do
  IFS='|' read -r name url type <<< "$entry"
  probe_stable "$url" "$type" || true
  T_NAME+=("$name"); T_URL+=("$url"); T_CLASS+=("$PROBE_CLASS"); T_DETAIL+=("$PROBE_DETAIL")
  n_total=$((n_total + 1))
  case "$PROBE_CLASS" in
    up)        log "✅ $name - UP" ;;
    transport) n_failed=$((n_failed + 1)); n_transport=$((n_transport + 1)); log "❌ $name - [transport] $PROBE_DETAIL" ;;
    app)       n_failed=$((n_failed + 1)); n_app=$((n_app + 1));             log "❌ $name - [app] $PROBE_DETAIL" ;;
  esac
done

# ---- pass 2: the correlation gate ----------------------------------------
# BLIND_ALL: the measured false pattern - every single target, all of them with
# no HTTP response. Products do not fail like that; a runner's network does.
# Not "N of 7": a subset is a real outage and stays alertable.
BLIND_ALL=0; SUPPRESS_TRANSPORT=0; EGRESS="not-checked"; GATE_REASON=""
if [ "$n_failed" -gt 0 ]; then
  if canary_up; then EGRESS="up"; else EGRESS="down"; fi
  log "egress canary: $EGRESS ($CANARY_HIT)"
  if [ "$n_failed" -eq "$n_total" ] && [ "$n_transport" -eq "$n_failed" ]; then
    BLIND_ALL=1
    GATE_REASON="all $n_total/$n_total targets returned HTTP 000 in the same run - runner network, not the products"
  fi
  if [ "$EGRESS" = "down" ]; then
    SUPPRESS_TRANSPORT=1
    GATE_REASON="${GATE_REASON:+$GATE_REASON; }egress canary unreachable ($CANARY_HIT) - HTTP 000 says nothing about our products"
  fi
fi
# Before trusting the gate, get the independent second vantage. Blind is silent,
# and silence must never be the answer to a real outage that merely LOOKS blind.
if [ "$BLIND_ALL" = "1" ] || [ "$SUPPRESS_TRANSPORT" = "1" ]; then
  second_opinion
  log "second vantage (worker): $SECOND_OPINION - $SECOND_OPINION_DETAIL"
  if [ "$SECOND_OPINION" = "products-down" ]; then
    BLIND_ALL=0; SUPPRESS_TRANSPORT=0
    GATE_REASON=""
    log ""
    log "🔴 GATE OVERRIDDEN by the second vantage: $SECOND_OPINION_DETAIL"
    log "   -> this is a real outage that only looked like runner blindness; alerting"
  fi
fi
if [ -n "$GATE_REASON" ]; then
  log ""
  log "🌐 CORRELATION GATE: $GATE_REASON"
  log "   -> no outage issue, no outage email for the suppressed targets"
  log "   (second vantage: $SECOND_OPINION - $SECOND_OPINION_DETAIL)"
fi

summ "### Uptime check - $RUN_TS\n\n| Target | Class | Status |\n|---|---|---|"

# ---- pass 3: act, then notify ONCE ---------------------------------------
load_open_outages
DOWN_NEW=(); DOWN_KNOWN=(); RECOVERED=(); SUPPRESSED=()
i=0
while [ "$i" -lt "$n_total" ]; do
  name="${T_NAME[$i]}"; url="${T_URL[$i]}"; class="${T_CLASS[$i]}"; detail="${T_DETAIL[$i]}"
  i=$((i + 1))

  if [ "$class" = "up" ]; then
    summ "| $name | - | ✅ UP |"
    issue=$(find_issue "$name")          # read-only: safe in dry-run too
    if [ -n "$issue" ]; then
      if [ "$MONITOR_DRY_RUN" != "1" ]; then
        gh issue close "$issue" --repo "$REPO" --comment "Recovered at $RUN_TS - target is UP." >/dev/null 2>&1 || true
      fi
      RECOVERED+=("$name")
    fi
    continue
  fi

  # suppressed = we have no trustworthy information about this target
  if [ "$BLIND_ALL" = "1" ] || { [ "$SUPPRESS_TRANSPORT" = "1" ] && [ "$class" = "transport" ]; }; then
    SUPPRESSED+=("$name")
    summ "| $name | $class | 🌐 no measurement (runner network) |"
    log "   🌐 $name - suppressed by correlation gate (no product alert)"
    # An outage issue already open stays open: a blind run is not evidence of recovery.
    continue
  fi

  summ "| $name | $class | ❌ $detail |"
  issue=$(find_issue "$name")            # read-only: safe in dry-run too
  if [ -z "$issue" ]; then
    if [ "$MONITOR_DRY_RUN" != "1" ]; then
      issue_err=$(gh issue create --repo "$REPO" --label outage \
        --title "🔴 OUTAGE: $name" \
        --body "$(printf 'Detected DOWN at %s\nURL: %s\nClass: %s\nDetail: %s\nEgress canary: %s (%s)\nSecond vantage (Cloudflare Worker): %s - %s\n\n_auto-managed by the uptime monitor; will close on recovery._' \
                  "$RUN_TS" "$url" "$class" "$detail" "$EGRESS" "$CANARY_HIT" "$SECOND_OPINION" "$SECOND_OPINION_DETAIL")" \
        2>&1 >/dev/null) || log "   ⚠️  could not create issue: $issue_err"
    fi
    DOWN_NEW+=("$i|$name")
  else
    DOWN_KNOWN+=("$i|$name")
    log "   (already alerted - issue #$issue open)"
  fi
done

if [ "${#SUPPRESSED[@]}" -gt 0 ]; then
  record_blind "$RUN_TS" "$GATE_REASON" \
    "$(printf 'Targets with no measurement: %s\nSample failure: %s\nRunner egress IP: %s\nEgress canary: %s (%s)\nSecond vantage (Cloudflare Worker): %s - %s\nRun: %s' \
       "${SUPPRESSED[*]}" "${T_DETAIL[0]}" "$(runner_ip)" "$EGRESS" "$CANARY_HIT" "$SECOND_OPINION" "$SECOND_OPINION_DETAIL" "${GITHUB_RUN_ID:-local}")"
fi

# ---- ONE grouped outage email --------------------------------------------
# Subject must say HOW MANY and WHO - the whole point of grouping is that the
# subject alone is enough to judge the blast radius without opening the mail.
join_names() {  # $1=max shown, rest=entries "idx|name"
  local max="$1"; shift
  local out="" k=0 e n
  for e in "$@"; do
    n="${e#*|}"; k=$((k + 1))
    if [ "$k" -le "$max" ]; then out="${out:+$out, }$n"; fi
  done
  if [ "$k" -gt "$max" ]; then out="$out ועוד $((k - max))"; fi
  printf '%s' "$out"
}
rows_html() {  # $1..=entries "idx|name" -> table rows
  local e idx name cls det
  for e in "$@"; do
    idx="${e%%|*}"; name="${e#*|}"
    cls="${T_CLASS[$((idx - 1))]}"; det="${T_DETAIL[$((idx - 1))]}"
    case "$cls" in transport) cls="כשל תעבורה" ;; app) cls="כשל אפליקציה" ;; esac
    printf '<tr><td style="padding:4px 8px"><b>%s</b></td><td style="padding:4px 8px">%s</td><td style="padding:4px 8px;color:#666">%s</td></tr>' \
      "$(esc "$name")" "$cls" "$(esc "$det")"
  done
}

if [ "${#DOWN_NEW[@]}" -gt 0 ]; then
  cnt="${#DOWN_NEW[@]}"
  who="$(join_names 3 "${DOWN_NEW[@]}")"
  if [ "$cnt" -eq 1 ]; then
    subject="🔴 תקלה (1/$n_total): $who לא זמין"
  else
    subject="🔴 תקלה ($cnt/$n_total): $who"
  fi
  known_html=""
  if [ "${#DOWN_KNOWN[@]}" -gt 0 ]; then
    known_html="<p style='color:#666'>כבר דווח קודם וממתין לתיקון: $(esc "$(join_names 7 "${DOWN_KNOWN[@]}")")</p>"
  fi
  send_email "$subject" \
    "<div dir=rtl style='font-family:Arial'><h2 style='color:#c00'>🔴 $cnt מתוך $n_total יעדים לא מגיבים</h2>
     <p><b>זמן:</b> $(esc "$RUN_TS")</p>
     <table style='border-collapse:collapse;font-size:14px'>
       <tr style='background:#f3f3f3'><th style='padding:4px 8px;text-align:right'>יעד</th><th style='padding:4px 8px;text-align:right'>סוג הכשל</th><th style='padding:4px 8px;text-align:right'>פירוט</th></tr>
       $(rows_html "${DOWN_NEW[@]}")
     </table>
     $known_html
     <p style='color:#666'>כל יעד נבדק שוב ושוב לפני ההתראה, ונבדק גם שהמנטר עצמו מחובר לרשת
     ($(esc "$CANARY_HIT")) - כך שזו נפילה אמיתית ולא תקלת רשת של שרת הבדיקה.</p>
     <p>תישלח הודעה אחת נוספת כשהיעדים יחזרו לפעול.</p></div>"
fi

# ---- ONE grouped recovery email ------------------------------------------
if [ "${#RECOVERED[@]}" -gt 0 ]; then
  rcnt="${#RECOVERED[@]}"
  rwho=""; for r in "${RECOVERED[@]}"; do rwho="${rwho:+$rwho, }$r"; done
  if [ "$rcnt" -eq 1 ]; then rsubject="✅ חזר לפעול: $rwho"; else rsubject="✅ חזרו לפעול ($rcnt): $rwho"; fi
  send_email "$rsubject" \
    "<div dir=rtl style='font-family:Arial'><h2 style='color:#0a0'>✅ $rcnt יעדים חזרו לפעול</h2>
     <p><b>זמן:</b> $(esc "$RUN_TS")<br><b>יעדים:</b> $(esc "$rwho")</p></div>"
fi

# --- deploy-drift loop (deployed commit vs repo HEAD) ----------------------
# Guarded: with no token to read private-repo HEADs, skip entirely (no-op) so
# the workflow is merge-safe before the secret exists. Also skipped when the
# runner is blind - every reading would be an empty string anyway.
if [ -n "${REPO_HEAD_TOKEN:-}" ] && [ "$BLIND_ALL" != "1" ] && [ -z "${MONITOR_TARGETS_FILE:-}" ]; then
  gh label create drift         --repo "$REPO" --color FBCA04 --description "deployed commit != repo HEAD" >/dev/null 2>&1 || true
  gh label create drift-alerted --repo "$REPO" --color D93F0B --description "drift alert already emailed"   >/dev/null 2>&1 || true
  summ "\n### Deploy drift - $RUN_TS\n\n| Product | Deployed | HEAD | State |\n|---|---|---|---|"

  for entry in "${DRIFT_TARGETS[@]}"; do
    IFS='|' read -r name url repo branch <<< "$entry"
    ts=$(date -u +"%Y-%m-%d %H:%M UTC")
    dep=$(running_commit "$url")
    headsha=$(head_commit "$repo" "$branch")
    dissue=$(find_drift_issue "$name")

    if [ -z "$dep" ]; then
      log "➖ drift $name - /health reports no commit yet (skip)"
      summ "| $name | _n/a_ | ${headsha:0:7} | ➖ not instrumented |"
      continue
    fi
    if [ -z "$headsha" ]; then
      log "➖ drift $name - could not read HEAD of $repo@$branch (skip)"
      summ "| $name | ${dep:0:7} | _err_ | ➖ HEAD unreadable |"
      continue
    fi

    if commits_match "$dep" "$headsha"; then
      log "✅ drift $name - in sync (${dep:0:7})"
      summ "| $name | ${dep:0:7} | ${headsha:0:7} | ✅ in sync |"
      if [ -n "$dissue" ]; then
        gh issue close "$dissue" --repo "$REPO" \
          --comment "Realigned at $ts - deployed ${dep:0:12} == HEAD." >/dev/null 2>&1 || true
      fi
    else
      log "⚠️  drift $name - deployed ${dep:0:7} != HEAD ${headsha:0:7}"
      summ "| $name | ${dep:0:7} | ${headsha:0:7} | ⚠️ DRIFT |"
      if [ -z "$dissue" ]; then
        # first detection -> record state, do NOT alert yet (grace window)
        gh issue create --repo "$REPO" --label drift \
          --title "🟡 DRIFT: $name" \
          --body "$(printf 'Deploy drift first seen at %s\nDeployed (running): %s\nHEAD (%s@%s): %s\nHealth: %s\n\n_Alerts only if this persists > %s min (normal deploys lag a few minutes). Auto-closes on realignment._' "$ts" "$dep" "$repo" "$branch" "$headsha" "$url" "$DRIFT_MAX_AGE_MIN")" \
          >/dev/null 2>&1 || log "   ⚠️  could not create drift issue"
        log "   (drift recorded - ${DRIFT_MAX_AGE_MIN}m grace window before alert)"
      else
        age=$(issue_age_min "$dissue")
        if [ "$age" -ge "$DRIFT_MAX_AGE_MIN" ] && ! issue_has_alerted "$dissue"; then
          gh issue edit "$dissue" --repo "$REPO" --add-label drift-alerted >/dev/null 2>&1 || true
          send_email "🟡 סחף פריסה: $name לא מעודכן" \
            "<div dir=rtl style='font-family:Arial'><h2 style='color:#b8860b'>🟡 $name - הקוד שרץ אינו העדכני</h2>
             <p>הקומיט שרץ בפרודקשן שונה מ-HEAD כבר מעל $DRIFT_MAX_AGE_MIN דקות - כנראה פריסה שנתקעה או נכשלה.</p>
             <p><b>זמן:</b> $ts<br><b>רץ בפועל:</b> ${dep:0:12}<br><b>HEAD ($branch):</b> ${headsha:0:12}<br><b>מקור:</b> $repo</p>
             <p>בדוק את הפריסה האחרונה ב-Coolify. הודעה זו נשלחת פעם אחת עד ליישור מחדש.</p></div>"
        else
          log "   (drift issue #$dissue open, age ${age}m - $( [ "$age" -ge "$DRIFT_MAX_AGE_MIN" ] && echo already-alerted || echo within-grace ))"
        fi
      fi
    fi
  done
fi

log ""
if [ "$BLIND_ALL" = "1" ]; then
  log "RESULT: NO MEASUREMENT - runner had no network (${n_total}/${n_total} × HTTP 000); no alert sent"
elif [ "$n_failed" -eq 0 ]; then
  log "RESULT: all $n_total targets UP"
else
  log "RESULT: DOWN=${#DOWN_NEW[@]} new, ${#DOWN_KNOWN[@]} known, ${#SUPPRESSED[@]} suppressed (of $n_total targets)"
fi
# never fail the job on an outage - the email IS the signal; keep the schedule healthy
exit 0
