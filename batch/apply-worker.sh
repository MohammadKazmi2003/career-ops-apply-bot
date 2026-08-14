#!/usr/bin/env bash
export PATH="$HOME/.opencode/bin:$PATH"

# Apply worker — fills AND submits one job application
# Auto-notifies on blockers, waits for user to resolve CAPTCHA, then auto-resumes
# Usage: ./batch/apply-worker.sh <company> <role> <score> <url>

# TTS voice: prefer the installed Siri Premium voice ('riya'), then Premium
# neural voices, then the best compact fallbacks.
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

COMPANY="$1"
ROLE="$2"
SCORE="$3"
URL="$4"

# Load the user's identity config (gitignored — copy from apply-bot.env.example)
if [[ -f "$(dirname "${BASH_SOURCE[0]}")/apply-bot.env" ]]; then
  source "$(dirname "${BASH_SOURCE[0]}")/apply-bot.env"
fi
APPLY_FULL_NAME="${APPLY_FULL_NAME:-Your Full Name}"
APPLY_FIRST_NAME="${APPLY_FIRST_NAME:-YourFirst}"
APPLY_LAST_NAME="${APPLY_LAST_NAME:-YourLast}"
APPLY_EMAIL="${APPLY_EMAIL:-you@example.com}"
APPLY_PHONE_WITH_CODE="${APPLY_PHONE_WITH_CODE:-+91 9876543210}"
APPLY_PHONE_LOCAL="${APPLY_PHONE_LOCAL:-9876543210}"
APPLY_LOCATION="${APPLY_LOCATION:-Your City, Your Country}"
APPLY_LINKEDIN="${APPLY_LINKEDIN:-https://www.linkedin.com/in/your-profile}"
APPLY_GITHUB="${APPLY_GITHUB:-https://github.com/your-username}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# macOS notification helper — with AUDIBLE alert for manual-action cases
notify() {
  local title="$1" msg="$2" sound="$3"
  osascript -e "display notification \"$msg\" with title \"$title\" sound name \"$sound\"" 2>/dev/null
  osascript -e 'tell application "System Events" to set frontmost of first process whose name is "Google Chrome" to true' 2>/dev/null
}

# Loud audible alert for when the USER must act (CAPTCHA, OTP, manual submit)
notify_loud() {
  local title="$1" msg="$2"
  # macOS notification with sound
  osascript -e "display notification \"$msg\" with title \"$title\" sound name \"Glass\"" 2>/dev/null
  # Play alert sound ONCE
  afplay /System/Library/Sounds/Glass.aiff 2>/dev/null
  # Spoken alert immediately after the single sound (works when away from screen);
  # auto-stops after 15s max so it never dangles past the message
  say -v "$APPLY_VOICE" "Action needed. $msg" 2>/dev/null &
  local say_pid=$!
  ( sleep 15; kill "$say_pid" 2>/dev/null ) &
}

# IDEMPOTENCY: skip if already applied (tracker or durable ledger)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if bash "$SCRIPT_DIR/is-applied.sh" "$URL"; then
  echo "SKIP (already applied): $COMPANY — $ROLE"
  echo "RESULT: SKIPPED_ALREADY_APPLIED"
  exit 0
fi

# DURABLE LEDGER — CLAIM at start: reserve this URL BEFORE doing any work.
# Even if this worker crashes or is killed mid-job, the URL stays in the
# ledger and will never be re-applied. is-applied.sh checks the ledger first.
# Format: date<TAB>url<TAB>company<TAB>role<TAB>result
LEDGER="$PROJECT_DIR/data/applied-ledger.tsv"
mkdir -p "$PROJECT_DIR/data"
touch "$LEDGER"
if ! grep -qF "$URL" "$LEDGER" 2>/dev/null; then
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%Y-%m-%d)" "$URL" "$COMPANY" "$ROLE" "PROCESSING" >> "$LEDGER"
fi

# Keep the browser autofill DB clean: only the current email, never a stale one.
clean_browser_autofill() {
  local webdata="$HOME/.career-ops-playwright/Default/Web Data"
  [[ -f "$webdata" ]] || return 0
  # Don't touch a live browser's DB (locked) — the running batch owns it.
  pgrep -f "career-ops-playwright" >/dev/null 2>&1 && return 0
  # Wipe all saved autofill values and seed ONLY the candidate's email.
  sqlite3 "$webdata" "DELETE FROM autofill;" 2>/dev/null
  sqlite3 "$webdata" "INSERT INTO autofill (name, value, value_lower, date_created, date_last_used, count) VALUES ('email', '${APPLY_EMAIL}', '${APPLY_EMAIL}', 0, 0, 1);" 2>/dev/null
}
clean_browser_autofill

# Find matching CV PDF (newest generated first — ls -t, not alphabetical).
# Resumes/covers live in user-configured dirs (from apply-bot.env; defaults below)
RESUME_DIR="${APPLY_RESUME_DIR:-$HOME/Desktop/mohd resume}"
COVER_DIR="${APPLY_COVER_DIR:-$HOME/Desktop/mohd cover letters}"
COVER_PAYLOAD_DIR="$COVER_DIR/payloads"
company_slug=$(echo "$COMPANY" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-')
CV_PDF=$(ls -t "$RESUME_DIR"/cv-candidate-*${company_slug}*.pdf 2>/dev/null | head -1)
[[ -z "$CV_PDF" ]] && CV_PDF=$(ls -t output/cv-candidate-*${company_slug}*.pdf 2>/dev/null | head -1)
COVER_PDF=$(ls -t "$COVER_DIR"/*-${company_slug}*-cover.pdf 2>/dev/null | head -1)
[[ -z "$COVER_PDF" ]] && COVER_PDF=$(ls -t output/*-${company_slug}*-cover.pdf 2>/dev/null | head -1)
# NOTE: intentionally NO generic *cover*.pdf fallback — a wrong-company cover
# (e.g. Hootsuite's for an Intercom job) is worse than none; the on-demand
# path composes a tailored cover when no company-specific PDF exists.

# CACHED TAILORED COVER (optional, zero-cost reuse):
# If a cover payload exists for this job's report, patch its email and inject
# the tailored text into the prompt. Otherwise the model composes on-demand.
CACHED_COVER_TEXT=""
REPORT_FILE=$(grep -rlF "$URL" reports/*.md 2>/dev/null | grep -v RESERVED | head -1)
if [[ -n "$REPORT_FILE" ]]; then
  REPORT_NUM=$(basename "$REPORT_FILE" | grep -oE '^[0-9]+')
  CANDIDATE_PAYLOADS=()
  for dir in "$COVER_PAYLOAD_DIR" output/covers /tmp; do
    for p in "$dir"/cover-payload-${REPORT_NUM}.json "$dir"/cover-payload-*${company_slug}*.json; do
      [[ -f "$p" ]] && CANDIDATE_PAYLOADS+=("$p")
    done
  done
  PAYLOAD="${CANDIDATE_PAYLOADS[0]:-}"
  if [[ -n "$PAYLOAD" ]]; then
    PATCHED="/tmp/cover-payload-${REPORT_NUM}-patched.json"
    sed 's/old-email@example.com/${APPLY_EMAIL}/g' "$PAYLOAD" > "$PATCHED" 2>/dev/null
    CACHED_COVER_TEXT=$(python3 - "$PATCHED" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    l = d.get("letter", {})
    parts = [l.get("opening",""), l.get("profile_intro","")]
    for a in l.get("achievements", []):
        lead = a.get("lead",""); impact = a.get("impact","")
        parts.append(f"{lead} — {impact}" if lead and impact else (lead or impact))
    for k in ("problems_section","closing"):
        if l.get(k): parts.append(l[k])
    print("\n\n".join(p for p in parts if p).strip())
except Exception:
    sys.exit(1)
PYEOF
)
  fi
fi

echo "=========================================="
echo "APPLYING: $COMPANY — $ROLE ($SCORE)"
echo "URL: $URL"
echo "CV: ${CV_PDF:-none}"
echo "Cover: ${COVER_PDF:-none}"
echo "Cached cover text: $([[ -n "$CACHED_COVER_TEXT" ]] && echo "yes (${#CACHED_COVER_TEXT} chars)" || echo "no — will compose on-demand")"
echo "=========================================="

# Build the prompt via a PLAIN heredoc writing to a file (NOT wrapped in $() —
# bash's parser mishandles odd single-quote counts inside "$(cat <<'EOF' ...)":
# it breaks with "unexpected EOF while looking for matching `''. Writing the
# template to a file first keeps the heredoc parse clean, and placeholders are
# injected via {{PLACEHOLDERS}} + sed instead of shell expansion.
PROMPT_TEMPLATE="/tmp/apply-prompt-template.txt"
cat > "$PROMPT_TEMPLATE" <<'PROMPT_EOF'
You are filling and SUBMITTING a job application for ${APPLY_FULL_NAME} (${APPLY_LOCATION}; email ${APPLY_EMAIL}).

CANDIDATE PROFILE:
- 6+ years: Software Engineering Intern (2020) → CTO (2021-Present), real estate tech (India/UAE). 164 commits / 14 months of active development on the flagship platform (GitHub-verifiable).
- ARCHITECTED AND BUILT a production real estate platform (Next.js 15 App Router, React 19, TypeScript, Tailwind) on Supabase (Postgres/PostGIS/Auth/Storage/Edge Functions). 15+ routes: map search, radius search, multi-step listing forms, property details (React Server Components), 4 role-specific dashboards.
- GEOSPATIAL ENGINEERING: PostGIS geography(Point,4326) storage; viewport search via ST_Intersects + ST_MakeEnvelope; radius search with client-side Haversine great-circle math (64-vertex spherical polygon); MapLibre GL with 600ms debounced pan/zoom search, marker diffing (no teardown), MapTiler geocoding, draggable location picker.
- DATABASE ARCHITECTURE: 60+ idempotent timestamped PostgreSQL migrations; 16 lookup tables, 3 conditional detail tables (residential/commercial/land), 6 junction tables; a PL/pgSQL RPC data layer that returns the entire property graph as one jsonb document shape-matched to TypeScript types; cursor-based pagination.
- SECURITY: 30+ RLS policies with subquery role checks; write-closed audit trails (direct INSERT blocked with WITH CHECK (false), all writes forced through SECURITY DEFINER functions that stamp auth.uid() server-side, SET search_path hardening); storage folder-ownership policies; SECURITY DEFINER role-sync trigger to JWT claims; rate limiting, query sanitization, zod validation; patched React Server Components CVE-2025-55182/66478 (RCE via Flight deserialization).
- SCALED the platform to Zillow-scale: migrated search to Elasticsearch with Postgres fallback, Redis caching, autocomplete, synonyms, keyset pagination; ClickHouse H3 hexagonal clustering with AggregatingMergeTree materialized views + supercluster WebGL rendering (-90% data transfer); combined /api/map-data endpoint with request coalescing (50-200ms parallel ClickHouse+ES); BullMQ async event pipeline with Redis counter buffering (100ms/500-cmd batches); polygon boundary draw search.
- AI ASSISTANT: built a conversational property-search chatbot over 30+ iterations: pgvector semantic search (768-dim embeddings) → custom intent-routed agent (SEMANTIC/TEXT/PROJECT_NAME search intents, tools, session memory with history trim) → migrated to MCP (Model Context Protocol) server architecture with intent classifier and multi-provider LLM support (DeepSeek, MiMo, OpenRouter — 342+ models). 49/50 real chatbot queries passed (98%).
- AUTOMATION: Playwright scraper ingesting PropertyFinder.ae data across 7 UAE regions by parsing __NEXT_DATA__ SSR payloads (not DOM scraping), with chained GitHub Actions workflows (cron → scrape → sync); cross-database sync optimized from 2+ hours to 36 seconds via timestamp comparison, with hierarchical FK-safe location sync, stale-data pruning, and retry isolation.
- AI/ML: RAG chatbots with 87% retrieval precision, 70% faster support resolution; GPT-2 transformer trained from scratch (~200M params); document summarization pipeline processing 1M+ docs/month with ROUGE +25%.
- AUTH: Supabase SSR cookie sessions, MFA, phone sign-up, Telegram OTP edge function, custom access token hook embedding roles in JWTs.
- Skills: TypeScript, Python, JavaScript, SQL, PL/pgSQL; Next.js 15 (App Router, Server Actions, RSC), React 19, Tailwind CSS; PostgreSQL 15+, PostGIS, Elasticsearch, ClickHouse, Redis, Supabase, PGVector; MapLibre GL, Recharts, dnd-kit; Playwright; LangChain, LangGraph, RAG, vector search, MCP, AI agents; FastAPI, Node.js; AWS, Docker, Kubernetes, Terraform, GitHub Actions, Vercel; Jest, Cypress, Testing Library.
- Education: BCA Data Science (HITS Chennai, 2025, First Class 85%+), B.Com (Mumbai)
- Certifications: Harvard CS50 AI, Google Data Analytics, FreeCodeCamp (full-stack)
- LinkedIn: ${APPLY_LINKEDIN}
- GitHub: ${APPLY_GITHUB} (realestate-platform: 164 commits; property_scraper_v2)
- Availability: immediate (0 days notice)
- Salary expectation: $130K-$220K USD equivalent
- Visa: candidate is India-based; answer truthfully about needing sponsorship for US/EU roles

APPLYING TO: {{COMPANY}} — {{ROLE}} (score {{SCORE}})
JOB URL: {{URL}}
CV PDF: {{CV_PDF}}
COVER PDF: {{COVER_PDF}}

TASK — Apply to this job COMPLETELY:
1. playwright_browser_navigate to: {{URL}}
2. playwright_browser_snapshot to read the page
3. If job description page, find and click the Apply button (playwright_browser_click on 'Apply' / 'Apply for this Job')
4. playwright_browser_snapshot to read ALL form fields
   5. HUMAN-LIKE BEHAVIOR (helps CAPTCHAs pass — CRITICAL):
      - After page loads, wait 1-2 seconds before interacting (playwright_browser_wait_for)
      - The batch script below includes delays and scrolls between fields for human-like pacing
      - Before clicking Submit, wait 1-3 seconds and take one final snapshot
      - If an invisible reCAPTCHA / checkbox CAPTCHA appears: click it once and wait 2-3 seconds for it to verify (checkmark appears) before proceeding
   6. Fill EVERY field in ONE batch script — ZERO individual tool calls between fields:
      a. You already have ONE snapshot from step 4 with all fields — use it
      b. Analyze the snapshot to identify ALL fields, their refs, types, and what values they need
       c. Generate ONE playwright_browser_run_code_unsafe call that fills EVERY field it can:
           - SANDBOX RULES (ignore = wasted rerun): NO setTimeout — use page.waitForTimeout(ms) only. NO console.log — return values. Do NOT spawn @explore subagents or other agents to parse snapshots — read snapshots yourself.
           - SELECTOR RULE (MANDATORY): use ONLY the element refs from the snapshot you already took (e.g. f1e246) via page.locator(). If a field's ref is missing, take ONE fresh snapshot to find it BEFORE writing any selector. NEVER guess selectors from memory (#phone, input[name=...], getByRole) — guessed selectors fail and waste the whole run. Only use role/text-based locators when the snapshot has no ref for an element.
           - page.locator(ref).fill(text) for text inputs
           - page.locator(ref).click() for checkboxes/radios
           - fileChooser for uploads: page.waitForEvent('filechooser'), click ref, setFiles(path)
           - Autocomplete/dynamic dropdowns: type to trigger → page.waitForTimeout(800) → page.evaluate(() => read DOM options array) → click best match by text
           - Wrap EACH field in try/catch; return [{name, ok, err}] per field so failures are visible
           - Add page.waitForTimeout(200-400) between fields and page.locator(ref).scrollIntoViewIfNeeded() for human-like pacing
       d. DO NOT make individual click/type tool calls — everything goes in ONE script execution
       e. After the script returns results: READ the [{name, ok, err}] array carefully.
       f. TARGETED REPAIR PROTOCOL (MANDATORY): if SOME fields failed:
          1. Run ONE small fix script that touches ONLY the failed fields (by name). Do NOT re-run fields whose result was ok.
          2. Take ONE verification snapshot.
          3. Max 2 repair passes total. After pass 2, if fields still fail, do NOT loop again — proceed with whatever is filled, note the failed fields in your final summary, and continue to Submit (a failed optional field must not block the application).
       g. If ALL fields report ok after the first script, skip repair entirely and proceed to the verification step.
       FIELD VALUES (use these in the batch script):
      - First/Full Name: '${APPLY_FULL_NAME}'
      - Last Name: '${APPLY_LAST_NAME}'
      - Email: '${APPLY_EMAIL}'
       - Phone (CRITICAL FORMAT RULE): if the form has a SEPARATE country/region dropdown or country-code selector (which supplies the +91 prefix on its own), fill the phone field with ONLY '${APPLY_PHONE_LOCAL}' — do NOT include '+91' (that would duplicate the code). If the form has a SINGLE combined phone field with no separate country control, fill '${APPLY_PHONE_WITH_CODE}'. If the phone field displays the prefix separately (e.g. a leading +91 shown outside the input), the input value must be '${APPLY_PHONE_LOCAL}'.
       - Country/region dropdown (if present): select the option whose text EQUALS 'India' (exact match, case-insensitive, trimmed). NEVER select an option merely because it CONTAINS 'India' or 'Indian' (e.g. 'British Indian Ocean Territory' is WRONG). If no exact 'India' option exists, report it in the results as failed with the available options.
       - Country/region text-input (if a combobox, not a dropdown): type 'India' and select the exact 'India' autocomplete option from the list; if only a close-but-not-exact option appears (e.g. 'India (IN)'), select it only if it is unambiguously India.
      - LinkedIn: '${APPLY_LINKEDIN}'
      - GitHub/Website: '${APPLY_GITHUB}'
      - Location/City: '${APPLY_LOCATION}' (for autocomplete: type then select '${APPLY_LOCATION}' or closest match)
      - Resume/CV: upload '{{CV_PDF}}' via fileChooser. If exact file missing, use output/cv.md
      - Cover letter TEXT field or 'Additional Information':
        {{TAILORED_COVER_PLACEHOLDER}}
{{CACHED_COVER_TEXT}}
      - Cover letter FILE upload field: upload '{{COVER_PDF}}' if it exists. If it does NOT exist: compose the tailored cover text (same as the text-field instructions), save it to /tmp/cover-payload-{{REPORT_NUM}}.json using this structure: {"letter": {"role_title": "...", "company": "...", "opening": "...", "profile_intro": "...", "achievements": [{"lead": "...", "impact": "..."}], "problems_section": "...", "closing": "..."}}, then run: node generate-cover-letter.mjs --payload /tmp/cover-payload-{{REPORT_NUM}}.json --out "$COVER_DIR/{{REPORT_NUM}}-{{COMPANY_SLUG}}-cover.pdf"  (this is a LOCAL render — zero tokens). If the render fails the fact-check because a metric is not found in cv.md, retry ONCE with --skip-facts: node generate-cover-letter.mjs --skip-facts --payload ... (the metrics came from the verified CANDIDATE PROFILE, so skipping the gate is safe). Then upload the generated PDF. If the render still fails, upload the CV PDF instead and note it.
      - 'Tell us about yourself' field (if present): paste the READY-TO-USE 'TELL US ABOUT YOURSELF' paragraph below verbatim. Do NOT compose a new one.
      - 'Why this role/company': 2-3 sentences: e.g. "I built a full-stack real estate platform from scratch using Next.js 15 with PostGIS geospatial queries, a 4-role RBAC system, and a Playwright-based data pipeline — the same full-stack, systems-level ownership this role requires. I'm drawn to {{COMPANY}} because [reference something specific about the company's mission or tech]." Adapt based on the actual job description.
      - Work authorization / visa sponsorship: answer truthfully; for US/EU roles answer 'Yes, will require sponsorship'
      - Salary expectations: '$130K-$220K' or closest range option
      - Notice period: 'Immediate'
      - Start date: 'Immediate' or 'ASAP'
      - Education: 'Bachelor of Computer Applications - Data Science, Hindustan Institute of Technology and Science, 2025'
      - 'How did you hear' dropdown: select 'LinkedIn' or 'Other' + type 'Online job board'
      - Gender/EEO (if mandatory): Male if listed

COMPOSE A TAILORED COVER LETTER (for any cover letter TEXT field or 'Additional Information' — use this instead of pasting boilerplate):
Write a 300-400 word cover letter tailored to {{COMPANY}} and THIS JOB, using ONLY facts from the CANDIDATE PROFILE above (metrics: 87% retrieval precision, 70% faster support resolution, 1M+ docs/month, ROUGE +25%, 49/50 queries, 10K queries/day, GPT-2 ~200M params). NEVER invent facts or metrics. Structure:
- Opening (2 sentences): role title + company, why you're applying (reference a specific detail from the job description you read on the page — a product, team, mission, or tech requirement).
- Profile intro (2-3 sentences): AI-focused engineer and CTO, 6+ years, intern→CTO, production AI/LLM systems, distributed search, geospatial platforms.
- 2-3 achievement bullets matched to THIS job's top competencies (from the JD you read), each with a real metric from the profile.
- Company-specific closing (2 sentences): tie your experience to what {{COMPANY}} is building (reference a JD detail); availability immediate.
If the job emphasizes AI/agentic work, lead with the AI/agentic achievements; if infrastructure, lead with the platform/scaling achievements. Match the JD's emphasis.

READY-TO-USE 'TELL US ABOUT YOURSELF' (paste verbatim into any 'Tell us about yourself' / 'About you' field):
I'm a full-stack software engineer and CTO with six years of hands-on engineering. I started as an intern in 2020 and grew into leading a real estate technology company's platform. My defining work is a property platform I architected end-to-end: a Next.js 15 and React 19 frontend, a PostgreSQL schema evolved through 60+ versioned migrations, PostGIS geospatial search with map-based and radius filtering, and a four-role access control system backed by 30+ row-level security policies and spoof-proof audit logging. When the platform needed to scale, I migrated search to Elasticsearch with a Postgres fallback, added Redis caching, and built ClickHouse-based map clustering that cut data transfer by 90%. I also automated the data pipeline — a Playwright scraper and CI/CD-scheduled sync that keeps thousands of property listings fresh. On the AI side, I've built a conversational property assistant (pgvector semantic search → custom agent → MCP architecture, 98% query pass rate), trained a GPT-2 model from scratch, and run RAG and document-summarization systems in production. What I'm best at: taking a system from an idea to a secure, scalable, production product and owning it completely.
7. PRE-SUBMIT VALIDATION (MANDATORY — one snapshot, check all of these before touching Submit):
   a. All required fields have values (no empty required markers / red borders).
   b. Email field equals exactly ${APPLY_EMAIL}.
   c. Phone field has EXACTLY ONE country prefix total: either the form's country dropdown supplies it (then the field value must be the local number, e.g. 9876543210) OR the field contains the full international number (e.g. +91 9876543210) with no separate country control. NEVER both. Fix violations before submitting.
   d. No red error messages visible.
   e. Resume/CV file is attached (upload success indicator).
   Fix ONLY the violations found, then re-verify once, then proceed.
8. FIND AND CLICK THE SUBMIT / 'Submit Application' BUTTON
9. After submit, snapshot to confirm success (success message, 'application received', etc.). If the submit fails validation (captcha-failed, missing-field error), read the error, fix ONLY what it names, and retry submit ONCE. Never loop submits.

BLOCKER HANDLING (CRITICAL) — TWO TIERS:
If a CAPTCHA (hCaptcha, reCAPTCHA, Turnstile), email verification, or login/account-creation wall blocks the submit, classify it FIRST:

TIER 1 — IMAGE CHALLENGES: TRY 3 VISION SOLVES (MiMo v2.5), THEN ALERT:
  Includes: hCaptcha image challenges (drag/click/select images), reCAPTCHA image grids, Turnstile interactive puzzles.
  You are DeepSeek v4-flash (text-only) — you CANNOT see images yourself, but MiMo v2.5 (mimo-v2.5 via opencode-go) IS vision-capable. On the FIRST snapshot where you detect an image challenge:
  a. Attempt up to 3 vision solves (max 3 per site — more failures worsen the risk score):
     1. playwright_browser_take_screenshot of the challenge area
     2. Hand the screenshot to MiMo v2.5 (vision) for analysis: "Analyze this CAPTCHA screenshot. If there is a clear single action (click a specific tile at row/col, click a specific element), return exactly: ACTION: <click r,c | click | skip>. If the challenge is unsolvable by clicking (drag-to-slot, rotated images), return: ACTION: unsolvable"
     3. If ACTION is a confident single click → execute it via playwright_browser_click (or run_code_unsafe), wait 3-5 seconds, snapshot
     4. If the challenge cleared (checkmark/gone) → continue to Submit
     5. If not cleared → repeat up to 3 attempts TOTAL (fresh screenshot each time — puzzles change)
     6. If MiMo returns 'unsolvable' OR after 3 failed attempts → STOP immediately (do NOT keep retrying)
  b. If vision solves fail: run alert-user.sh (sound + voice + Skip & Continue):
     bash ${PROJECT_DIR}/batch/alert-user.sh "{{COMPANY}}" "{{ROLE}}" "<specific reason you detect>"
  c. Do NOT click 'Skip Challenge' repeatedly, do NOT inspect hCaptcha iframes, do NOT try accessibility hacks. Max 3 total vision attempts per site.
  d. HARD STOP after the alert: do NOT re-fill the form, do NOT re-upload the resume, do NOT click Submit again, do NOT restore anything. The page may have reloaded and wiped fields (HTTP 400) — that is FINE. Leave the browser exactly as-is. NEVER enter a re-fill/re-submit loop after exhausting vision attempts.
  e. Poll every 8 seconds (playwright_browser_snapshot) for up to 1 minute: if the CAPTCHA is gone (user solved it), click Submit, snapshot to confirm success, report RESULT: SUBMITTED.
  f. If after 1 minute it is still blocked, report RESULT: NEEDS_MANUAL with the reason.

TIER 2 — NON-IMAGE TASKS: SOLVE FIRST (max 3 attempts), ALERT ONLY IF STUCK:
  Includes: invisible/checkbox reCAPTCHA, email verification / OTP, clicking buttons, selecting options, filling fields.
  a. Attempt the task yourself:
     1. CHECKBOX or INVISIBLE reCAPTCHA (no image challenge): click the checkbox once, wait 3-5 seconds, snapshot to check for a green checkmark. If verified, click Submit. First click can fail — retry once more after a 2-second wait (attempt 2). Do not exceed 3 attempts.
     2. EMAIL VERIFICATION / OTP wall: BUILD HINTS dynamically from what you see — the company name, the ATS platform (visible in the URL — greenhouse, ashby, lever, workday), and any phrasing on the page (e.g. 'security code'). Like a human, you decide what to search for based on the application context. Run: bash ${PROJECT_DIR}/batch/read-otp.sh "COMPANY|ATS_DOMAIN|PAGE_PHRASE" (substitute the actual values you determined). If it prints OTP_CODE: <code>, type it in, click verify/continue, submit. If it prints a listing of newest emails (inspect fallback): READ the listing, identify the verification email (sender/subject/body), extract the code yourself from the printed body excerpt, type it in, submit. Do not give up because the script says NOT_FOUND — reason over the listing like a human would. Max 3 attempts.
  b. Only if still blocked after your attempts: run alert-user.sh with the specific reason:
     bash ${PROJECT_DIR}/batch/alert-user.sh "{{COMPANY}}" "{{ROLE}}" "<specific reason you detect>"
  c. Leave the browser on the blocked page. Do NOT re-fill anything — preserve all progress.
  d. Poll every 8 seconds (playwright_browser_snapshot) for up to 1 minute: if the blocker is cleared (user solved it), click Submit, snapshot to confirm success, report RESULT: SUBMITTED.
  e. If after 1 minute it is still blocked, report RESULT: NEEDS_MANUAL with the reason.
- If the form cannot be found at all (page 404/redirected/closed), report RESULT: CLOSED.
- If login/account creation is REQUIRED and cannot be skipped, report RESULT: NEEDS_MANUAL with reason.
- RESULT: NEEDS_MANUAL must ALWAYS be accompanied by the reason on the next line (REASON: ...).

IMPORTANT — FINAL OUTPUT FORMAT (print at the very end, exactly one of these):
RESULT: SUBMITTED
RESULT: NEEDS_MANUAL
RESULT: CLOSED

Then on the next line if NEEDS_MANUAL:
REASON: <specific blocker>
WHAT_FILLED: <brief summary of fields filled>
BLOCKED_FIELD: <the specific field/step where it blocked, if known>
PROMPT_EOF
prompt="$(cat "$PROMPT_TEMPLATE")"

# Inject values into the prompt (sed-special chars in values are escaped)
escape_sed() {
  printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}
PROMPT_FILE="/tmp/apply-prompt-current.txt"
if [[ -n "$CACHED_COVER_TEXT" ]]; then
  TAILORED_COVER_INSTR="PASTE THIS TAILORED COVER LETTER verbatim into the cover letter text field (already composed per-job):"
  CACHED_COVER_FILE="/tmp/cached-cover-${REPORT_NUM:-0}.txt"
  printf '%s' "$CACHED_COVER_TEXT" > "$CACHED_COVER_FILE"
else
  TAILORED_COVER_INSTR="COMPOSE a tailored cover letter now (see COMPOSE A TAILORED COVER LETTER below)."
  CACHED_COVER_FILE=""
fi
COMPANY_SLUG_SAFE=$(echo "$company_slug" | sed 's/[^a-z0-9-]//g')
sed -e "s|{{COMPANY}}|$(escape_sed "$COMPANY")|g" \
    -e "s|{{ROLE}}|$(escape_sed "$ROLE")|g" \
    -e "s|{{SCORE}}|$(escape_sed "$SCORE")|g" \
    -e "s|{{URL}}|$(escape_sed "$URL")|g" \
    -e "s|{{CV_PDF}}|$(escape_sed "${CV_PDF:-output/cv.md}")|g" \
    -e "s|{{COVER_PDF}}|$(escape_sed "${COVER_PDF:-none}")|g" \
    -e "s|{{REPORT_NUM}}|$(escape_sed "${REPORT_NUM:-unknown}")|g" \
    -e "s|{{COMPANY_SLUG}}|$(escape_sed "$COMPANY_SLUG_SAFE")|g" \
    -e "s|{{TAILORED_COVER_PLACEHOLDER}}|$(escape_sed "$TAILORED_COVER_INSTR")|g" \
    <<< "$prompt" > "$PROMPT_FILE"
# Inject the multi-line cached cover text via python (sed cannot handle newlines)
if [[ -n "$CACHED_COVER_FILE" ]]; then
  python3 - "$PROMPT_FILE" "$CACHED_COVER_FILE" <<'PYEOF'
import sys
prompt_path, cached_path = sys.argv[1], sys.argv[2]
content = open(prompt_path).read()
cached = open(cached_path).read()
content = content.replace("{{CACHED_COVER_TEXT}}", cached)
open(prompt_path, "w").write(content)
PYEOF
fi

# Expand identity config tokens (${APPLY_*}) inside the prompt text with the
# actual values loaded from apply-bot.env (or defaults). The heredoc is quoted,
# so these need explicit substitution here.
APPLY_EXPANSIONS=(
  "APPLY_FULL_NAME" "APPLY_FIRST_NAME" "APPLY_LAST_NAME" "APPLY_EMAIL"
  "APPLY_PHONE_WITH_CODE" "APPLY_PHONE_LOCAL" "APPLY_LOCATION"
  "APPLY_LINKEDIN" "APPLY_GITHUB"
)
for v in "${APPLY_EXPANSIONS[@]}"; do
  val="${!v:-}"
  if [[ -n "$val" ]]; then
    python3 - "$PROMPT_FILE" "\${$v}" "$val" <<'PYEOF'
import sys
path, token, value = sys.argv[1], sys.argv[2], sys.argv[3]
content = open(path).read()
content = content.replace(token, value)
open(path, "w").write(content)
PYEOF
  fi
done
prompt="$(cat "$PROMPT_FILE")"

echo "Prompt built: $(wc -c < "$PROMPT_FILE") bytes"

# Capture FULL output to a per-job file (no tail truncation — tee + tail causes
# SIGPIPE that truncates the file, losing the RESULT line at the end)
OUTFILE="/tmp/apply-worker-last-output.txt"

# WATCHDOG — hard time cap per job (900s = 15 min). A runaway worker (CAPTCHA
# re-fill/re-submit loops, stuck polls) must never eat the whole batch clock.
# macOS has no `timeout` binary, so use a background kill timer that targets
# ONLY this worker's opencode process (never pkill — that would kill the
# batch's other workers too).
JOB_WATCHDOG_SEC="${JOB_WATCHDOG_SEC:-900}"
WATCHDOG_PID=""
(
  sleep "$JOB_WATCHDOG_SEC"
  # Find the opencode started by THIS worker (the echo pipeline's child)
  WATCHDOG_OPCODE=$(pgrep -f "opencode run --auto" | head -1)
  [[ -n "$WATCHDOG_OPCODE" ]] && kill -9 "$WATCHDOG_OPCODE" 2>/dev/null
  echo ""
  echo "WATCHDOG: job exceeded ${JOB_WATCHDOG_SEC}s — killed opencode $WATCHDOG_OPCODE (see /tmp/apply-worker-last-output.txt)"
) &
WATCHDOG_PID=$!

echo "$prompt" | opencode run --auto -m "opencode-go/deepseek-v4-flash" 2>&1 | tee "$OUTFILE"
kill "$WATCHDOG_PID" 2>/dev/null
wait "$WATCHDOG_PID" 2>/dev/null

# Write result marker for the batch loop (reliable, per-job).
# Use the LAST RESULT line the model printed — the model's intermediate text
# may mention other RESULT values (planning/thinking), so substring grep
# anywhere in the file is unreliable. Take the final one only.
LAST_RESULT=$(grep -oE "RESULT: (SUBMITTED|NEEDS_MANUAL|CLOSED|SKIPPED_ALREADY_APPLIED)" "$OUTFILE" 2>/dev/null | tail -1 | awk '{print $2}')
case "$LAST_RESULT" in
  SUBMITTED)                echo "SUBMITTED" > /tmp/apply-result.txt ;;
  NEEDS_MANUAL)             echo "NEEDS_MANUAL" > /tmp/apply-result.txt ;;
  CLOSED)                   echo "CLOSED" > /tmp/apply-result.txt ;;
  SKIPPED_ALREADY_APPLIED)  echo "SKIPPED" > /tmp/apply-result.txt ;;
  *)                        echo "UNKNOWN" > /tmp/apply-result.txt ;;
esac

# DURABLE LEDGER — finalize: update this URL's row with the terminal result.
# Terminal outcomes are NEVER re-attempted:
#   - UNKNOWN (worker failed / no clear result) → SKIPPED_ALREADY_APPLIED —
#     re-running burns tokens for the same outcome, so treat as terminal.
#   - NEEDS_MANUAL with a PERMANENT rejection reason (application-limit,
#     90-day window, already-applied, "we couldn't submit") → SKIPPED —
#     retrying is futile.
#   - NEEDS_MANUAL with a SOLVABLE blocker (CAPTCHA/OTP) → stays NEEDS_MANUAL
#     (retryable once the user completes the manual task).
RESULT_VAL=$(cat /tmp/apply-result.txt 2>/dev/null)
[[ -z "$RESULT_VAL" ]] && RESULT_VAL="UNKNOWN"
LEDGER_STATUS="$RESULT_VAL"
if [[ "$RESULT_VAL" == "UNKNOWN" ]]; then
  LEDGER_STATUS="SKIPPED_ALREADY_APPLIED"
elif [[ "$RESULT_VAL" == "NEEDS_MANUAL" ]]; then
  REASON_TEXT=$(grep -aE "REASON:" "$OUTFILE" 2>/dev/null | tail -1)
  if echo "$REASON_TEXT" | grep -qiE "$PERMANENT_REASON_RE|90.day|three applications|received.*applications|we couldn.t submit"; then
    LEDGER_STATUS="SKIPPED_ALREADY_APPLIED"
  fi
fi
grep -vF "$URL" "$LEDGER" > "$LEDGER.tmp" 2>/dev/null
mv "$LEDGER.tmp" "$LEDGER"
printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%Y-%m-%d)" "$URL" "$COMPANY" "$ROLE" "$LEDGER_STATUS" >> "$LEDGER"

# Notify ONLY when manual action is needed (loud). Success/closed are silent —
# per-job notifications for hundreds of jobs would spam constantly.
if [[ "$LAST_RESULT" == "NEEDS_MANUAL" ]]; then
  notify_loud "Apply Bot" "manual action needed for $COMPANY"
fi

# Tracker flip — the durable idempotency record. Mark Applied when the outcome
# is terminal and reapplying would NEVER succeed:
#   SUBMITTED        → application sent
#   NEEDS_MANUAL     → only when the reason is a PERMANENT rejection
#                      (application-limit, already-applied, closed, 30-day
#                      window) — a CAPTCHA/OTP blocker is NOT permanent; the
#                      user may still solve it and submit, so do not flip.
#   CLOSED           → posting gone; reapplying is pointless
# This makes re-runs skip these jobs even if the ledger file is lost.
# Tracker flip — the durable idempotency record. Outcomes map to statuses:
#   SUBMITTED     → Applied (application genuinely sent)
#   NEEDS_MANUAL  → ONLY flipped when the reason is a PERMANENT rejection
#                   (application-limit, already-applied, closed, 30-day
#                   window) → Discarded (reapply will never be accepted).
#                   CAPTCHA/OTP/thread-link blockers are NOT flipped — the job
#                   stays Evaluated and eligible for future runs.
#   CLOSED        → Discarded (posting gone; reapplying is pointless)
# Discarded blocks re-application in is-applied.sh just like Applied does.
mark_tracker_final() {
  local status="$1" note="$2"
  REPORT=$(grep -rlF "$URL" reports/*.md 2>/dev/null | grep -v RESERVED | head -1)
  if [[ -n "$REPORT" ]]; then
    REPORT_NUM=$(basename "$REPORT" | grep -oE '^[0-9]+')
    ROW=$(grep -nF "reports/${REPORT_NUM}-" data/applications.md | head -1 | cut -d: -f1)
    if [[ -n "$ROW" ]]; then
      NUM=$(sed -n "${ROW}p" data/applications.md | awk -F'|' '{print $2}' | xargs)
      if [[ -n "$NUM" ]]; then
        echo "✓ Marking tracker row #$NUM as $status..."
        node set-status.mjs "$NUM" "$status" --note "$note" --force 2>&1 | tail -2
      fi
    fi
  fi
}

PERMANENT_REASON_RE='application.limit|already applied|30.day|30 day|not accept|reject|closed|no longer|unavailable|limit'

if [[ "$LAST_RESULT" == "SUBMITTED" ]]; then
  mark_tracker_final "Applied" "Submitted via ATS on $(date +%Y-%m-%d); URL: $URL"
elif [[ "$LAST_RESULT" == "NEEDS_MANUAL" ]]; then
  REASON_TEXT=$(grep -aE "REASON:" "$OUTFILE" 2>/dev/null | tail -1)
  if echo "$REASON_TEXT" | grep -qiE "$PERMANENT_REASON_RE"; then
    mark_tracker_final "Discarded" "ATS-rejected permanently on $(date +%Y-%m-%d) (reapply will not be accepted); URL: $URL"
  fi
elif [[ "$LAST_RESULT" == "CLOSED" ]]; then
  mark_tracker_final "Discarded" "Posting closed/unavailable on $(date +%Y-%m-%d) (reapply will not be accepted); URL: $URL"
fi

echo ""
echo "=== DONE: $COMPANY — $ROLE ==="
