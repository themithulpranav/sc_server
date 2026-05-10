import json
import re
import sys

import pdfplumber


CONTROL_KEYWORDS = [
    "must",
    "shall",
    "required",
    "enforced",
    "reviewed",
    "monitored",
    "authenticated",
    "authorized",
    "encrypted",
    "restricted",
    "verified",
    "logged",
    "approved",
    "protected",
    "configured"
]


def normalize(text):
    return re.sub(r"\s+", " ", text).strip()


def score_control_candidate(text):
    lower = text.lower()

    return sum(
        1 for keyword in CONTROL_KEYWORDS
        if keyword in lower
    )


def classify_block(line):
    if re.match(r"^[A-Z][A-Z0-9\\s\\-]{3,}$", line):
        return "heading"

    return "paragraph"


pdf_path = sys.argv[1]

blocks = []

with pdfplumber.open(pdf_path) as pdf:
    for page_number, page in enumerate(pdf.pages, start=1):
        text = page.extract_text(x_tolerance=2)

        if not text:
            continue

        lines = text.split("\\n")

        current_section = []

        for line in lines:
            line = normalize(line)

            if len(line) < 20:
                continue

            block_type = classify_block(line)

            if block_type == "heading":
                current_section = [line]

            blocks.append({
                "page": page_number,
                "type": block_type,
                "section": current_section,
                "text": line,
                "control_candidate_score": score_control_candidate(line)
            })

print(json.dumps(blocks))