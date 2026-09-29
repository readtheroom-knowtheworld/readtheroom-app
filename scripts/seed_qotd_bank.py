#!/usr/bin/env python3
# Copyright (C) 2025 Soud Al Kharusi
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Generate the SQL that seeds the initial QOTD question bank.

Reads a JSON file of questions (produced by a separate Claude session — run
`--print-brief` for the exact request text to paste there), validates it, and
writes a single-transaction SQL file to run in the Supabase SQL editor.

Usage:
    python3 scripts/seed_qotd_bank.py --print-brief
    python3 scripts/seed_qotd_bank.py questions.json
    python3 scripts/seed_qotd_bank.py questions.json \
        --country-code US --author-id <uuid> --out seed_questions.sql

Input JSON format (a top-level array):
    [
      {"prompt": "Is a hot dog a sandwich?",
       "description": "Structurally speaking.",           // optional
       "type": "multiple_choice",
       "options": ["Yes", "No", "It's a taco"]},
      {"prompt": "Pineapple belongs on pizza.",
       "type": "approval_rating",                          // no options
       "low_label": "Keep it off",                         // slider low end
       "high_label": "Belongs on pizza"}                   // slider high end
    ]

What the generated SQL does (mirrors the app's own insert path in
question_service.submitQuestion — see DBarchitecture.md):
  - INSERT INTO questions (prompt, description, type, country_code,
    targeting_type='globe', nsfw=false, is_hidden=false, is_private=false,
    author_id, is_seeded=true) — author_id defaults to NULL (anonymous).
    is_seeded requires the prefer_organic_qotd.sql migration to run FIRST.
  - For multiple_choice: INSERT INTO question_options (question_id,
    option_text, sort_order), one row per option.
  - For approval_rating: INSERT INTO question_options exactly TWO rows
    naming the slider ends — sort_order 0 = low/thumbs-down ("low_label",
    default "Disagree"), sort_order 1 = high/thumbs-up ("high_label",
    default "Agree"). Same shape the app writes in
    question_service.submitQuestion; see DBarchitecture.md → question_options
    and lib/src/utils/approval_labels.dart. (The app's own fallbacks are
    "Disapprove"/"Approve"; seeded prompts are all statements, so the bank
    defaults to "Disagree"/"Agree" and names better ends where it can.)
  - Wrapped in BEGIN/COMMIT with a sentinel guard that aborts if the first
    prompt already exists, so running the file twice cannot double-seed.
"""

import argparse
import json
import sys
from collections import Counter

EXPECTED_COUNT = 365
SPLIT_TOLERANCE = 0.10  # warn if either type is <40% or >60% of the bank
MAX_PROMPT_CHARS = 200
MAX_DESCRIPTION_WORDS = 300
MIN_OPTIONS, MAX_OPTIONS = 2, 6
# Approval slider-end labels (WP-B convention). Mirrors
# kApprovalLabelMaxLength in lib/src/utils/approval_labels.dart.
MAX_LABEL_CHARS = 20
# Every seeded approval prompt is a statement, so the bank's fallback ends are
# agreement words rather than the app's generic "Disapprove"/"Approve".
DEFAULT_LOW_LABEL = "Disagree"
DEFAULT_HIGH_LABEL = "Agree"

BRIEF = f"""\
Please write exactly {EXPECTED_COUNT} Question-of-the-Day candidates for
"Read the Room", a global anonymous social Q&A app where the whole world
answers one question a day. Output ONLY a JSON array, no prose, in this
format:

[
  {{"prompt": "Is a hot dog a sandwich?",
    "description": "Structurally speaking.",
    "type": "multiple_choice",
    "options": ["Yes", "No", "It's a taco"]}},
  {{"prompt": "Pineapple belongs on pizza.",
    "type": "approval_rating",
    "low_label": "Keep it off",
    "high_label": "Belongs on pizza"}}
]

Rules:
- Exactly {EXPECTED_COUNT} entries; roughly half "multiple_choice" and half
  "approval_rating" (183/182 either way is perfect).
- multiple_choice: {MIN_OPTIONS}-{MAX_OPTIONS} short, distinct options; no
  "all of the above". approval_rating: a statement or yes/no-style question
  people agree/disagree with on a slider; NO "options" key.
- approval_rating: name the two slider ends with "low_label" (the
  thumbs-down end) and "high_label" (the thumbs-up end). Both are optional
  and default to "{DEFAULT_LOW_LABEL}"/"{DEFAULT_HIGH_LABEL}", which is the
  right answer for a plain statement — so only write your own when the
  statement has a sharper two-sided framing ("Cereal is a soup." →
  "Not soup"/"Soup"; "Dogs are better than cats." → "Team cats"/"Team dogs").
  Max {MAX_LABEL_CHARS} characters each, no trailing punctuation, and NEVER
  spell the ends out in the description — the slider shows them itself.
- "description" is optional — include one only when a line of context makes
  the question better; keep it under a sentence or two.
- Prompts under {MAX_PROMPT_CHARS} characters, unique, self-contained, and
  answerable by anyone anywhere (no country-specific, no current-events
  that will date badly, nothing requiring niche knowledge).
- Tone: curious, playful, occasionally deep. Mix everyday debates, would-
  you-rathers, values, habits, food, tech, relationships, philosophy.
- Strictly no NSFW, politics-of-the-day, medical/legal advice bait, or
  anything targeting a group.
"""


def fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def warn(msg: str) -> None:
    print(f"WARNING: {msg}", file=sys.stderr)


def sql_str(value: str) -> str:
    """Escape a string as a single-quoted SQL literal."""
    cleaned = "".join(ch for ch in value if ch == "\n" or ord(ch) >= 32)
    return "'" + cleaned.replace("'", "''") + "'"


def approval_labels(q: dict) -> tuple:
    """The two slider-end labels of one approval question, each defaulted.

    sort_order 0 = low / thumbs-down end, sort_order 1 = high / thumbs-up end
    (DBarchitecture.md → question_options). Mirrors approvalLabelsFrom() in
    lib/src/utils/approval_labels.dart, which defaults each end independently.
    """
    def one(key, fallback):
        raw = (q.get(key) or "").strip()
        return raw[:MAX_LABEL_CHARS] if raw else fallback

    return one("low_label", DEFAULT_LOW_LABEL), one("high_label", DEFAULT_HIGH_LABEL)


def validate(questions: list) -> None:
    if not isinstance(questions, list):
        fail("top-level JSON must be an array of question objects")
    n = len(questions)
    if n != EXPECTED_COUNT:
        warn(f"expected {EXPECTED_COUNT} questions, got {n} — continuing")

    counts = Counter()
    prompts_seen = set()
    for i, q in enumerate(questions):
        where = f"question #{i + 1}"
        if not isinstance(q, dict):
            fail(f"{where}: not an object")
        prompt = q.get("prompt")
        qtype = q.get("type")
        if not prompt or not isinstance(prompt, str) or not prompt.strip():
            fail(f"{where}: missing/empty prompt")
        if len(prompt) > MAX_PROMPT_CHARS:
            fail(f"{where}: prompt exceeds {MAX_PROMPT_CHARS} chars: {prompt[:60]}…")
        key = prompt.strip().lower()
        if key in prompts_seen:
            fail(f"{where}: duplicate prompt: {prompt[:60]}…")
        prompts_seen.add(key)

        if qtype not in ("multiple_choice", "approval_rating"):
            fail(f"{where}: type must be multiple_choice or approval_rating, got {qtype!r}")
        counts[qtype] += 1

        desc = q.get("description")
        if desc is not None:
            if not isinstance(desc, str):
                fail(f"{where}: description must be a string")
            if len(desc.split()) > MAX_DESCRIPTION_WORDS:
                fail(f"{where}: description exceeds {MAX_DESCRIPTION_WORDS} words")

        options = q.get("options")
        if qtype == "multiple_choice":
            if not isinstance(options, list) or not (
                MIN_OPTIONS <= len(options) <= MAX_OPTIONS
            ):
                fail(f"{where}: multiple_choice needs {MIN_OPTIONS}-{MAX_OPTIONS} options")
            texts = [o for o in options if isinstance(o, str) and o.strip()]
            if len(texts) != len(options):
                fail(f"{where}: every option must be a non-empty string")
            if len({o.strip().lower() for o in texts}) != len(texts):
                fail(f"{where}: duplicate options")
        elif options:
            fail(f"{where}: approval_rating must not have options")

        # Slider end labels: approval-only, optional, ≤ MAX_LABEL_CHARS.
        for key in ("low_label", "high_label"):
            label = q.get(key)
            if label is None:
                continue
            if qtype != "approval_rating":
                fail(f"{where}: {key} is only valid on approval_rating")
            if not isinstance(label, str) or not label.strip():
                fail(f"{where}: {key} must be a non-empty string")
            if len(label.strip()) > MAX_LABEL_CHARS:
                fail(
                    f"{where}: {key} exceeds {MAX_LABEL_CHARS} chars: "
                    f"{label.strip()!r}"
                )
        if qtype == "approval_rating":
            low, high = approval_labels(q)
            if low.lower() == high.lower():
                fail(f"{where}: low_label and high_label must differ")

    mc, ap = counts["multiple_choice"], counts["approval_rating"]
    print(f"Validated {n} questions: {mc} multiple_choice / {ap} approval_rating")
    if n and (min(mc, ap) / n) < (0.5 - SPLIT_TOLERANCE):
        warn(
            f"split is outside ~50/50 (±{int(SPLIT_TOLERANCE * 100)}%): "
            f"{mc} MC vs {ap} approval"
        )


def generate_sql(questions, country_code, author_id):
    author_sql = sql_str(author_id) + "::uuid" if author_id else "NULL"
    sentinel = questions[0]["prompt"].strip()

    out = [
        "-- Generated by scripts/seed_qotd_bank.py — initial QOTD bank seed",
        f"-- {len(questions)} questions; country_code={country_code}, "
        f"author_id={author_id or 'NULL (anonymous)'}",
        "-- Run once in the Supabase SQL editor. Re-running aborts on the",
        "-- sentinel guard below instead of double-seeding.",
        "-- Every question writes its question_options rows: one per choice for",
        "-- multiple_choice, and exactly two for approval_rating naming the",
        "-- slider ends (sort_order 0 = low, 1 = high).",
        "",
        "BEGIN;",
        "",
        "DO $$ BEGIN",
        "  IF EXISTS (SELECT 1 FROM questions WHERE is_seeded AND prompt = "
        + sql_str(sentinel)
        + ") THEN",
        "    RAISE EXCEPTION 'seed_qotd_bank: sentinel prompt already present "
        "— bank appears seeded; aborting';",
        "  END IF;",
        "END $$;",
        "",
    ]

    for q in questions:
        prompt = sql_str(q["prompt"].strip())
        desc = q.get("description")
        desc_sql = sql_str(desc.strip()) if desc and desc.strip() else "NULL"
        qtype = q["type"]

        if qtype == "multiple_choice":
            option_rows = ", ".join(
                f"({sql_str(opt.strip())}, {i})"
                for i, opt in enumerate(q["options"])
            )
            out.append(
                "WITH q AS (\n"
                "  INSERT INTO questions (prompt, description, type, country_code,\n"
                "    targeting_type, nsfw, is_hidden, is_private, author_id, is_seeded)\n"
                f"  VALUES ({prompt}, {desc_sql}, 'multiple_choice', "
                f"{sql_str(country_code)}, 'globe', false, false, false, {author_sql}, true)\n"
                "  RETURNING id\n"
                ")\n"
                "INSERT INTO question_options (question_id, option_text, sort_order)\n"
                f"SELECT q.id, o.option_text, o.sort_order\n"
                f"FROM q, (VALUES {option_rows}) AS o(option_text, sort_order);"
            )
        else:
            # Two rows naming the slider ends: 0 = low/thumbs-down,
            # 1 = high/thumbs-up. Same shape submitQuestion writes.
            low, high = approval_labels(q)
            option_rows = f"({sql_str(low)}, 0), ({sql_str(high)}, 1)"
            out.append(
                "WITH q AS (\n"
                "  INSERT INTO questions (prompt, description, type, country_code,\n"
                "    targeting_type, nsfw, is_hidden, is_private, author_id, is_seeded)\n"
                f"  VALUES ({prompt}, {desc_sql}, 'approval_rating', "
                f"{sql_str(country_code)}, 'globe', false, false, false, {author_sql}, true)\n"
                "  RETURNING id\n"
                ")\n"
                "INSERT INTO question_options (question_id, option_text, sort_order)\n"
                "SELECT q.id, o.option_text, o.sort_order\n"
                f"FROM q, (VALUES {option_rows}) AS o(option_text, sort_order);"
            )
        out.append("")

    out.append("COMMIT;")
    out.append("")
    return "\n".join(out)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", nargs="?", help="questions JSON file")
    parser.add_argument(
        "--print-brief",
        action="store_true",
        help="print the request text to paste into a Claude session, then exit",
    )
    parser.add_argument(
        "--country-code",
        default="US",
        help="countries.country_code FK value for every seeded question (default US)",
    )
    parser.add_argument(
        "--author-id",
        default=None,
        help="auth.users uuid to own the questions (default: NULL / anonymous)",
    )
    parser.add_argument(
        "--out",
        default="seed_questions.sql",
        help="output SQL path (default seed_questions.sql)",
    )
    args = parser.parse_args()

    if args.print_brief:
        print(BRIEF)
        return
    if not args.input:
        parser.error("provide a questions JSON file (or --print-brief)")

    try:
        with open(args.input, encoding="utf-8") as f:
            questions = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        fail(f"could not read {args.input}: {e}")

    validate(questions)
    sql = generate_sql(questions, args.country_code, args.author_id)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(sql)
    print(f"Wrote {args.out} — review it, then run it once in the Supabase SQL editor.")


if __name__ == "__main__":
    main()
