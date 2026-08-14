#!/usr/bin/env bash
# Worker script for PDF generation — called by xargs
export PATH="$HOME/.opencode/bin:$PATH"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Resumes are stored in ~/Desktop/mohd resume/ (moved out of output/)
OUTPUT_DIR="$HOME/Desktop/mohd resume"
LOG="/tmp/pdf-batch-log.txt"

report="$1"
report_name=$(basename "$report" .md)

# IDEMPOTENCY: skip if PDF already exists
if compgen -G "$OUTPUT_DIR/cv-candidate-${report_name}-"*.pdf > /dev/null 2>&1; then
  echo "SKIP: $report_name (PDF exists)" >> "$LOG"
  exit 0
fi

cd "$PROJECT_DIR"
prompt="Read cv.md and $report. Generate a tailored ATS-optimized CV PDF. Create HTML at $OUTPUT_DIR/cv-candidate-${report_name}.html using templates/cv-template.html, then run: node generate-pdf.mjs $OUTPUT_DIR/cv-candidate-${report_name}.html $OUTPUT_DIR/cv-candidate-${report_name}-$(date +%Y-%m-%d).pdf --format=letter --allow-reorder --report=$(echo "$report_name" | grep -oE '^[0-9]+')"

echo "$prompt" | opencode run --auto -m "opencode-go/deepseek-v4-flash" > /dev/null 2>&1

if compgen -G "$OUTPUT_DIR/cv-candidate-${report_name}-"*.pdf > /dev/null 2>&1; then
  echo "OK: $report_name" >> "$LOG"
else
  echo "FAIL: $report_name" >> "$LOG"
fi
