#!/usr/bin/env bash
set -euo pipefail

# Generate PDF for a single report
# Usage: ./batch/gen-pdf-for-report.sh <report-file>

export PATH="$HOME/.opencode/bin:$PATH"

REPORT="$1"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$PROJECT_DIR/$REPORT" ]]; then
  echo "Report not found: $REPORT"
  exit 1
fi

cd "$PROJECT_DIR"

# Extract score
SCORE=$(grep -oE 'Score:\*\* [0-9]+\.[0-9]+/5' "$REPORT" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
if [[ -z "$SCORE" ]]; then
  echo "No score found in $REPORT"
  exit 1
fi

# Check threshold
BELOW=$(echo "$SCORE < 3.0" | bc -l 2>/dev/null || echo "1")
if [[ "$BELOW" == "1" ]]; then
  echo "Score $SCORE < 3.0, skipping"
  exit 0
fi

# Generate PDF
RESUME_DIR="$HOME/Desktop/mohd resume"
echo "Generating PDF for $REPORT (score: $SCORE)..."
echo "Read cv.md and $REPORT. Generate a tailored ATS-optimized CV PDF. The report has the JD requirements. Create HTML at ${RESUME_DIR}/cv-candidate-$(basename "$REPORT" .md).html using templates/cv-template.html, then run: node generate-pdf.mjs ${RESUME_DIR}/cv-candidate-$(basename "$REPORT" .md).html ${RESUME_DIR}/cv-candidate-$(basename "$REPORT" .md)-$(date +%Y-%m-%d).pdf --format=letter" | opencode run --auto -m "opencode-go/deepseek-v4-flash" 2>&1

echo "Done"
