#!/usr/bin/env bash
set -euo pipefail

# Inputs (env vars set by action.yml)
: "${TIMESHEET_PATH:=timesheet.csv}"
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
  # New branch, or before-sha not reachable (shallow history) — we don't know
  # what's "new" on this branch vs. shared history, so look at only the last
  # 20 commits reachable from the tip and diff against their oldest parent
  # (NOT an empty tree — that would diff the entire repo on a branch cut from
  # an existing large history).
  LOG_RANGE="$AFTER_SHA"
  LOG_RANGE_LIMIT="-n 20"
  COMMIT_COUNT=$(git rev-list $LOG_RANGE_LIMIT --count $LOG_RANGE)
  BASE_SHA=$(git rev-parse "${AFTER_SHA}~${COMMIT_COUNT}" 2>/dev/null || echo "$EMPTY_TREE")
else
  BASE_SHA="$BEFORE_SHA"
  LOG_RANGE="${BEFORE_SHA}..${AFTER_SHA}"
  LOG_RANGE_LIMIT=""
  COMMIT_COUNT=$(git rev-list --count $LOG_RANGE)
fi

if [ "$COMMIT_COUNT" = "0" ]; then
  echo "No new commits in range, nothing to record." >&2
  exit 0
fi

AUTHORS=$(git log $LOG_RANGE_LIMIT --pretty=format:'%an' $LOG_RANGE | tr ',' ' ' | { grep -viE '^(ai-commit-timesheet-bot|github-actions(\[bot\])?|.*\[bot\])$' || true; } | sort -u | paste -sd ';' -)
COMMIT_MESSAGES=$(git log $LOG_RANGE_LIMIT --pretty=format:'- %s' $LOG_RANGE)
TIMESTAMP=$(git log -1 --pretty=format:'%aI' "$AFTER_SHA")

SHORTSTAT=$(git diff --shortstat "$BASE_SHA" "$AFTER_SHA")
FILES_CHANGED=$(echo "$SHORTSTAT" | grep -oE '[0-9]+ file' | grep -oE '[0-9]+' || echo 0)
INSERTIONS=$(echo "$SHORTSTAT" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)
DELETIONS=$(echo "$SHORTSTAT" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo 0)
FILES_CHANGED=${FILES_CHANGED:-0}
INSERTIONS=${INSERTIONS:-0}
DELETIONS=${DELETIONS:-0}

PROMPT=$(cat <<EOF
You are doing a quick code review of a git push for a team timesheet log.

Base commit:  ${BASE_SHA}
Head commit:  ${AFTER_SHA}
You are in the repo working directory (already checked out at the head
commit). Run \`git diff ${BASE_SHA} ${AFTER_SHA}\` yourself (and \`git show\`,
\`git log\`, \`Read\`, \`Grep\`, \`Glob\` as needed) to actually look at what
changed and understand it in context — don't just paraphrase the commit
messages below.

Commit messages (for context, not to be taken at face value):
${COMMIT_MESSAGES}

Output EXACTLY two lines, nothing else — no preamble, no markdown, no
quotes:

Line 1 — under 40 words, for a non-engineer manager reading a timesheet:
start with a category tag (Feature:/Fix:/Refactor:/Chore:/Docs:/Test:), then
a plain-language sentence describing what the code actually does now and
why, based on your own reading of the diff — not the commit message. If the
diff looks risky, incomplete, or inconsistent with the commit message, say
so briefly instead of just describing intent.

Line 2 — a code-quality verdict on this push, from your own reading of the
diff: start with exactly "Quality: Good", "Quality: Fair", or "Quality: Poor",
then " — " and a short reason. Judge on correctness, obvious bugs, missing
error handling, missing tests for risky logic, security issues, and code
smells — not on style preference. Use Good when you see nothing concerning,
Fair for minor concerns worth a second look, Poor for real bugs/security
issues/risky untested logic. If nothing meaningful changed (e.g. a version
bump, generated file, config-only change), say "Quality: Good — no
functional code to assess."
EOF
)

RAW_OUTPUT=""
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  RAW_OUTPUT=$(claude -p "$PROMPT" --output-format text \
    --allowedTools "Bash(git diff:*)" "Bash(git show:*)" "Bash(git log:*)" "Read" "Grep" "Glob" \
    2>/dev/null || echo "")
fi

SUMMARY=$(echo "$RAW_OUTPUT" | sed -n '1p')
QUALITY=$(echo "$RAW_OUTPUT" | sed -n '2p')

if [ -z "${SUMMARY:-}" ]; then
  SUMMARY=$(echo "$COMMIT_MESSAGES" | head -1 | sed 's/^- //')
fi
if [ -z "${QUALITY:-}" ]; then
  QUALITY="Quality: Unrated — AI review unavailable for this push."
fi

SUMMARY=$(echo "$SUMMARY" | tr '\n' ' ' | tr ',' ';' | sed -e 's/"/'"'"'/g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
QUALITY=$(echo "$QUALITY" | tr '\n' ' ' | tr ',' ';' | sed -e 's/"/'"'"'/g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
QUALITY_RATING=$(echo "$QUALITY" | grep -oE '^Quality: [A-Za-z]+' | sed 's/^Quality: //' || echo "Unrated")
QUALITY_NOTES=$(echo "$QUALITY" | sed -E 's/^Quality: [A-Za-z]+ ?—? ?//')

mkdir -p "$(dirname "$TIMESHEET_PATH")" 2>/dev/null || true
if [ ! -f "$TIMESHEET_PATH" ]; then
  echo "timestamp,branch,authors,commits,files_changed,insertions,deletions,summary,quality_rating,quality_notes,after_sha" > "$TIMESHEET_PATH"
fi

echo "\"${TIMESTAMP}\",\"${BRANCH_NAME}\",\"${AUTHORS}\",${COMMIT_COUNT},${FILES_CHANGED},${INSERTIONS},${DELETIONS},\"${SUMMARY}\",\"${QUALITY_RATING}\",\"${QUALITY_NOTES}\",\"${AFTER_SHA}\"" >> "$TIMESHEET_PATH"

echo "Recorded timesheet entry for ${AFTER_SHA} on ${BRANCH_NAME}"

# Hand the computed entry to later composite steps (e.g. publish-central.sh)
if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "TIMESHEET_RECORDED=true"
    echo "TIMESHEET_TIMESTAMP=${TIMESTAMP}"
    echo "TIMESHEET_BRANCH=${BRANCH_NAME}"
    echo "TIMESHEET_AUTHORS=${AUTHORS}"
    echo "TIMESHEET_COMMITS=${COMMIT_COUNT}"
    echo "TIMESHEET_FILES_CHANGED=${FILES_CHANGED}"
    echo "TIMESHEET_INSERTIONS=${INSERTIONS}"
    echo "TIMESHEET_DELETIONS=${DELETIONS}"
    echo "TIMESHEET_SUMMARY=${SUMMARY}"
    echo "TIMESHEET_QUALITY_RATING=${QUALITY_RATING}"
    echo "TIMESHEET_QUALITY_NOTES=${QUALITY_NOTES}"
    echo "TIMESHEET_AFTER_SHA=${AFTER_SHA}"
  } >> "$GITHUB_ENV"
fi
