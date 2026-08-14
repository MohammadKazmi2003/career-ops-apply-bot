# Career-Ops + Apply Bot

**Automate your job search — scan, evaluate, and apply to jobs automatically.**

This project helps you apply for jobs faster. It:
1. **Scans** 150+ company job boards for roles that match you
2. **Evaluates** each job (scores it 0–5 against your profile)
3. **Applies** — fills and submits the application form for you (the Apply Bot)
4. **Tracks** everything in a simple tracker

> ⚠️ **Privacy:** this repo contains **zero personal data**. Your name, email,
> phone, and resume paths are stored in a local config file that is never
> committed. Safe to clone and use.

---

## How is this different from the original career-ops?

The original [career-ops](https://github.com/santifer/career-ops) scans and
evaluates jobs, but **you fill application forms yourself**. This fork adds
the **Apply Bot** that fills and submits them for you:

| Feature | Original career-ops | This fork |
|---------|--------------------|-----------|
| Scan job boards | ✅ | ✅ |
| Evaluate jobs (score 0–5) | ✅ | ✅ |
| Track applications | ✅ | ✅ |
| Tailored resume PDFs | ✅ | ✅ |
| **Auto-fill application forms** | ❌ | ✅ |
| **Auto-submit applications** | ❌ | ✅ |
| **CAPTCHA handling** (checkbox + vision) | ❌ | ✅ |
| **Email OTP reading** | ❌ | ✅ |
| **Never double-applies** (idempotent) | ❌ | ✅ |
| **Per-job tailored cover letters** | ❌ | ✅ |

---

## Quick start — 6 steps

> **Total time: ~15 minutes** to get set up.

### Step 1 — Install dependencies

You need:
- **Node.js 18+** and npm
- **Python 3**
- An **AI coding CLI** — [opencode](https://opencode.ai), Claude Code, Codex, or
  Gemini CLI (see [docs/SETUP.md](docs/SETUP.md) and
  [docs/SUPPORTED_CLIS.md](docs/SUPPORTED_CLIS.md))
- **Google Chrome** (the bot drives a real browser)

```bash
npm install
```

### Step 2 — Configure your profile (who you are)

```bash
cp config/profile.example.yml config/profile.yml
```

Edit `config/profile.yml` with your name, email, target roles, and salary range:

```yaml
candidate:
  full_name: "Your Name"
  email: "you@gmail.com"
  phone: "+1 555 123 4567"
target_roles:
  primary:
    - "Software Engineer"
    - "AI Engineer"
```

### Step 3 — Configure job scanning (what to search for)

```bash
cp templates/portals.example.yml portals.yml
```

Edit `portals.yml`:
- **`title_filter.positive`** — job titles you want (e.g. `AI Engineer`, `Backend Engineer`)
- **`tracked_companies`** — add/remove companies whose boards you want scanned

### Step 4 — Configure the Apply Bot (your identity)

```bash
cp batch/apply-bot.env.example batch/apply-bot.env
```

Edit `batch/apply-bot.env` — this is what the bot fills into forms:

```bash
APPLY_FULL_NAME="Your Name"
APPLY_EMAIL="you@gmail.com"
APPLY_PHONE_WITH_CODE="+1 555 123 4567"   # full international format
APPLY_PHONE_LOCAL="5551234567"            # digits only (used when a country dropdown exists)
APPLY_LOCATION="Your City, Your Country"
APPLY_LINKEDIN="https://www.linkedin.com/in/your-profile"
APPLY_GITHUB="https://github.com/your-username"
```

### Step 5 — Add your resume (cv.md)

Create `cv.md` in the project root with your resume in plain markdown:

```markdown
# Your Name

**Email:** you@gmail.com
**LinkedIn:** https://www.linkedin.com/in/your-profile

## Summary
Brief intro about you...

## Experience
### Senior Software Engineer — Company (2022–Present)
- Did thing, with result
```

> The bot reads this file to answer "tell us about yourself" questions and to
> generate tailored resumes.

---

## Running the pipeline (3 commands)

After setup, the workflow is: **scan → evaluate → apply**.

### Command 1 — Scan for jobs

```bash
node scan.mjs --verify
```

This checks 150+ company job boards, finds new roles matching your
`portals.yml` filters, and saves them to `data/pipeline.md`.

**What you'll see:** a list of new job URLs added to your pipeline.

### Command 2 — Evaluate the jobs

```bash
# Tell your AI CLI to evaluate everything in the pipeline:
#   e.g. opencode:  opencode run "Run the career-ops pipeline mode for data/pipeline.md"
#        codex:     codex exec "Run career-ops pipeline mode for data/pipeline.md"
```

This reads each job URL, compares it to your profile, and writes:
- A **report** per job in `reports/` (with a score like `4.2/5`)
- A row in the **tracker** (`data/applications.md`)

**What you'll see:** scores for each job, e.g. `4.2/5 — strong match`.

### Command 3 — Apply automatically

```bash
# 1. Build your apply list (all jobs scored >= 3.0)
./batch/build-apply-list.sh 3.0 /tmp/apply-jobs.txt

# 2. Start the apply bot
nohup ./batch/apply-to-jobs.sh /tmp/apply-jobs.txt > /tmp/apply-batch.log 2>&1 &

# 3. Watch it work
tail -f /tmp/apply-log.txt
```

The bot will:
- Open each job's application form in Chrome
- Fill every field (name, email, phone, dropdowns, checkboxes, essays, uploads)
- Verify before submitting (email correct, phone format, no errors)
- Click **Submit**
- Skip jobs already applied to (never double-applies)
- **Alert you (sound + voice) only when it needs your help** (e.g. a CAPTCHA)

**What you'll see:** progress like `Job 12/47: Google — AI Engineer | SUBMITTED`.

---

## How the Apply Bot works

```
apply-to-jobs.sh (the batch loop)
  └─ apply-worker.sh "Company" "Role" "4.2/5" "https://job-url"
       ├─ is-applied.sh → already applied? skip (idempotent)
       ├─ finds your tailored resume + cover for THIS company
       ├─ opens the form in a real Chrome browser
       ├─ fills ALL fields in ONE batch script
       ├─ verifies before submit
       ├─ handles CAPTCHAs (see below)
       └─ writes the result to a durable ledger (never re-applies)
```

---

## CAPTCHA handling — what to expect

| Type | What happens |
|------|--------------|
| **Checkbox / invisible CAPTCHA** | Bot clicks it, waits, verifies, continues ✅ |
| **Image challenge** (hCaptcha "select the animals") | Bot screenshots it, asks a vision model (MiMo v2.5), tries up to **3 times** |
| **Still stuck?** | Bot **alerts you** (sound + spoken message) with a **"Skip & Continue"** button. Solve it in the open Chrome tab, and the batch resumes automatically. |

> **Honest note:** drag-and-drop image CAPTCHAs are very hard for any
> automation. You'll occasionally be asked to solve one — that's by design
> (it's the difference between working and getting your IP flagged).

---

## Key files

| File | What it does |
|------|--------------|
| `batch/apply-to-jobs.sh` | The batch runner — processes a list of jobs |
| `batch/apply-worker.sh` | Fills + submits ONE application |
| `batch/apply-bot.env` | **Your identity config (gitignored — never commit)** |
| `batch/build-apply-list.sh` | Builds the job list from your tracker |
| `batch/is-applied.sh` | Checks if a job was already applied to |
| `batch/read-otp.sh` | Reads email verification codes (OTP) |
| `batch/alert-user.sh` | Sound + voice alert when you're needed |
| `batch/cover-worker.sh` | Generates tailored cover letters |
| `batch/pdf-worker.sh` | Generates tailored resume PDFs |
| `data/applied-ledger.tsv` | Tracks what's been applied to (never double-apply) |

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| **"Browser is already in use"** | Kill leftovers: `pkill -9 -f "opencode run"; pkill -9 -f "apply-worker"` |
| **The bot skipped everything** | That's the idempotency ledger working. Delete `data/applied-ledger.tsv` to force a fresh start. |
| **Apply list is empty** | You haven't evaluated jobs yet — run Command 2 (evaluate) first. |
| **CAPTCHA alerts are annoying** | Click "Skip & Continue" to move on without solving. |
| **Nothing happens when I run the batch** | Test your AI CLI: `echo "hello" | opencode run --auto` should reply. Then check `/tmp/apply-batch.log`. |

---

## Docs

- [Setup guide](docs/SETUP.md) — full installation
- [Supported CLIs](docs/SUPPORTED_CLIS.md)
- [Architecture](ARCHITECTURE.md)
- [Apply bot setup](batch/README.md)

## License

[MIT](LICENSE) — same as the original career-ops.
