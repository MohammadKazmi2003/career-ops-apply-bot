# Apply Bot — Automated Job Application Worker

A set of scripts that fill and submit job applications via headless browser
automation (Playwright) with an LLM (opencode).

> **Privacy:** everything here is identity-agnostic. Your personal details
> (name, email, phone, resume paths) live in `batch/apply-bot.env`, which is
> gitignored. Copy `batch/apply-bot.env.example` → `batch/apply-bot.env` and
> fill in your own values before running anything.

## Scripts

| Script | Purpose |
|--------|---------|
| `apply-to-jobs.sh <list-file>` | Run the batch: process a tab-separated job list (`date␟company␟role␟score␟url`) sequentially |
| `apply-worker.sh <company> <role> <score> <url>` | Fill + submit ONE application (called by the batch) |
| `is-applied.sh <url>` | Idempotency gate — returns 0 if the job was already processed |
| `build-apply-list.sh [min-score] [out]` | Build a 5-column apply list from tracker + reports |
| `alert-user.sh <company> <role> [reason]` | Loud notification (sound + voice + dialog) when manual action is needed |
| `read-otp.sh "<hints|pipe|separated>"` | Read an email OTP/verification code (Gmail IMAP) |
| `read-otp-imap.py` | IMAP backend for `read-otp.sh` |
| `cover-worker.sh <report-file>` | Generate a tailored cover letter PDF + payload |
| `pdf-worker.sh <report-file>` | Generate a tailored resume PDF |
| `gen-all-missing-pdfs.sh` / `gen-pdf-for-report.sh` / `gen-pdfs-from-list.sh` | Batch resume/cover generation helpers |
| `backfill-applied.sh <url-list>` | Mark tracker rows as Applied for confirmed submissions |

## Setup

1. **Configure identity** (required):
   ```bash
   cp batch/apply-bot.env.example batch/apply-bot.env
   # edit batch/apply-bot.env with YOUR name, email, phone, resume/cover dirs
   ```

2. **Resume/cover directories**: the worker looks for per-job tailored resumes
   and covers in the folders configured in `apply-bot.env`
   (`APPLY_RESUME_DIR`, `APPLY_COVER_DIR`). Place your
   `cv-candidate-{slug}*.pdf` and `{report}-{company}-cover.pdf` files there.

3. **Gmail OTP (optional)**: create `~/.gmail-mcp/imap-credentials.json`
   (gitignored, outside the repo):
   ```json
   {"email": "you@gmail.com", "password": "<16-char App Password>"}
   ```

4. **Run**:
   ```bash
   # 1. Build your apply list (score >= 3.0)
   ./batch/build-apply-list.sh 3.0 /tmp/apply-jobs.txt
   # 2. Start the batch
   nohup ./batch/apply-to-jobs.sh /tmp/apply-jobs.txt > /tmp/apply-batch.log 2>&1 &
   # 3. Track
   tail -f /tmp/apply-log.txt
   ```

## Dependencies

- `opencode` CLI (`~/.opencode/bin`) with an LLM provider
- Node.js + Playwright (for browser automation + PDF generation)
- Python 3 + `supabase`/`playwright` for the OTP reader and scraping helpers

## Notes

- The batch is **idempotent**: already-applied jobs are skipped via
  `data/applied-ledger.tsv` (a durable ledger in the repo's `data/` dir).
- CAPTCHA/image challenges alert the user (loud sound + spoken message) and
  poll for a manual solve before reporting `NEEDS_MANUAL`.
- Each worker is time-capped (15 min default) so a stuck job can't stall the
  batch.
