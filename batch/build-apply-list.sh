#!/usr/bin/env bash
# Build 5-column apply lists from the tracker + reports, split by score chunks.
# Usage: ./batch/build-apply-list.sh [min-score] [output]
#   Default: all Evaluated rows with score >= 2.5 → /tmp/apply-jobs-expanded.txt
#   Examples:
#     ./batch/build-apply-list.sh 3.5 /tmp/apply-35plus.txt
#     ./batch/build-apply-list.sh 3.0 /tmp/apply-30-34.txt
#   Chunked output (all tiers) is written to /tmp/apply-chunk-{35,30,25}.txt

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

MIN="${1:-2.5}"
OUT="${2:-/tmp/apply-jobs-expanded.txt}"
TMP="/tmp/apply-list-raw.txt"
rm -f "$TMP" "$OUT"

echo "Building apply list (score >= $MIN)..."

# 1) Collect tracker rows: status=Evaluated, score >= MIN
# Tracker cols: | # | date | company | role | score | status | pdf | report | notes |
# Convert score to numeric for comparison; keep raw score for output.
trim() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
grep '^|' data/applications.md | while IFS='|' read -r _ num date company role score status pdf report notes; do
  s="$(echo "$score" | trim)"
  st="$(echo "$status" | trim)"
  [[ "$st" != "Evaluated" ]] && continue
  n="${s%%/*}"
  num_n=$(echo "$n" | awk '{printf "%.1f", $1}')
  min_n=$(echo "$MIN" | awk '{printf "%.1f", $1}')
  awk -v a="$num_n" -v b="$min_n" 'BEGIN{exit !(a>=b)}' || continue
  num="$(echo "$num" | trim)"
  date="$(echo "$date" | trim)"
  company="$(echo "$company" | trim)"
  role="$(echo "$role" | trim)"
  report="$(echo "$report" | trim)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$num" "$date" "$company" "$role" "$s" "$report"
done > "$TMP"

echo "  Tracker rows collected: $(wc -l < "$TMP")"

# 2) Resolve URL from each row's report file
# Report link format: [num](../reports/NNN-slug-date.md) or [num](reports/...)
RESOLVED="/tmp/apply-list-resolved.txt"
rm -f "$RESOLVED"
while IFS=$'\t' read -r num date company role score report; do
  rpt_num=$(echo "$report" | grep -oE '[0-9]+' | head -1)
  rpt_file=$(ls reports/${rpt_num}-*.md 2>/dev/null | grep -v RESERVED | head -1)
  [[ -z "$rpt_file" ]] && continue
  url=$(grep -m1 '^\*\*URL:\*\*' "$rpt_file" | sed 's/^\*\*URL:\*\*[[:space:]]*//; s/[[:space:]]*$//')
  [[ -z "$url" ]] && continue
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$date" "$company" "$role" "$score" "$url" "$num"
done < "$TMP" >> "$RESOLVED"

echo "  With resolvable URL: $(wc -l < "$RESOLVED")"

# 3) Dedupe by URL (keep the highest-score row)
awk -F'\t' '!seen[$5]++' "$RESOLVED" > "$OUT"
echo "  After URL dedup: $(wc -l < "$OUT")"

# 4) Chunked outputs
awk -F'\t' '{split($4,s,"/"); if (s[1]+0 >= 3.5) print $1"\t"$2"\t"$3"\t"$4"\t"$5}' "$OUT" > /tmp/apply-chunk-35.txt
awk -F'\t' '{split($4,s,"/"); if (s[1]+0 >= 3.0 && s[1]+0 < 3.5) print $1"\t"$2"\t"$3"\t"$4"\t"$5}' "$OUT" > /tmp/apply-chunk-30.txt
awk -F'\t' '{split($4,s,"/"); if (s[1]+0 >= 2.5 && s[1]+0 < 3.0) print $1"\t"$2"\t"$3"\t"$4"\t"$5}' "$OUT" > /tmp/apply-chunk-25.txt

echo ""
echo "=== CHUNKS ==="
echo "  ≥3.5:   $(wc -l < /tmp/apply-chunk-35.txt)  → /tmp/apply-chunk-35.txt"
echo "  3.0-3.4: $(wc -l < /tmp/apply-chunk-30.txt)  → /tmp/apply-chunk-30.txt"
echo "  2.5-2.9: $(wc -l < /tmp/apply-chunk-25.txt)  → /tmp/apply-chunk-25.txt"
echo ""
echo "=== SAMPLE (first 3 of $OUT) ==="
head -3 "$OUT" | while IFS=$'\t' read -r d c r s u; do echo "  $d | $c | $r | $s | ${u:0:60}"; done
