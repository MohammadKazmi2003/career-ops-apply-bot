#!/usr/bin/env bash
set -euo pipefail

# Regenerate PDFs for reports missing them
# Usage: ./batch/regenerate-pdfs.sh [threshold] [parallel]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPORTS_DIR="$PROJECT_DIR/reports"
OUTPUT_DIR="$PROJECT_DIR/output"

THRESHOLD=${1:-3.0}
PARALLEL=${2:-4}

cd "$PROJECT_DIR"

# Count reports needing PDFs
echo "Scanning reports..."
total=0
for report in "$REPORTS_DIR"/*.md; do
  [[ -f "$report" ]] || continue
  score=$(grep -oE 'Score:\*\* [0-9]+\.[0-9]+/5' "$report" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
  [[ -z "$score" ]] && continue
  below=$(echo "$score < $THRESHOLD" | bc -l 2>/dev/null || echo "1")
  [[ "$below" == "1" ]] && continue
  # Check if any PDF references this report
  report_name=$(basename "$report")
  if ! grep -q "$report_name" "$OUTPUT_DIR"/*.pdf 2>/dev/null; then
    total=$((total + 1))
  fi
done

echo "Found $total reports needing PDFs"

if [[ $total -eq 0 ]]; then
  echo "Nothing to do"
  exit 0
fi

echo "Use the batch runner to process them:"
echo ""
echo "  cd $PROJECT_DIR"
echo "  ./batch/batch-runner-opencode.sh --parallel $PARALLEL --limit $total"
echo ""
echo "Or run manually for a single report:"
echo ""
echo "  opencode run -m opencode-go/deepseek-v4-flash \"Read cv.md and reports/XXX.md, generate tailored PDF\""
