#!/usr/bin/env bash
export PATH="$HOME/.opencode/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPORTS_DIR="$PROJECT_DIR/reports"
OUTPUT_DIR="$PROJECT_DIR/output"
RESUME_DIR="$HOME/Desktop/mohd resume"
LOG="/tmp/pdf-gen-log.txt"

THRESHOLD=${1:-3.0}
PARALLEL=${2:-4}

cd "$PROJECT_DIR"
rm -f "$LOG"

echo "Scanning for reports needing PDFs (threshold: $THRESHOLD)..."

needs_pdf=()
for report in "$REPORTS_DIR"/*.md; do
  [[ -f "$report" ]] || continue
  score=$(grep -oE 'Score:\*\* [0-9]+\.[0-9]+/5' "$report" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
  [[ -z "$score" ]] && continue
  below=$(echo "$score < $THRESHOLD" | bc -l 2>/dev/null || echo "1")
  [[ "$below" == "1" ]] && continue

  report_name=$(basename "$report" .md)
  report_num=$(echo "$report_name" | grep -oE '^[0-9]+')

  # Check if any PDF contains this report number OR this report name
  if ls "$OUTPUT_DIR"/*.pdf 2>/dev/null | grep -q "$report_num"; then
    continue
  fi
  if ls "$OUTPUT_DIR"/*.pdf 2>/dev/null | grep -q "$report_name"; then
    continue
  fi

  needs_pdf+=("$report")
done

total=${#needs_pdf[@]}
echo "Found $total reports needing PDFs"

if [[ $total -eq 0 ]]; then
  echo "All reports have PDFs!"
  exit 0
fi

for ((i=0; i<total; i++)); do
  report="${needs_pdf[$i]}"
  report_name=$(basename "$report" .md)

  echo "[$((i+1))/$total] Processing $report_name..."

  (
    cd "$PROJECT_DIR"
    prompt="Read cv.md and $report. Generate a tailored ATS-optimized CV PDF. Create HTML at ${RESUME_DIR}/cv-candidate-${report_name}.html using templates/cv-template.html, then run: node generate-pdf.mjs ${RESUME_DIR}/cv-candidate-${report_name}.html ${RESUME_DIR}/cv-candidate-${report_name}-$(date +%Y-%m-%d).pdf --format=letter --allow-reorder"
    echo "$prompt" | opencode run --auto -m "opencode-go/deepseek-v4-flash" > "/tmp/pdf-${i}.log" 2>&1

    if ls "$RESUME_DIR/cv-candidate-${report_name}-"*.pdf 1>/dev/null 2>&1; then
      echo "OK: $report_name" >> "$LOG"
    else
      echo "FAIL: $report_name" >> "$LOG"
    fi
  ) &

  sleep 3
  while [[ $(jobs -r | wc -l) -ge $PARALLEL ]]; do
    wait -n 2>/dev/null || true
  done
done

wait

generated=$(grep -c "^OK:" "$LOG" 2>/dev/null || echo "0")
failed=$(grep -c "^FAIL:" "$LOG" 2>/dev/null || echo "0")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Total: $total | Generated: $generated | Failed: $failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
