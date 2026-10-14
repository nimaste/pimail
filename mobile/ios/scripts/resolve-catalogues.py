#!/usr/bin/env python3
"""Resolve additive .strings conflicts, then prove the result actually parses.

Line counts are not evidence: a conflict marker left in a .strings file is not
a syntax error, so the table simply truncates at that point and every key after
it silently falls back to English. Only the parsed key count shows that.
"""
import json, pathlib, re, subprocess, sys

pattern = re.compile(
    r"<<<<<<< [^\n]*\n(?P<ours>.*?)^=======\n(?P<theirs>.*?)^>>>>>>> [^\n]*\n",
    re.S | re.M)

for rel in subprocess.run(["git", "diff", "--name-only", "--diff-filter=U"],
                          capture_output=True, text=True).stdout.split():
    if not rel.endswith(".strings"):
        print(f"!! {rel} is not a catalogue — resolve by hand"); continue
    p = pathlib.Path(rel)
    s = pattern.sub(lambda m: m.group("ours") + m.group("theirs"), p.read_text())
    seen, out = set(), []
    for line in s.splitlines(True):
        if line.startswith('"'):
            key = line.split('" = "')[0]
            if key in seen:
                continue
            seen.add(key)
        out.append(line)
    p.write_text("".join(out))

ok = True
for mod in ["PLMailCore", "PLMailUI"]:
    tables = {}
    for lang in ["en", "de"]:
        f = f"Packages/PLMail/Sources/{mod}/Resources/{lang}.lproj/Localizable.strings"
        r = subprocess.run(["plutil", "-convert", "json", "-o", "-", f],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(f"!! {mod}/{lang} does not parse"); ok = False; continue
        tables[lang] = set(json.loads(r.stdout))
    if len(tables) == 2:
        drift = tables["en"] ^ tables["de"]
        print(f"{mod}: en={len(tables['en'])} de={len(tables['de'])} drift={sorted(drift)[:4]}")
        ok = ok and not drift

sys.exit(0 if ok else 1)
