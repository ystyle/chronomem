#!/bin/bash
# Fail if a credential-shaped literal is about to be committed.
#
# Written after an API key sat in `airamcp.sh` as an inline fallback and reached
# three remotes — one of them public — before anyone looked. The script is the
# cheap half of the fix: the expensive half is rotating a key that is already
# public.
#
# Usage: bench/check_secrets.sh [rev]     (default: staged changes)
set -uo pipefail

REV="${1:-}"
if [ -z "$REV" ]; then
  FILES=$(git diff --cached --name-only --diff-filter=ACM)
  SHOW="git diff --cached -U0 --"
else
  FILES=$(git ls-tree -r --name-only "$REV")
  SHOW="git show $REV --"
fi

PATTERN='(sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----)'
FOUND=0

for f in $FILES; do
  case "$f" in
    *.png|*.jpg|*.pdf|*.gguf|*.bin) continue ;;   # binaries, not scanned
  esac
  if [ -n "$REV" ]; then
    hits=$(git show "$REV:$f" 2>/dev/null | grep -nE "$PATTERN" || true)
  else
    hits=$(git diff --cached -U0 -- "$f" | grep -E '^\+' | grep -nE "$PATTERN" || true)
  fi
  if [ -n "$hits" ]; then
    echo "SECRET in $f:" >&2
    echo "$hits" | sed -E 's/(sk-|gh[pousr]_|AKIA)[A-Za-z0-9_-]{6,}/\1<redacted>/g' >&2
    FOUND=1
  fi
done

if [ "$FOUND" -eq 1 ]; then
  echo "" >&2
  echo "Refusing: move the credential to the environment. If it was already" >&2
  echo "committed, rotating it is the only real remediation." >&2
  exit 1
fi
echo "no credential-shaped literals found"
