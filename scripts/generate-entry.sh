#!/usr/bin/env bash
set -euo pipefail

# Inputs (env vars set by action.yml)
: "${TIMESHEET_PATH:=timesheet.csv}"
: "${MAX_DIFF_CHARS:=8000}"
: "${BEFORE_SHA:?BEFORE_SHA is required}"
: "${AFTER_SHA:?AFTER_SHA is required}"
: "${BRANCH_NAME:?BRANCH_NAME is required}"

EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"
ZERO_SHA="0000000000000000000000000000000000000000"

if [ "$AFTER_SHA" = "$ZERO_SHA" ]; then
  echo "Branch/tag deleted, nothing to record." >&2
  exit 0
fi

if [ "$BEFORE_SHA" = "$ZERO_SHA" ] || ! git cat-file -e "$BEFORE_SHA" 2>/dev/null; then
  # New branch, or before-sha not reachable (shallow history) — diff against empty tree
  # and only summarize the tip commit's own message range.
  BASE_SHA="$EMPTY_TREE"
  LOG_RANGE="$AFTER_SHA"
  LOG_RANGE_LIMIT="-n 20"
else
  BASE_SHA="$BEFORE_SHA"
  LOG_RANGE="${BEFORE_SHA}..${AFTER_SHA}"
  LOG_RANGE_LIMIT=""
fi

COMMIT_COUNT=$(git log $LOG_RANGE_LIMIT --pretty=format:'%H' $LOG_RANGE | wc -l | tr -d ' ')
if [ "$COMMIT_COUNT" = "0" ]; then
  echo "No new commits in range, nothing to record." >&2
  exit 0
fi

AUTHORS=$(git log $LOG_RANGE_LIMIT --pretty=format:'%an' $LOG_RANGE | sort -u | paste -sd ';' -)
COMMIT_MESSAGES=$(git log $LOG_RANGE_LIMIT --pretty=format:'- %s' $LOG_RANGE)
TIMESTAMP=$(git log -1 --pretty=format:'%aI' "$AFTER_SHA")

SHORTSTAT=$(git diff --shortstat "$BASE_SHA" "$AFTER_SHA")
FILES_CHANGED=$(echo "$SHORTSTAT" | grep -oE '[0-9]+ file' | grep -oE '[0-9]+' || echo 0)
INSERTIONS=$(echo "$SHORTSTAT" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)
DELETIONS=$(echo "$SHORTSTAT" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo 0)
FILES_CHANGED=${FILES_CHANGED:-0}
INSERTIONS=${INSERTIONS:-0}
DELETIONS=${DELETIONS:-0}

DIFF_TEXT=$(git diff "$BASE_SHA" "$AFTER_SHA" -- . \
  ':(exclude)*.lock' ':(exclude)package-lock.json' ':(exclude)pnpm-lock.yaml' ':(exclude)yarn.lock' \
  | head -c "$MAX_DIFF_CHARS")

PROMPT=$(cat <<EOF
You are summarizing a git push for a team timesheet log. Read the commit
messages and diff below and reply with ONE short sentence (max ~20 words)
describing what changed, in plain language a non-engineer manager could
understand. Do not use any tools. Do not add preamble, quotes, or a trailing
period-separated list — just the sentence.

Commit messages:
${COMMIT_MESSAGES}

Diff (may be truncated):
${DIFF_TEXT}
EOF
)

if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  SUMMARY=$(claude -p "$PROMPT" --output-format text 2>/dev/null || echo "")
fi
if [ -z "${SUMMARY:-}" ]; then
  SUMMARY=$(echo "$COMMIT_MESSAGES" | head -1 | sed 's/^- //')
fi

SUMMARY=$(echo "$SUMMARY" | tr '\n' ' ' | tr ',' ';' | sed 's/"/'"'"'/g' | xargs)

mkdir -p "$(dirname "$TIMESHEET_PATH")" 2>/dev/null || true
if [ ! -f "$TIMESHEET_PATH" ]; then
  echo "timestamp,branch,authors,commits,files_changed,insertions,deletions,summary,after_sha" > "$TIMESHEET_PATH"
fi

echo "\"${TIMESTAMP}\",\"${BRANCH_NAME}\",\"${AUTHORS}\",${COMMIT_COUNT},${FILES_CHANGED},${INSERTIONS},${DELETIONS},\"${SUMMARY}\",\"${AFTER_SHA}\"" >> "$TIMESHEET_PATH"

echo "Recorded timesheet entry for ${AFTER_SHA} on ${BRANCH_NAME}"
