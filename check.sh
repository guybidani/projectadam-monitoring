#!/usr/bin/env bash
# Project Adam — external uptime monitor.
# Runs from GitHub Actions (off-VPS), so it stays up even when the VPS is down.
# Alerts Guy by email via Resend on REAL outages only, de-duplicated through
# GitHub Issues: one email per outage (not one per 5-min run) + a recovery email.
#
# Usage:
#   bash check.sh            # normal monitoring run
#   bash check.sh selftest   # send one clearly-marked test email (proves the pipe)
set -uo pipefail

REPO="${GITHUB_REPOSITORY:-guybidani/projectadam-monitoring}"
ALERT_TO="${ALERT_TO:?ALERT_TO not set}"
RESEND_API_KEY="${RESEND_API_KEY:?RESEND_API_KEY not set}"
FROM="Project Adam Monitor <noreply@projectadam.co.il>"
RETRIES=3
RETRY_WAIT=15

# name | url | type(health|page)
TARGETS=(
  "Project Adam|https://projectadam.co.il/|page"
  "Vixy|https://vixy.projectadam.co.il/api/health|health"
  "Vixy CRM|https://crm.projectadam.co.il/health|health"
  "Kolio|https://kolio.projectadam.co.il/api/health|health"
)

BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT

log()  { echo "$@"; }
summ() { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo -e "$1" >> "$GITHUB_STEP_SUMMARY" || true; }

# --- email via Resend -------------------------------------------------------
send_email() {
  local subject="$1" html="$2" resp payload
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

# --- one probe: prints "UP" or "DOWN: reason"; returns 0/1 ------------------
probe() {
  local url="$1" type="$2" code
  code=$(curl -sS -o "$BODY_FILE" -w "%{http_code}" --max-time 20 "$url" 2>/dev/null)
  code="${code:-000}"
  if [ "$code" != "200" ]; then
    echo "DOWN: HTTP $code"; return 1
  fi
  if [ "$type" = "health" ]; then
    # any JSON field explicitly reporting a failure state = degraded
    if grep -qiE '"[a-z_]+"[[:space:]]*:[[:space:]]*"(down|error|fail|failed|unhealthy|degraded)"' "$BODY_FILE"; then
      echo "DOWN: degraded $(tr -d '\n' < "$BODY_FILE" | head -c 160)"; return 1
    fi
  else
    # a page must look like real HTML, not a proxy error body
    if ! grep -qi "<title" "$BODY_FILE"; then
      echo "DOWN: 200 but no HTML title (possible error page)"; return 1
    fi
  fi
  echo "UP"; return 0
}

# --- probe with retries (kills false positives from deploy blips / momentary 5xx)
probe_stable() {
  local url="$1" type="$2" i result rc
  for i in $(seq 1 "$RETRIES"); do
    result=$(probe "$url" "$type"); rc=$?
    if [ "$rc" -eq 0 ]; then echo "$result"; return 0; fi
    [ "$i" -lt "$RETRIES" ] && sleep "$RETRY_WAIT"
  done
  echo "$result"; return 1
}

# --- open outage issue for a target (empty if none) ------------------------
find_issue() {
  gh issue list --repo "$REPO" --state open --label outage --json number,title \
    --jq "map(select(.title==\"🔴 OUTAGE: $1\")) | .[0].number // empty" 2>/dev/null
}

# --- self-test: prove the alert pipe reaches Guy ---------------------------
if [ "${1:-}" = "selftest" ]; then
  log "=== SELF-TEST ==="
  # 1) prove DOWN detection works against a guaranteed-404 (no email)
  d=$(probe "https://projectadam.co.il/__uptime_selftest_should_404__" page) && true
  log "detection check (expect DOWN): $d"
  # 2) prove Resend delivery end-to-end (one marked email)
  ts=$(date -u +"%Y-%m-%d %H:%M UTC")
  send_email "✅ [בדיקת מערכת] ניטור Project Adam הופעל" \
    "<div dir=rtl style='font-family:Arial'><h2>✅ מערכת הניטור פעילה</h2>
     <p>זו הודעת בדיקה חד-פעמית שמאשרת שהתראות הניטור מגיעות אליך.</p>
     <p>מהיום, 4 המוצרים (Project Adam, Vixy, Vixy CRM, Kolio) נבדקים כל 5 דקות מ-GitHub (מחוץ לשרת).
     תקבל מייל רק אם משהו נופל באמת (אחרי 3 בדיקות רצופות), ומייל נוסף כשהוא חוזר.</p>
     <p style='color:#888'>זמן: $ts · אפשר להתעלם מהודעה זו.</p></div>"
  log "=== SELF-TEST DONE ==="
  exit 0
fi

# --- main monitoring loop ---------------------------------------------------
FAILED=0
DEGRADED_LIST=""
summ "### Uptime check — $(date -u +'%Y-%m-%d %H:%M UTC')\n\n| Product | Status |\n|---|---|"

for entry in "${TARGETS[@]}"; do
  IFS='|' read -r name url type <<< "$entry"
  status=$(probe_stable "$url" "$type"); up=$?
  issue=$(find_issue "$name")
  ts=$(date -u +"%Y-%m-%d %H:%M UTC")

  if [ "$up" -ne 0 ]; then
    FAILED=1
    DEGRADED_LIST="$DEGRADED_LIST $name"
    log "❌ $name — $status"
    summ "| $name | ❌ $status |"
    if [ -z "$issue" ]; then
      # new outage -> open issue (state) + alert Guy
      gh issue create --repo "$REPO" --label outage \
        --title "🔴 OUTAGE: $name" \
        --body "$(printf 'Detected DOWN at %s\nURL: %s\nDetail: %s\n\n_auto-managed by the uptime monitor; will close on recovery._' "$ts" "$url" "$status")" \
        >/dev/null 2>&1 || log "   ⚠️  could not create issue"
      send_email "🔴 תקלה: $name לא זמין" \
        "<div dir=rtl style='font-family:Arial'><h2 style='color:#c00'>🔴 $name לא מגיב</h2>
         <p><b>זמן:</b> $ts<br><b>כתובת:</b> $url<br><b>פירוט:</b> $status</p>
         <p>נבדק $RETRIES פעמים ברצף לפני ההתראה. תישלח הודעה נוספת כשהשירות יחזור לפעול.</p></div>"
    else
      log "   (already alerted — issue #$issue open)"
    fi
  else
    log "✅ $name — UP"
    summ "| $name | ✅ UP |"
    if [ -n "$issue" ]; then
      # recovered -> close issue + notify
      gh issue close "$issue" --repo "$REPO" \
        --comment "Recovered at $ts — service is UP." >/dev/null 2>&1 || true
      send_email "✅ חזר לפעול: $name" \
        "<div dir=rtl style='font-family:Arial'><h2 style='color:#0a0'>✅ $name חזר לפעול</h2>
         <p><b>זמן:</b> $ts<br><b>כתובת:</b> $url</p></div>"
    fi
  fi
done

if [ "$FAILED" -ne 0 ]; then
  log ""
  log "RESULT: DOWN ->$DEGRADED_LIST"
else
  log ""
  log "RESULT: all 4 products UP"
fi
# never fail the job on an outage — the email IS the signal; keep the schedule healthy
exit 0
