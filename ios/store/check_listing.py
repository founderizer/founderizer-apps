#!/usr/bin/env python3
"""Counts each field of listing.md against Apple's limit, which its heading names: "## Subtitle (30)".

    python3 -B app/ios/store/check_listing.py
"""
import os
import re
import sys

LISTING = os.path.join(os.path.dirname(os.path.abspath(__file__)), "listing.md")


def fields(text):
    """Each "## <name> (<limit>)" heading with the words under it, up to the next heading."""
    parts = re.split(r"^## ", text, flags=re.M)[1:]
    for part in parts:
        head, _, body = part.partition("\n")
        limit = re.fullmatch(r"(.+?) \((\d+)\)", head.strip())
        if limit:
            yield limit.group(1), int(limit.group(2)), body.strip()


def main():
    over = 0
    for name, limit, words in fields(open(LISTING).read()):
        if name == "Keywords" and ", " in words:
            print(f"{name}: a space after a comma counts against the limit")
            over += 1
        flat = words if name == "Description" else " ".join(words.split())
        mark = "ok" if len(flat) <= limit else "OVER"
        over += mark == "OVER"
        print(f"{name}: {len(flat)} of {limit} {mark}")
    return 1 if over else 0


if __name__ == "__main__":
    sys.exit(main())
