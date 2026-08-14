#!/usr/bin/env bash
export PATH="$HOME/.opencode/bin:$PATH"

# Generate cover letters for top reports — FIXED: xargs -P parallel + idempotent
# Usage: ./batch/gen-cover-letters.sh <list-file> [parallel]

LIST_FILE="${1:-/tmp/top100-list.txt}"
PARALLEL="${2:-4}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKER="$SCRIPT_DIR/cover-worker.sh"
LOG="/tmp/cover-batch-log.txt"

cd "$PROJECT_DIR"
rm -f "$LOG"

total=$(wc -l < "$LIST_FILE" | tr -d ' ')
echo "Processing $total cover letters (parallel: $PARALLEL)"

cat "$LIST_FILE" | grep -v '^$' | xargs -P "$PARALLEL" -I{} bash "$WORKER" {}

ok=$(grep -c "^OK:" "$LOG" 2>/dev/null || echo "0")
fail=$(grep -c "^FAIL:" "$LOG" 2>/dev/null || echo "0")
skip=$(grep -c "^SKIP:" "$LOG" 2>/dev/null || echo "0")
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Total: $total | OK: $ok | FAIL: $fail | SKIP: $skip"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
