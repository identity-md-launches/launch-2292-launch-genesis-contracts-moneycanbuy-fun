#!/usr/bin/env python3
"""docs/LAUNCH-TASK.md against the code: every constructorArgs list that test/review/ReviewLaunch.t.sol holds against
LaunchPlan byte for byte (DOC* constants) must appear in the doc verbatim, and every launch text must fit the swarm's
8,000-character objective. Prints the fingerprints (sha256, first 16 hex, before the placeholders are filled) of each
launch text. Exit 1 on any mismatch. Foundry may not read files (no fs_permissions under the launch
rules), so this half of the check runs here."""
import hashlib, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOC = os.path.join(ROOT, "docs", "LAUNCH-TASK.md")
TEST = os.path.join(ROOT, "test", "review", "ReviewLaunch.t.sol")

doc = open(DOC, encoding="utf-8").read()
test = open(TEST, encoding="utf-8").read()
ok = True
consts = re.findall(r"string constant (DOC\w+) =\s*'([^']*)'", test)
consts += re.findall(r'string constant (DOC\w+) =\s*"([^"]*)"', test)
for name, value in consts:
    found = value in doc
    ok &= found
    print(f"{name:24} {'ok' if found else 'NOT IN THE DOC'}")

blocks = re.findall(r"## Launch (\d) text[^\n]*\n\n```\n(.*?)\n```", doc, re.S)
if len(blocks) != 4:
    print("expected 4 launch texts, found", len(blocks))
    ok = False
for n, text in blocks:
    fp = hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]
    fits = len(text) <= 8000
    ok &= fits
    print(f"launch {n}: {len(text)} chars, sha256 {fp}{'' if fits else '  OVER 8,000'}")
sys.exit(0 if ok else 1)
