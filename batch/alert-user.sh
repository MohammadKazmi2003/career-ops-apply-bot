#!/usr/bin/env bash
# Loud audible + visual alert for the user — tells you WHAT action is needed
# Usage: ./batch/alert-user.sh <company> <role> [reason]
# reason examples: "email OTP required — code sent to your Gmail",
#                  "hCaptcha image challenge — solve in the Chrome window",
#                  "login required — sign in to continue"

COMPANY="${1:-job}"
ROLE="${2:-}"
REASON="${3:-}"

# TTS voice: prefer the installed Siri Premium voice ('riya'), then Premium
# neural voices, then the best compact fallbacks.
# Override with: APPLY_VOICE="Daniel" ./batch/alert-user.sh ...
APPLY_VOICE="${APPLY_VOICE:-}"
if [[ -z "$APPLY_VOICE" ]]; then
  for v in "riya" "com.apple.speech.synthesis.voice.custom.siri.riya.premium" "Ava (Premium)" "Zoe (Premium)" "Allison (Premium)" "Joelle (Premium)" "Daniel" "Samantha"; do
    if say -v '?' 2>/dev/null | grep -qF " $v " || { say -v "$v" -o /tmp/.voice-check.aiff "voice check" >/dev/null 2>&1 && rm -f /tmp/.voice-check.aiff; }; then
      APPLY_VOICE="$v"
      break
    fi
  done
  APPLY_VOICE="${APPLY_VOICE:-Samantha}"
fi

if [[ -n "$REASON" ]]; then
  MSG="$COMPANY $ROLE — $REASON"
  VOICE_MSG="$COMPANY $ROLE. $REASON"
else
  MSG="$COMPANY $ROLE needs your action — solve the CAPTCHA/OTP in the Chrome window"
  VOICE_MSG="Action needed for $COMPANY $ROLE. Please check the Chrome window."
fi

# Notification with sound
osascript -e "display notification \"$MSG\" with title \"Apply Bot — Action Needed\" sound name \"Glass\"" 2>/dev/null

# Bring Chrome to front
osascript -e 'tell application "System Events" to set frontmost of first process whose name is "Google Chrome" to true' 2>/dev/null

# Play alert sound ONCE
afplay /System/Library/Sounds/Glass.aiff 2>/dev/null

# Interactive dialog with a 'Skip & Continue' button — clicking it touches the
# continue flag so the batch moves on whether or not the application succeeded.
# Runs backgrounded (non-blocking); auto-dismisses after 60s (batch wait cap).
# The spoken alert runs in the SAME block as the dialog: dismissing the dialog
# (any button / Esc) immediately kills the voice; only a timeout leaves it to
# finish naturally (nobody is there to dismiss it).
(
  say -v "$APPLY_VOICE" "Action needed. $VOICE_MSG" 2>/dev/null &
  SAY_PID=$!
  CHOICE=$(osascript -e "display alert \"Apply Bot — Action Needed\" message \"$MSG\" buttons {\"Skip & Continue\", \"I will handle it\"} default button \"I will handle it\" giving up after 60" 2>/dev/null)
  if echo "$CHOICE" | grep -q "button returned"; then
    kill "$SAY_PID" 2>/dev/null
  fi
  if echo "$CHOICE" | grep -qi "Skip"; then
    touch /tmp/apply-continue.txt
  fi
) &

echo "Alert sent: $MSG (voice: $APPLY_VOICE)"
