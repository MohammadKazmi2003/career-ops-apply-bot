#!/usr/bin/env bash
export PATH="$HOME/.opencode/bin:$PATH"

# Apply to all active jobs sequentially (fill + submit)
# Workers self-resolve CAPTCHAs (poll up to 5 min). For unresolvable blockers,
# the batch pauses and waits — resumed automatically when the flag appears,
# or the user/operator can signal with: touch /tmp/apply-continue.txt
# Usage: ./batch/apply-to-jobs.sh <list-file>

LIST_FILE="${1:-/tmp/active-jobs.txt}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER="$SCRIPT_DIR/apply-worker.sh"
LOG="/tmp/apply-log.txt"
DONE_FILE="/tmp/apply-done.txt"
MANUAL_FILE="/tmp/apply-manual.txt"
SKIP_FILE="/tmp/apply-skipped.txt"
CONTINUE_FLAG="/tmp/apply-continue.txt"

cd "$(dirname "$SCRIPT_DIR")"
rm -f "$LOG" "$DONE_FILE" "$MANUAL_FILE" "$SKIP_FILE" "$CONTINUE_FLAG"

total=$(wc -l < "$LIST_FILE" | tr -d ' ')
STATUS_FILE="/tmp/apply-status.txt"
echo "Applying to $total jobs sequentially..."

index=0
while IFS=$'\t' read -r date company role score url; do
  # GUARD: reject malformed rows (a 4-column list silently misreads role/score/url)
  if [[ -z "$url" || -z "$score" ]]; then
    echo "⚠️  SKIPPED malformed row $index (expected 5 tab-separated cols: date company role score url): $date $company $role $score $url"
    echo "SKIPPED: MALFORMED ROW — $company $date $score $url" >> "$SKIP_FILE"
    continue
  fi
  index=$((index+1))
  # Live status file so the user always knows where the batch is
  echo "Job $index/$total: $company — $role ($score) | $(date '+%H:%M:%S')" > "$STATUS_FILE"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "[$index/$total] $company — $role ($score)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # IDEMPOTENCY: skip if already applied
  if bash "$SCRIPT_DIR/is-applied.sh" "$url" 2>/dev/null; then
    echo "SKIPPED (already applied): $company — $role"
    echo "SKIPPED: $company — $role" >> "$SKIP_FILE"
    echo "  → Progress: $index/$total done (skipped)"
    continue
  fi

  # Reset result marker BEFORE each worker — a crashed worker must never
  # leave a stale marker that the loop misreads as a successful submit
  rm -f /tmp/apply-result.txt

  bash "$WORKER" "$company" "$role" "$score" "$url" >> "$LOG" 2>&1

  # Read per-job result marker (written by the worker — reliable, not cumulative)
  RESULT=$(cat /tmp/apply-result.txt 2>/dev/null)
  [[ -z "$RESULT" ]] && RESULT="UNKNOWN"

  case "$RESULT" in
    SUBMITTED)
      echo "DONE: $company — $role" >> "$DONE_FILE"
      ;;
    SKIPPED)
      echo "SKIPPED: $company — $role" >> "$SKIP_FILE"
      ;;
    CLOSED)
      echo "CLOSED: $company — $role" >> "$DONE_FILE"
      ;;
    NEEDS_MANUAL)
      REASON=$(grep "REASON:" "$LOG" 2>/dev/null | tail -1)
      echo "NEEDS_MANUAL: $company — $role | ${REASON:-reason unknown}" >> "$MANUAL_FILE"
      echo ""
      echo "⛔ MANUAL ACTION REQUIRED: $company — $role"
      echo "   ${REASON:-A blocker requires your attention.}"
      echo ""
      echo "⏸️  BATCH PAUSED — this job could not be auto-submitted."
      echo "   → The Chrome tab is left open on the blocked page."
      echo "   → Resolve it (solve CAPTCHA, complete the form, click Submit)."
      echo "   → The batch resumes AUTOMATICALLY once you finish."
      echo "   → Skip it: click 'Skip & Continue' in the alert dialog"
      echo "     (or: touch /tmp/apply-continue.txt). Checks every 15s."
      echo ""
      # Wait until the flag appears (auto-resume) — operator touches the file,
      # or the user clicks 'Skip & Continue' in the alert dialog;
      # check every 15s up to 1 minute, then auto-skip the job
      waited=0
      while [[ ! -f "$CONTINUE_FLAG" ]]; do
        sleep 15
        waited=$((waited+15))
        # If the job got submitted manually (tracker flipped), auto-continue
        if bash "$SCRIPT_DIR/is-applied.sh" "$url" 2>/dev/null; then
          echo "   ✓ Detected that the application was submitted — resuming."
          rm -f "$CONTINUE_FLAG"
          break
        fi
        if [[ $waited -ge 60 ]]; then
          echo "   ⚠️  Waited 1 min. Skipping this job; resuming batch."
          echo "PASSED (manual wait timeout): $company — $role" >> "$SKIP_FILE"
          rm -f "$CONTINUE_FLAG"
          break
        fi
      done
      echo "   ✓ Resumed — continuing to next job."
      ;;
    *)
      echo "SKIPPED: $company — $role (no clear result — treated as skipped)" >> "$SKIP_FILE"
      echo "  ⚠️  No RESULT detected for $company — $role (check /tmp/apply-worker-last-output.txt) — marked skipped, will not be retried"
      ;;
  esac

  echo "  → Progress: $index/$total done"
done < "$LIST_FILE"

echo ""
echo "================================"
echo "ALL DONE"
echo "  Submitted: $(wc -l < "$DONE_FILE" 2>/dev/null || echo 0)"
echo "  Skipped (already applied): $(wc -l < "$SKIP_FILE" 2>/dev/null || echo 0)"
echo "  Needs manual: $(wc -l < "$MANUAL_FILE" 2>/dev/null || echo 0)"
echo "================================"
