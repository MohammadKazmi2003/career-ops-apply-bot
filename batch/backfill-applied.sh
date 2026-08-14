#!/usr/bin/env bash
export PATH="$HOME/.opencode/bin:$PATH"

# Backfill: mark successfully-submitted jobs as Applied in the tracker
# Reads a list of URLs (one per line) from a file
# Usage: ./batch/backfill-applied.sh <url-list-file>

LIST_FILE="${1:-/tmp/backfill-list.txt}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

total=0
fixed=0
skipped=0

while IFS= read -r url; do
  [[ -z "$url" ]] && continue
  total=$((total+1))

  # Skip if already applied
  if bash "$SCRIPT_DIR/is-applied.sh" "$url" 2>/dev/null; then
    echo "SKIP (already applied): $url"
    skipped=$((skipped+1))
    continue
  fi

  # Find report and tracker row
  REPORT=$(grep -rlF "$url" reports/*.md 2>/dev/null | grep -v RESERVED | head -1)
  if [[ -z "$REPORT" ]]; then
    echo "NO REPORT: $url"
    continue
  fi
  REPORT_NUM=$(basename "$REPORT" | grep -oE '^[0-9]+')
  ROW=$(grep -nF "reports/${REPORT_NUM}-" data/applications.md | head -1 | cut -d: -f1)
  if [[ -z "$ROW" ]]; then
    echo "NO TRACKER ROW: $url (report $REPORT_NUM)"
    continue
  fi
  NUM=$(sed -n "${ROW}p" data/applications.md | awk -F'|' '{print $2}' | xargs)
  if [[ -z "$NUM" ]]; then
    echo "NO ROW NUMBER: $url"
    continue
  fi

  echo "→ Marking row #$NUM (report $REPORT_NUM) as Applied..."
  node set-status.mjs "$NUM" Applied --note "Backfilled: submitted via ATS on $(date +%Y-%m-%d); URL: $url" --force 2>&1 | tail -1
  fixed=$((fixed+1))
done < "$LIST_FILE"

echo ""
echo "================================"
echo "Total: $total | Marked Applied: $fixed | Already applied: $skipped"
echo "================================"
