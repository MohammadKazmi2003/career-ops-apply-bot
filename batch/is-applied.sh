#!/usr/bin/env bash
# Idempotency check: is this job already applied?
# Usage: ./batch/is-applied.sh <url>
# Returns 0 (already applied), 1 (not applied)

URL="$1"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# DURABLE LEDGER: only TERMINAL outcomes block re-application.
# NEEDS_MANUAL is NOT terminal — those jobs are pending manual intervention
# (CAPTCHA, thread-link, etc.) and must stay eligible for future runs once the
# user completes the task. Permanent rejections (application-limit, closed
# postings) are caught separately via the tracker's Applied/Discarded status.
# PROCESSING / UNKNOWN are also retryable (crashed worker / failed detection).
LEDGER_ROW=$(grep -F "$URL" data/applied-ledger.tsv 2>/dev/null | head -1)
if [[ -n "$LEDGER_ROW" ]]; then
  LEDGER_STATUS=$(echo "$LEDGER_ROW" | awk -F'\t' '{print $5}')
  case "$LEDGER_STATUS" in
    SUBMITTED|CLOSED|SKIPPED_ALREADY_APPLIED)
      exit 0
      ;;
  esac
fi

# Find the report containing this URL
REPORT=$(grep -rlF "$URL" reports/*.md 2>/dev/null | grep -v RESERVED | head -1)
[[ -z "$REPORT" ]] && exit 1

# Extract report number
REPORT_NUM=$(basename "$REPORT" | grep -oE '^[0-9]+')

# Check tracker: does a row with this report link show a terminal status?
# Applied = genuinely submitted; Discarded = closed posting or permanent
# rejection (reapply will never be accepted). Both must block re-application.
# Tracker rows look like: | 762 | date | Company | Role | 4.5/5 | Applied | ...
if grep -E "\| (Applied|Discarded) \|" data/applications.md | grep -qF "reports/${REPORT_NUM}-"; then
  exit 0
fi

# Also check notes for the exact job ID (fallback for rows whose report link
# was re-evaluated to a different report number)
if grep -E "\| (Applied|Discarded) \|" data/applications.md | grep -qiE "Submitted via|reapply will not|Posting closed"; then
  # Extract ONLY the unique job identifier from the URL:
  # - Ashby/Lever: the 36-char UUID (last path segment)
  # - Greenhouse: the numeric job ID (last path segment)
  # - gem.com/wayve/firststage etc: last segment with digits
  JOB_ID=$(echo "$URL" | grep -oE '[a-zA-Z0-9-]{20,}$|[0-9]{6,}$' | tail -1)
  if [[ -z "$JOB_ID" ]]; then
    JOB_ID=$(basename "$URL" | grep -oE '[a-zA-Z0-9_-]+' | tail -1)
  fi
  if [[ -n "$JOB_ID" ]] && [[ ${#JOB_ID} -ge 8 ]]; then
    if grep -E "\| (Applied|Discarded) \|" data/applications.md | grep -qF "$JOB_ID"; then
      exit 0
    fi
  fi
fi

exit 1
