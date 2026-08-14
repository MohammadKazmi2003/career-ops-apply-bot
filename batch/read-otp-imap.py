#!/usr/bin/env python3
"""Gmail OTP/verification code reader via IMAP — 3-stage pipeline.

Stage 1: hint-scoring — score newest N messages against hint tokens
         (sender/subject/body). Progressive depth: 10 -> 30 -> 60.
Stage 2: inspect — print a listing of the newest N emails (subject/sender/
         date/body excerpt) so the LLM can reason and identify the code.
Stage 3: retry — caller re-invokes; this script is stateless per call.

Usage:
  read-otp-imap.py --score "<hint1|hint2|hint3>" [--depth 10|30|60]
  read-otp-imap.py --inspect [--count 10]
  read-otp-imap.py --search-term "<term>" [--depth 30]

Config: ~/.gmail-mcp/imap-credentials.json
"""
import imaplib, email, re, sys, json, os, time, argparse
from email.header import decode_header

# Words that look like 8-char codes but are common prose
FALSE_POSITIVES = {
    "mohammad", "position", "consider", "meantime", "patience", "interest",
    "engineer", "software", "learning", "platform", "possible", "visiting",
    "foremost", "gathered", "openings", "continue", "linkedin", "overflow",
    "identity", "settings", "accounts", "security", "resubmit", "application",
    "received", "hightouch", "deployed", "surname", "company", "because",
}

CODE_RE = re.compile(r"([A-Za-z0-9]{5,10})")
NEAR_RE = re.compile(
    r"(?:code|otp|pin|verification|security\s*cod|one-?time|confirm|verify|enter)\b[^A-Za-z0-9]{0,25}?([A-Za-z0-9]{5,10})",
    re.I,
)
# Explicit "copy and paste this code" patterns — the real Greenhouse format
PASTE_RE = re.compile(
    r"(?:code into the security code field on your application|copypaste|copy and paste|your (?:verification )?code is|enter(?: the| this)? code|your code:|verification code is)\s*[:\s]*([A-Za-z0-9]{5,10})",
    re.I,
)


def load_creds():
    path = os.path.expanduser("~/.gmail-mcp/imap-credentials.json")
    if not os.path.exists(path):
        print("ERROR: create ~/.gmail-mcp/imap-credentials.json")
        sys.exit(1)
    with open(path) as f:
        return json.load(f)


def decode(s):
    if not s:
        return ""
    parts = decode_header(s)
    out = ""
    for txt, enc in parts:
        if isinstance(txt, bytes):
            try:
                out += txt.decode(enc or "utf-8", errors="replace")
            except Exception:
                out += txt.decode("utf-8", errors="replace")
        else:
            out += txt
    return out


def get_body(msg):
    """Return plain-text body (decode both text/plain and text/html)."""
    body = ""
    if msg.is_multipart():
        for part in msg.walk():
            ct = part.get_content_type()
            if ct == "text/plain":
                try:
                    body = part.get_payload(decode=True).decode(errors="replace")
                    break
                except Exception:
                    continue
        if not body:
            for part in msg.walk():
                if part.get_content_type() == "text/html":
                    try:
                        body = part.get_payload(decode=True).decode(errors="replace")
                        body = re.sub(r"<[^>]+>", " ", body)
                        break
                    except Exception:
                        continue
    else:
        try:
            body = msg.get_payload(decode=True).decode(errors="replace")
        except Exception:
            body = str(msg.get_payload())
    return body


def connect():
    creds = load_creds()
    M = imaplib.IMAP4_SSL(creds.get("host", "imap.gmail.com"))
    M.login(creds["email"], creds["password"])
    M.select("INBOX")
    return M


def fetch_newest(M, depth, days=3):
    """Return list of (num, msg) for the NEWEST `depth` messages (last `days` days)."""
    since = time.strftime("%d-%b-%Y", time.gmtime(time.time() - days * 86400))
    typ, data = M.search(None, f'(SINCE "{since}")')
    nums = data[0].split() if data[0] else []
    if not nums:
        return []
    newest = nums[-depth:]
    out = []
    for num in newest:
        typ, msg_data = M.fetch(num, "(RFC822)")
        if msg_data and msg_data[0] and isinstance(msg_data[0], tuple):
            out.append((num, email.message_from_bytes(msg_data[0][1])))
    return out


def extract_code(subj, body, sender):
    """Extract a plausible verification code from combined text."""
    text = subj + " " + body
    # 1. Explicit Greenhouse "copy and paste this code into the ... field: XXXX"
    for m in PASTE_RE.finditer(text):
        cand = m.group(1)
        if cand.lower() not in FALSE_POSITIVES and re.fullmatch(r"[A-Za-z0-9]{5,10}", cand):
            return cand
    # 2. Codes near code-keywords (skip obvious prose like "field")
    for m in NEAR_RE.finditer(text):
        cand = m.group(1)
        if cand.lower() in FALSE_POSITIVES:
            continue
        if cand.lower() in ("field", "below", "above", "email", "phone", "your"):
            continue
        if cand.isalpha() and len(cand) == 8:
            continue
        if re.fullmatch(r"[A-Za-z0-9]{5,10}", cand):
            return cand
    # 3. Fallback: any 6-10 alnum token not in false positives
    for cand in CODE_RE.findall(text):
        if cand.lower() in FALSE_POSITIVES:
            continue
        if cand.isalpha():
            continue
        if re.fullmatch(r"[A-Za-z0-9]{6,10}", cand):
            return cand
    return None


def score_email(msg, hints):
    """Score a message against hint tokens."""
    subj = decode(msg.get("Subject", ""))
    frm = decode(msg.get("From", ""))
    date = msg.get("Date", "")
    body = get_body(msg)
    text = f"{subj} {frm} {body}".lower()
    score = 0
    matched = []
    for hint in hints:
        if hint and hint.lower() in text:
            score += 3
            matched.append(hint)
    # Body contains code-ish phrasing
    if re.search(r"code|otp|verification|confirm|security", text, re.I):
        score += 2
    if CODE_RE.search(body) or NEAR_RE.search(body):
        score += 2
    return score, matched, subj, frm, date, body


def mode_score(hints, depth):
    M = connect()
    try:
        msgs = fetch_newest(M, depth)
        best = None
        best_score = 0
        for num, msg in msgs:
            score, matched, subj, frm, date, body = score_email(msg, hints)
            if score > best_score:
                best_score = score
                best = (num, msg, score, matched, subj, frm, date, body)
        if best and best_score >= 4:
            num, msg, score, matched, subj, frm, date, body = best
            code = extract_code(subj, body, frm)
            if code:
                print(f"OTP_CODE: {code}")
                print(f"MATCHED: score={score} hints={matched} subj={subj[:60]} from={frm[:50]}")
                return 0
            else:
                print(f"OTP_CODE: NOT_FOUND (matched email but no code parsed)")
                print(f"MATCHED: score={score} hints={matched} subj={subj[:60]} from={frm[:50]}")
                print(f"BODY_EXCERPT: {body[:300]}")
                return 1
        print("OTP_CODE: NOT_FOUND")
        return 1
    finally:
        M.logout()


def mode_inspect(count):
    M = connect()
    try:
        msgs = fetch_newest(M, count)
        print("=== NEWEST EMAILS ===")
        for i, (num, msg) in enumerate(msgs, 1):
            subj = decode(msg.get("Subject", ""))
            frm = decode(msg.get("From", ""))
            date = msg.get("Date", "")
            body = get_body(msg)
            excerpt = re.sub(r"\s+", " ", body)[:250]
            print(f"[{i}] SUBJ: {subj[:70]} | FROM: {frm[:55]} | DATE: {date[:25]}")
            print(f"    BODY: {excerpt}")
        return 0
    finally:
        M.logout()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--score", help="hint tokens separated by |")
    ap.add_argument("--depth", type=int, default=10, help="newest N to scan")
    ap.add_argument("--inspect", action="store_true", help="print newest emails listing")
    ap.add_argument("--count", type=int, default=10, help="how many to inspect")
    ap.add_argument("--search-term", help="simple term search (legacy)")
    args = ap.parse_args()

    if args.inspect:
        sys.exit(mode_inspect(args.count))

    if args.score:
        hints = [h.strip() for h in args.score.split("|") if h.strip()]
        sys.exit(mode_score(hints, args.depth))

    # Legacy: single search term
    if args.search_term:
        hints = [args.search_term]
        sys.exit(mode_score(hints, args.depth))

    print("Usage: read-otp-imap.py --score 'hint1|hint2' [--depth N] | --inspect [--count N]")
    sys.exit(2)


if __name__ == "__main__":
    main()
