#!/usr/bin/env bash
# Council pre-push content gates — sovereign-wiki static site.
# Real checks for a Layer 0 static property: structure, machine endpoints,
# link integrity, and a secret-leak scan. Fail closed.
set -uo pipefail
FAIL=0
say() { echo "[gate] $*"; }
bad() { echo "[gate][FAIL] $*"; FAIL=1; }

task_repo_root="$(git rev-parse --show-toplevel)" || exit 1
cd "$task_repo_root" || exit 1

# 1. Required Layer 0 files exist and are non-trivial
for f in index.html llms.txt robots.txt sitemap.xml .well-known/agent-card.json; do
  [ -s "$f" ] && say "present: $f" || bad "missing or empty: $f"
done

# 2. index.html has a real title and canonical
grep -q "<title>sovereign.wiki" index.html && say "title ok" || bad "index.html title missing/incorrect"
grep -q 'rel="canonical"' index.html && say "canonical ok" || bad "index.html canonical missing"

# 3. agent-card.json parses as JSON
python3 -c "import json; c=json.load(open('.well-known/agent-card.json')); assert c.get('name')=='sovereign-wiki' and c.get('layer0') is True, 'bad card'" \
  && say "agent-card ok" || bad "agent-card.json invalid"

# 4. sitemap parses and points at this host
python3 -c "import xml.etree.ElementTree as ET; t=ET.parse('sitemap.xml'); locs=[e.text for e in t.iter() if e.tag.endswith('loc')]; assert locs and all(l.startswith('https://csoai-org.github.io/sovereign-wiki/') for l in locs), 'bad sitemap'" \
  && say "sitemap ok" || bad "sitemap.xml invalid"

# 5. robots references the sitemap
grep -q "Sitemap: https://csoai-org.github.io/sovereign-wiki/sitemap.xml" robots.txt && say "robots ok" || bad "robots.txt sitemap ref missing"

# 6. Check every published content page and discovery file. Never echo matched values.
# A grep | head pipeline can report a false clean result after grep receives SIGPIPE.
if python3 - <<'SCAN'
from pathlib import Path
import re, sys
roots = [Path(p) for p in ('index.html', 'llms.txt', 'robots.txt', 'sitemap.xml', '.well-known', 'crown-jewels', 'x402')]
pattern = re.compile(r'(gho_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN (RSA|OPENSSH|EC) PRIVATE KEY)')
failed = False
for root in roots:
    if not root.exists():
        print(f'[scan] missing required content path: {root}')
        failed = True
        continue
    for path in sorted(root.rglob('*')) if root.is_dir() else [root]:
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding='utf-8')
        except (OSError, UnicodeError):
            print(f'[scan] could not inspect: {path}')
            failed = True
            continue
        if pattern.search(text):
            print(f'[scan] possible secret marker in: {path}')
            failed = True
sys.exit(1 if failed else 0)
SCAN
then
  say "secret-scan clean (published content paths)"
else
  bad "published content secret scan failed; matched values withheld"
fi

# 7. External ecosystem links present (one-door consistency)
for u in csoai.org councilof.ai meok.ai proofof.ai; do
  grep -q "$u" index.html && grep -q "$u" llms.txt || bad "ecosystem link missing from index/llms: $u"
done
say "ecosystem links ok"

if [ "$FAIL" -eq 0 ]; then
  echo "[gate] ALL GATES PASSED — sovereign-wiki static Layer 0 suite"
  exit 0
fi
echo "[gate] FAILED — push blocked"
exit 1

