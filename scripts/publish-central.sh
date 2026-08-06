#!/usr/bin/env bash
set -euo pipefail

: "${CENTRAL_REPO:?CENTRAL_REPO is required (owner/repo)}"
: "${CENTRAL_REPO_TOKEN:?CENTRAL_REPO_TOKEN is required}"
: "${PROJECT_NAME:?PROJECT_NAME is required}"

if [ "${TIMESHEET_RECORDED:-}" != "true" ]; then
  echo "No timesheet entry was recorded this run, skipping central publish." >&2
  exit 0
fi

: "${TIMESHEET_TIMESTAMP:?}"
: "${TIMESHEET_BRANCH:?}"
: "${TIMESHEET_AUTHORS:?}"
: "${TIMESHEET_COMMITS:?}"
: "${TIMESHEET_FILES_CHANGED:?}"
: "${TIMESHEET_INSERTIONS:?}"
: "${TIMESHEET_DELETIONS:?}"
: "${TIMESHEET_SUMMARY:?}"
: "${TIMESHEET_AFTER_SHA:?}"

DATE_UTC=$(date -u -d "$TIMESHEET_TIMESTAMP" +%Y-%m-%d)
YEAR_UTC=$(date -u -d "$TIMESHEET_TIMESTAMP" +%Y)
MONTH_UTC=$(date -u -d "$TIMESHEET_TIMESTAMP" +%m)

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

git clone -q --depth 1 "https://x-access-token:${CENTRAL_REPO_TOKEN}@github.com/${CENTRAL_REPO}.git" "$WORKDIR"
cd "$WORKDIR"
git config user.name "ai-commit-timesheet-bot"
git config user.email "ai-commit-timesheet-bot@users.noreply.github.com"

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

regenerate_contributor_summary() {
  local dir="$1" label="$2"
  local log="$dir/log.csv" summary="$dir/summary.md"
  local totals
  totals=$(awk -F',' 'NR>1 { for(i=1;i<=9;i++) gsub(/"/,"",$i); commits+=$4; files+=$5; ins+=$6; del+=$7; pushes++ } END { printf "%d,%d,%d,%d,%d", pushes+0, commits+0, files+0, ins+0, del+0 }' "$log")
  IFS=',' read -r pushes commits files ins del <<< "$totals"

  {
    echo "# ${label}"
    echo
    echo "**Totals:** ${commits} commits, ${files} files changed, +${ins}/-${del} lines, across ${pushes} pushes."
    echo
    echo "## Daily summaries"
    echo
    awk -F',' 'NR>1 { for(i=1;i<=9;i++) gsub(/"/,"",$i); printf "- **%s** (%s, %s): %s\n", $1, $2, $3, $8 }' "$log"
  } > "$summary"
}

# Appends a row to $1/log.csv (creating it with a header if needed) and
# regenerates $1/summary.md from the full file.
append_and_summarize() {
  local dir="$1" label="$2"
  local log="${dir}/log.csv"
  mkdir -p "$dir"
  if [ ! -f "$log" ]; then
    echo "timestamp,project,branch,commits,files_changed,insertions,deletions,summary,after_sha" > "$log"
  fi
  echo "\"${TIMESHEET_TIMESTAMP}\",\"${PROJECT_NAME}\",\"${TIMESHEET_BRANCH}\",${TIMESHEET_COMMITS},${TIMESHEET_FILES_CHANGED},${TIMESHEET_INSERTIONS},${TIMESHEET_DELETIONS},\"${TIMESHEET_SUMMARY}\",\"${TIMESHEET_AFTER_SHA}\"" >> "$log"
  regenerate_contributor_summary "$dir" "$label"
}

DAILY_FILE="projects/${PROJECT_NAME}/daily/${DATE_UTC}.csv"
mkdir -p "$(dirname "$DAILY_FILE")"
if [ ! -f "$DAILY_FILE" ]; then
  echo "timestamp,branch,authors,commits,files_changed,insertions,deletions,summary,after_sha" > "$DAILY_FILE"
fi
echo "\"${TIMESHEET_TIMESTAMP}\",\"${TIMESHEET_BRANCH}\",\"${TIMESHEET_AUTHORS}\",${TIMESHEET_COMMITS},${TIMESHEET_FILES_CHANGED},${TIMESHEET_INSERTIONS},${TIMESHEET_DELETIONS},\"${TIMESHEET_SUMMARY}\",\"${TIMESHEET_AFTER_SHA}\"" >> "$DAILY_FILE"

IFS=';' read -ra AUTHOR_LIST <<< "$TIMESHEET_AUTHORS"
for author in "${AUTHOR_LIST[@]}"; do
  author=$(echo "$author" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ -z "$author" ] && continue
  SLUG=$(slugify "$author")

  # contributors/<slug>/<year>/<month>/ — this person's pushes across all projects.
  # (Their per-project activity is just this same data filtered by project — no
  # need for a separate projects/<project>/contributors/<slug>/... tree.)
  append_and_summarize \
    "contributors/${SLUG}/${YEAR_UTC}/${MONTH_UTC}" \
    "${SLUG} — ${YEAR_UTC}-${MONTH_UTC}"
done

git add -A

if git diff --cached --quiet; then
  echo "No changes to publish to central repo."
  exit 0
fi

git commit -q -m "Log ${PROJECT_NAME}@${TIMESHEET_AFTER_SHA:0:7} (${TIMESHEET_BRANCH})"

for attempt in 1 2 3; do
  if git push -q origin HEAD:main 2>/dev/null; then
    echo "Published timesheet entry to ${CENTRAL_REPO}"
    exit 0
  fi
  echo "Push attempt ${attempt} failed, retrying..." >&2
  git pull -q --rebase origin main
done

echo "Failed to push to ${CENTRAL_REPO} after 3 attempts" >&2
exit 1
