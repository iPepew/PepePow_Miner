#!/usr/bin/env python3
from pathlib import Path

path = Path(__file__).with_name("prepare-v053-source.py")
text = path.read_text(encoding="utf-8")
old = "    return positive_fraction(value / 1024.0);"
new = "    return positive_fraction_bits(value / 1024.0);"
if old in text:
    text = text.replace(old, new, 1)
elif new not in text:
    raise SystemExit("Cannot patch v0.5.3 scaled-fraction fallback")
path.write_text(text, encoding="utf-8")
print("PASS: v0.5.3 generator helper ordering fixed")
