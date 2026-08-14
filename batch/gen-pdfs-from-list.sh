#!/usr/bin/env bash
export PATH="$HOME/.opencode/bin:$PATH"

# Generate PDFs from a pre-built report list — FIXED: xargs -P parallel + idempotent
# Usage: ./batch/gen-pdfs-from-list.sh <list-file> [parallel]

LIST_FILE="${1:-/tmp/missing-pdfs.txt}"
PARALLEL="${2:-4}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKER="$SCRIPT_DIR/pdf-worker.sh"
LOG="/tmp/pdf-batch-log.txt"

cd "$PROJECT_DIR"
rm -f "$LOG"

total=$(wc -l < "$LIST_FILE" | tr -d ' ')
echo "Processing $total reports (parallel: $PARALLEL)"

# xargs -P runs N workers in true parallel — no bash job-control bugs
cat "$LIST_FILE" | grep -v '^$' | xargs -P "$PARALLEL" -I{} bash "$WORKER" {}

ok=$(grep -c "^OK:" "$LOG" 2>/dev/null || echo "0")
fail=$(grep -c "^FAIL:" "$LOG" 2>/dev/null || echo "0")
skip=$(grep -c "^SKIP:" "$LOG" 2>/dev/null || echo "0")
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Total: $total | OK: $ok | FAIL: $fail | SKIP: $skip"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
