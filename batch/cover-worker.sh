#!/usr/bin/env bash
# Worker script for cover letter generation — called by xargs
export PATH="$HOME/.opencode/bin:$PATH"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$(dirname "${BASH_SOURCE[0]}")/apply-bot.env" ]]; then
  source "$(dirname "${BASH_SOURCE[0]}")/apply-bot.env"
fi
APPLY_EMAIL="${APPLY_EMAIL:-you@example.com}"
APPLY_FULL_NAME="${APPLY_FULL_NAME:-Your Full Name}"
OUTPUT_DIR="${APPLY_COVER_DIR:-$HOME/Desktop/mohd cover letters}"
PAYLOAD_DIR="$OUTPUT_DIR/payloads"
LOG="/tmp/cover-batch-log.txt"

report="$1"
report_name=$(basename "$report" .md)
report_num=$(echo "$report_name" | grep -oE '^[0-9]+')

mkdir -p "$PAYLOAD_DIR"

# IDEMPOTENCY: skip if cover letter already exists
if compgen -G "$OUTPUT_DIR/${report_name}-cover.pdf" > /dev/null 2>&1; then
  echo "SKIP: $report_name (cover exists)" >> "$LOG"
  exit 0
fi

cd "$PROJECT_DIR"
prompt="You are preparing a tailored cover letter PDF for ${APPLY_FULL_NAME} (${APPLY_LOCATION:-Your City, Your Country}; email ${APPLY_EMAIL}).

READ FIRST (mandatory):
1. cv.md — the candidate's CV (achievements and metrics source)
2. $report — the evaluation report for this job (contains the JD requirements, company context, and score)
3. config/profile.yml — candidate identity, comp targets, notice period
4. modes/_profile.md — adaptive framing, negotiation scripts, location policy

TASK:
1. Identify the role title, company, and top 3-4 required competencies from the report
2. Select 4-5 achievement bullets from cv.md that best match those competencies (exact wording + metrics from cv.md)
3. Draft a 350-420 word cover letter with: opening (why applying), profile intro (experience + domain), achievements (bold lead + impact with metric), problems section (specific to the company's context from the report), closing (availability: immediate)

VOICE RULES: active voice only, no em dashes, no buzzwords (leverage/synergy/seamless/holistic), no filler openers, concrete claims with numbers only from cv.md. NEVER invent facts, metrics, or companies.

THEN CREATE THE PDF:
1. Write the payload JSON to ${PAYLOAD_DIR}/cover-payload-${report_num}.json (persistent — survives reboots; also copy to /tmp/cover-payload-${report_num}.json for compatibility) with this exact structure:
{
  \"candidate\": {\"name\": \"${APPLY_FULL_NAME}\", \"email\": \"${APPLY_EMAIL}\", \"location\": \"${APPLY_LOCATION:-Your City, Your Country}\", \"linkedin\": \"${APPLY_LINKEDIN:-https://www.linkedin.com/in/your-profile}\", \"github\": \"${APPLY_GITHUB:-https://github.com/your-username}\", \"credentials\": [\"Your Credential\"]},
  \"letter\": {\"role_title\": \"<exact role from report>\", \"company\": \"<company>\", \"city\": \"<city from report if known>\", \"date\": \"$(date +%Y-%m-%d)\", \"opening\": \"...\", \"profile_intro\": \"...\", \"achievements\": [{\"lead\": \"...\", \"impact\": \"...\"}], \"problems_section\": \"...\", \"closing\": \"...\", \"language_closing\": null},
  \"output_path\": \"${OUTPUT_DIR}/${report_name}-cover.pdf\"
}
2. Run: node generate-cover-letter.mjs --payload ${PAYLOAD_DIR}/cover-payload-${report_num}.json
3. Confirm the PDF exists. Report the path.

Do not ask questions. Execute all steps."

echo "$prompt" | opencode run --auto -m "opencode-go/deepseek-v4-flash" > /dev/null 2>&1

if compgen -G "$OUTPUT_DIR/${report_name}-cover.pdf" > /dev/null 2>&1; then
  echo "OK: $report_name" >> "$LOG"
else
  echo "FAIL: $report_name" >> "$LOG"
fi
