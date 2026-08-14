#!/usr/bin/env bash
# Gmail OTP auto-reader — 3-stage pipeline
# Stage 1: hint-scoring (progressive depth 10 -> 30 -> 60)
# Stage 2: inspect newest emails listing (for LLM reasoning)
# Stage 3: retry with 15s wait, up to 4 attempts
# Usage: ./batch/read-otp.sh "<hints|pipe|separated>" [max-attempts]

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HINTS="${1:-}"
MAX_ATTEMPTS="${2:-4}"

if [[ ! -f ~/.gmail-mcp/imap-credentials.json ]]; then
  echo "❌ NOT CONFIGURED: create ~/.gmail-mcp/imap-credentials.json"
  echo "   {\"email\":\"...\",\"password\":\"<16-char App Password>\"}"
  exit 2
fi

echo "Checking Gmail for verification email (hints: '${HINTS:-any}')..."

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  # Depth escalates with attempts: 10 -> 30 -> 60 -> 60
  case "$attempt" in
    1) DEPTH=10 ;;
    2) DEPTH=30 ;;
    *) DEPTH=60 ;;
  esac

  # Stage 1: hint-scoring
  if [[ -n "$HINTS" ]]; then
    RESULT=$(python3 "$PROJECT_DIR/batch/read-otp-imap.py" --score "$HINTS" --depth "$DEPTH" 2>/dev/null)
  else
    RESULT=$(python3 "$PROJECT_DIR/batch/read-otp-imap.py" --score "verification|security|code" --depth "$DEPTH" 2>/dev/null)
  fi

  OTP=$(echo "$RESULT" | grep -oE "OTP_CODE: [A-Za-z0-9]{4,10}" | awk '{print $2}')
  if [[ -n "$OTP" ]] && [[ "$OTP" != "NOT_FOUND" ]]; then
    echo "✅ OTP FOUND (attempt $attempt, depth $DEPTH): $OTP"
    echo "$RESULT" | grep "MATCHED" || true
    echo "$OTP" > /tmp/last-otp.txt
    exit 0
  fi

  # Stage 2: inspect newest emails (the LLM/worker reasons over this listing)
  echo "  ℹ️  Attempt $attempt: scoring found nothing. Newest emails for inspection:"
  python3 "$PROJECT_DIR/batch/read-otp-imap.py" --inspect --count 10 2>/dev/null | head -30

  if [[ $attempt -lt $MAX_ATTEMPTS ]]; then
    echo "  ⏳ Waiting 15s before retry (email may be in transit)..."
    sleep 15
  fi
done

echo "❌ No OTP found after $MAX_ATTEMPTS attempts"
exit 1
