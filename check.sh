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
# vixy.co.il is the Resend-verified sender domain (projectadam.co.il lost
# verification in the 29.7 rebrand — alerts from it were silently rejected).
FROM="Vixy Monitor <noreply@vixy.co.il>"
RETRIES=3
RETRY_WAIT=15

# name | url | type(health|page)
# vixy.co.il domains are what customers use since the 29.7 rebrand; the old
# *.projectadam.co.il subdomains are only an OAuth safety net — not monitored.
TARGETS=(
  "Project Adam|https://projectadam.co.il/|page"
  "Vixy Ads|https://vixy.co.il/api/health|health"
  "Vixy CRM|https://crm.vixy.co.il/health|health"
  "Vixy Coach|https://coach.vixy.co.il/api/health|health"
)

# --- deploy-drift check -----------------------------------------------------
# Does the commit each app SERVES at /health match its repo HEAD? The /health
# "commit" field is process.env.SOURCE_COMMIT — Coolify injects the deployed git
# SHA as a runtime env on every deploy, so it reflects what is ACTUALLY running
# (= the image tag), not the source tree. A green /health does NOT prove a deploy
# landed (two swaps silently failed on 2026-07-22); this catches that.
# Alert only when a drift persists past DRIFT_MAX_AGE_MIN — a normal deploy lags
# a few minutes; a stuck/failed swap lingers. Needs REPO_HEAD_TOKEN (read-only
# PAT, contents:read) to read private-repo HEADs; unset -> whole check is a no-op.
# Per app: a missing / "unknown" commit = not yet instrumented -> skipped (safe
# rollout — each product lights up once it ships the /health commit field).
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
     <p>מהיום, 4 המוצרים (Project Adam, Vixy Ads, Vixy CRM, Vixy Coach) נבדקים על דומייני vixy.co.il החיים כל 5 דקות מ-GitHub (מחוץ לשרת).
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

# --- deploy-drift loop (deployed commit vs repo HEAD) ----------------------
# Guarded: with no token to read private-repo HEADs, skip entirely (no-op) so
# the workflow is merge-safe before the secret exists.
if [ -n "${REPO_HEAD_TOKEN:-}" ]; then
  gh label create drift         --repo "$REPO" --color FBCA04 --description "deployed commit != repo HEAD" >/dev/null 2>&1 || true
  gh label create drift-alerted --repo "$REPO" --color D93F0B --description "drift alert already emailed"   >/dev/null 2>&1 || true
  summ "\n### Deploy drift — $(date -u +'%Y-%m-%d %H:%M UTC')\n\n| Product | Deployed | HEAD | State |\n|---|---|---|---|"

  for entry in "${DRIFT_TARGETS[@]}"; do
    IFS='|' read -r name url repo branch <<< "$entry"
    ts=$(date -u +"%Y-%m-%d %H:%M UTC")
    dep=$(running_commit "$url")
    headsha=$(head_commit "$repo" "$branch")
    dissue=$(find_drift_issue "$name")

    if [ -z "$dep" ]; then
      log "➖ drift $name — /health reports no commit yet (skip)"
      summ "| $name | _n/a_ | ${headsha:0:7} | ➖ not instrumented |"
      continue
    fi
    if [ -z "$headsha" ]; then
      log "➖ drift $name — could not read HEAD of $repo@$branch (skip)"
      summ "| $name | ${dep:0:7} | _err_ | ➖ HEAD unreadable |"
      continue
    fi

    if commits_match "$dep" "$headsha"; then
      log "✅ drift $name — in sync (${dep:0:7})"
      summ "| $name | ${dep:0:7} | ${headsha:0:7} | ✅ in sync |"
      if [ -n "$dissue" ]; then
        gh issue close "$dissue" --repo "$REPO" \
          --comment "Realigned at $ts — deployed ${dep:0:12} == HEAD." >/dev/null 2>&1 || true
      fi
    else
      log "⚠️  drift $name — deployed ${dep:0:7} != HEAD ${headsha:0:7}"
      summ "| $name | ${dep:0:7} | ${headsha:0:7} | ⚠️ DRIFT |"
      if [ -z "$dissue" ]; then
        # first detection -> record state, do NOT alert yet (grace window)
        gh issue create --repo "$REPO" --label drift \
          --title "🟡 DRIFT: $name" \
          --body "$(printf 'Deploy drift first seen at %s\nDeployed (running): %s\nHEAD (%s@%s): %s\nHealth: %s\n\n_Alerts only if this persists > %s min (normal deploys lag a few minutes). Auto-closes on realignment._' "$ts" "$dep" "$repo" "$branch" "$headsha" "$url" "$DRIFT_MAX_AGE_MIN")" \
          >/dev/null 2>&1 || log "   ⚠️  could not create drift issue"
        log "   (drift recorded — ${DRIFT_MAX_AGE_MIN}m grace window before alert)"
      else
        age=$(issue_age_min "$dissue")
        if [ "$age" -ge "$DRIFT_MAX_AGE_MIN" ] && ! issue_has_alerted "$dissue"; then
          gh issue edit "$dissue" --repo "$REPO" --add-label drift-alerted >/dev/null 2>&1 || true
          send_email "🟡 סחף פריסה: $name לא מעודכן" \
            "<div dir=rtl style='font-family:Arial'><h2 style='color:#b8860b'>🟡 $name — הקוד שרץ אינו העדכני</h2>
             <p>הקומיט שרץ בפרודקשן שונה מ-HEAD כבר מעל $DRIFT_MAX_AGE_MIN דקות — כנראה פריסה שנתקעה או נכשלה.</p>
             <p><b>זמן:</b> $ts<br><b>רץ בפועל:</b> ${dep:0:12}<br><b>HEAD ($branch):</b> ${headsha:0:12}<br><b>מקור:</b> $repo</p>
             <p>בדוק את הפריסה האחרונה ב-Coolify. הודעה זו נשלחת פעם אחת עד ליישור מחדש.</p></div>"
        else
          log "   (drift issue #$dissue open, age ${age}m — $( [ "$age" -ge "$DRIFT_MAX_AGE_MIN" ] && echo already-alerted || echo within-grace ))"
        fi
      fi
    fi
  done
fi

if [ "$FAILED" -ne 0 ]; then
  log ""
  log "RESULT: DOWN ->$DEGRADED_LIST"
else
  log ""
  log "RESULT: all 4 products UP"
fi
# never fail the job on an outage — the email IS the signal; keep the schedule healthy
exit 0
