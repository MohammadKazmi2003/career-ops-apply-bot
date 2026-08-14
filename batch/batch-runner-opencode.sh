#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.opencode/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BATCH_DIR="$SCRIPT_DIR"
INPUT_FILE="$BATCH_DIR/batch-input.tsv"
STATE_FILE="$BATCH_DIR/batch-state.tsv"
PROMPT_FILE="$BATCH_DIR/batch-prompt.md"
LOGS_DIR="$BATCH_DIR/logs"
TRACKER_DIR="$BATCH_DIR/tracker-additions"
REPORTS_DIR="$PROJECT_DIR/reports"
URL_INDEX="/tmp/career-ops-existing-urls.txt"

PARALLEL=4
DRY_RUN=false
RETRY_FAILED=false
START_FROM=0
MAX_RETRIES=2
LIMIT=0
STATUS_ONLY=false
MAX_PARALLEL=8
MODEL="opencode-go/deepseek-v4-flash"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err() { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
  cat <<'USAGE'
career-ops batch runner (OpenCode — deepseek-v4-flash)
Usage: batch-runner-opencode.sh [OPTIONS]
  --parallel N      Concurrent workers (default: 4, max: 8)
  --dry-run         Preview without processing
  --retry-failed    Retry failed offers
  --start-from N    Skip IDs below N
  --limit N         Max offers to process
  --status-only     Show status and exit
  --model M         Override model
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --parallel) PARALLEL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --retry-failed) RETRY_FAILED=true; shift ;;
    --start-from) START_FROM="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --status-only) STATUS_ONLY=true; shift ;;
    --model) MODEL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) log_err "Unknown: $1"; usage; exit 1 ;;
  esac
done

[[ "$PARALLEL" -gt "$MAX_PARALLEL" ]] && { log_warn "Capping $PARALLEL → $MAX_PARALLEL"; PARALLEL=$MAX_PARALLEL; }

mkdir -p "$LOGS_DIR" "$TRACKER_DIR" "$REPORTS_DIR"
[[ ! -f "$STATE_FILE" ]] && printf 'id\turl\tstatus\tstarted_at\tcompleted_at\treport_num\tscore\terror\tretries\n' > "$STATE_FILE"

# Build URL index (fast lookup)
build_url_index() {
  grep -rh "URL:" "$REPORTS_DIR"/*.md 2>/dev/null | grep -oE 'https://[^ |)]+' | sort -u > "$URL_INDEX"
}

# Check if URL already has a report
url_has_report() {
  local url="$1"
  grep -qF "$url" "$URL_INDEX" 2>/dev/null
}

# Global cleanup
cleanup_all() { rm -f "$BATCH_DIR"/batch-prompt-resolved-*.md; }
trap cleanup_all EXIT INT TERM

# Atomic report number allocation (lock file prevents parallel races)
get_next_report_num() {
  local lock="$BATCH_DIR/.report-num.lock"
  local max=100
  local num
  # Acquire lock (wait up to 10s)
  local waited=0
  while ! mkdir "$lock" 2>/dev/null; do
    [[ $waited -ge 100 ]] && { log_err "Could not acquire report lock"; return 1; }
    sleep 0.1
    waited=$((waited + 1))
  done
  # Recompute max (another worker may have created a report meanwhile)
  for f in "$REPORTS_DIR"/*.md; do
    [[ -f "$f" ]] || continue
    num=$(basename "$f" | grep -oE '^[0-9]+' | head -1)
    if [[ -n "$num" ]]; then
      num=$((10#$num))
      [[ "$num" -gt "$max" ]] && max="$num"
    fi
  done
  max=$((max + 1))
  # Reserve the slot by creating a placeholder file
  printf 'RESERVED\n' > "$REPORTS_DIR/$(printf "%03d" $max)-RESERVED.md"
  rmdir "$lock"
  printf "%03d" $max
}

if [[ "$STATUS_ONLY" == "true" ]]; then
  build_url_index
  total=$(wc -l < "$INPUT_FILE" | tr -d ' ')
  total=$((total - 1))
  completed=$(awk -F'\t' '$3=="completed"' "$STATE_FILE" 2>/dev/null | wc -l | tr -d ' ')
  failed=$(awk -F'\t' '$3=="failed"' "$STATE_FILE" 2>/dev/null | wc -l | tr -d ' ')
  reports=$(ls "$REPORTS_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
  indexed=$(wc -l < "$URL_INDEX" | tr -d ' ')
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Total: $total | Completed: $completed | Failed: $failed"
  echo "Reports: $reports | Indexed URLs: $indexed"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 0
fi

if [[ "$DRY_RUN" == "true" ]]; then
  build_url_index
  pending=0
  skipped=0
  while IFS=$'\t' read -r id url source notes; do
    [[ "$id" == "id" ]] && continue
    [[ "$id" -lt "$START_FROM" ]] && continue
    if url_has_report "$url"; then
      skipped=$((skipped + 1))
      continue
    fi
    pending=$((pending + 1))
  done < "$INPUT_FILE"
  log_info "Dry run: $pending new | $skipped already done"
  exit 0
fi

process_offer() {
  local id="$1" url="$2" notes="$3" worker_id="$4"

  if url_has_report "$url"; then
    return 0
  fi

  local report_num started_at log_file prompt_file today exit_code=0
  report_num=$(get_next_report_num)
  started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  log_file="$LOGS_DIR/${report_num}-${id}.log"
  prompt_file="$BATCH_DIR/batch-prompt-resolved-${id}.md"

  log_info "[$worker_id] #$id → report $report_num"

  today=$(date +%Y-%m-%d)
  sed -e "s|{{URL}}|$url|g" -e "s|{{REPORT_NUM}}|$report_num|g" \
      -e "s|{{DATE}}|$today|g" -e "s|{{ID}}|$id|g" \
      "$PROMPT_FILE" > "$prompt_file"

  cd "$PROJECT_DIR"
  cat "$prompt_file" | opencode run --auto -m "$MODEL" > "$log_file" 2>&1 || exit_code=$?
  rm -f "$prompt_file"

  local completed_at
  completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [[ $exit_code -eq 0 ]] && ls "$REPORTS_DIR/${report_num}-"*.md 1>/dev/null 2>&1; then
    local score
    score=$(grep -oE '[0-9]+\.[0-9]+/5' "$log_file" 2>/dev/null | tail -1 | cut -d'/' -f1 || echo "0")
    log_ok "[$worker_id] #$id score=$score"
    local company role slug
    company=$(echo "$notes" | cut -d'|' -f1 | xargs)
    role=$(echo "$notes" | cut -d'|' -f2 | xargs)
    slug=$(echo "$company" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-')
    echo -e "${report_num}\t$(date +%Y-%m-%d)\t${company}\t${role}\tEvaluated\t${score}/5\t❌\t[${report_num}](reports/${report_num}-${slug}-$(date +%Y-%m-%d).md)\tAuto-evaluated by batch" \
      > "$TRACKER_DIR/${report_num}-${id}.tsv"
    echo -e "${id}\t${url}\tcompleted\t${started_at}\t${completed_at}\t${report_num}\t${score}\t\t0" >> "$STATE_FILE"
  else
    log_err "[$worker_id] #$id failed"
    echo -e "${id}\t${url}\tfailed\t${started_at}\t${completed_at}\t${report_num}\texit $exit_code\t0" >> "$STATE_FILE"
  fi
}

build_url_index

declare -a pending_ids=() pending_urls=() pending_notes=()
while IFS=$'\t' read -r id url source notes; do
  [[ "$id" == "id" ]] && continue
  [[ "$id" -lt "$START_FROM" ]] && continue
  url_has_report "$url" && continue
  state=$(awk -F'\t' -v id="$id" '$1==id {print $3}' "$STATE_FILE" 2>/dev/null)
  [[ -z "$state" ]] && state="pending"
  [[ "$state" == "completed" ]] && continue
  if [[ "$state" == "failed" ]] && [[ "$RETRY_FAILED" != "true" ]]; then
    retries=$(awk -F'\t' -v id="$id" '$1==id {print $9}' "$STATE_FILE" 2>/dev/null || echo "0")
    [[ "$retries" -ge "$MAX_RETRIES" ]] && continue
  fi
  pending_ids+=("$id")
  pending_urls+=("$url")
  pending_notes+=("$notes")
done < "$INPUT_FILE"

total=${#pending_ids[@]}
[[ "$LIMIT" -gt 0 && "$total" -gt "$LIMIT" ]] && total=$LIMIT
log_info "Model: $MODEL | Pending: $total | Parallel: $PARALLEL"

processed=0
worker_id=0
for ((i=0; i<total; i++)); do
  while [[ $(jobs -r | wc -l) -ge $PARALLEL ]]; do
    wait -n 2>/dev/null || true
  done
  process_offer "${pending_ids[$i]}" "${pending_urls[$i]}" "${pending_notes[$i]}" "$worker_id" &
  worker_id=$((worker_id + 1))
  processed=$((processed + 1))
  sleep 1
done

wait
log_info "Done. Processed $processed."
cd "$PROJECT_DIR"
node merge-tracker.mjs 2>&1 || true
completed=$(awk -F'\t' '$3=="completed"' "$STATE_FILE" 2>/dev/null | wc -l | tr -d ' ')
failed=$(awk -F'\t' '$3=="failed"' "$STATE_FILE" 2>/dev/null | wc -l | tr -d ' ')
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Completed: $completed | Failed: $failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
