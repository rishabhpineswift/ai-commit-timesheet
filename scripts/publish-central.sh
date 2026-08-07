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
QUALITY_RATING="${TIMESHEET_QUALITY_RATING:-Unrated}"
QUALITY_NOTES="${TIMESHEET_QUALITY_NOTES:-}"
DEV_SUMMARY="${TIMESHEET_DEV_SUMMARY:-}"

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

# A file created before developer_summary existed still has the old 11-column
# header even after new 12-column rows get appended to it — parseCsv in the
# portal maps values to headers positionally, so that mismatch silently
# shifts quality_rating/quality_notes/after_sha one column to the right for
# every row written after the column was added. Rewrite the header and
# backfill old rows with an empty developer_summary so old and new rows line
# up under the same 12-column schema.
migrate_summary_schema() {
  local file="$1"
  [ -f "$file" ] || return 0
  grep -q "developer_summary" <(head -1 "$file") && return 0

  local tmp
  tmp=$(mktemp)
  {
    IFS= read -r old_header
    echo "${old_header/summary,quality_rating/summary,developer_summary,quality_rating}"
    awk -F',' 'BEGIN{OFS=","} { if (NF==11) { for(i=NF;i>=9;i--) $(i+1)=$i; $9="\"\""; NF=12 }; print }'
  } < "$file" > "$tmp"
  mv "$tmp" "$file"
}

regenerate_contributor_summary() {
  local dir="$1" label="$2"
  local log="$dir/log.csv" summary="$dir/summary.md"
  local totals
  totals=$(awk -F',' 'NR>1 { for(i=1;i<=12;i++) gsub(/"/,"",$i); commits+=$4; files+=$5; ins+=$6; del+=$7; pushes++; if ($10=="Poor") poor++ } END { printf "%d,%d,%d,%d,%d,%d", pushes+0, commits+0, files+0, ins+0, del+0, poor+0 }' "$log")
  IFS=',' read -r pushes commits files ins del poor <<< "$totals"

  {
    echo "# ${label}"
    echo
    echo "**Totals:** ${commits} commits, ${files} files changed, +${ins}/-${del} lines, across ${pushes} pushes${poor:+, ${poor} flagged Poor quality}."
    echo
    echo "## Daily summaries"
    echo
    awk -F',' 'NR>1 { for(i=1;i<=12;i++) gsub(/"/,"",$i); printf "- **%s** (%s, %s) [%s]: %s\n", $1, $2, $3, $10, $8 }' "$log"
  } > "$summary"
}

# Appends a row to $1/log.csv (creating it with a header if needed) and
# regenerates $1/summary.md from the full file. Takes explicit commit/line
# counts rather than reusing the push-level totals — a contributor's row
# must reflect only the lines actually attributed to them (see the
# per-author breakdown built in generate-entry.sh), not the whole push.
append_and_summarize() {
  local dir="$1" label="$2" commits="$3" files="$4" ins="$5" del="$6"
  local log="${dir}/log.csv"
  mkdir -p "$dir"
  migrate_summary_schema "$log"
  if [ ! -f "$log" ]; then
    echo "timestamp,project,branch,commits,files_changed,insertions,deletions,summary,developer_summary,quality_rating,quality_notes,after_sha" > "$log"
  fi
  echo "\"${TIMESHEET_TIMESTAMP}\",\"${PROJECT_NAME}\",\"${TIMESHEET_BRANCH}\",${commits},${files},${ins},${del},\"${TIMESHEET_SUMMARY}\",\"${DEV_SUMMARY}\",\"${QUALITY_RATING}\",\"${QUALITY_NOTES}\",\"${TIMESHEET_AFTER_SHA}\"" >> "$log"
  regenerate_contributor_summary "$dir" "$label"
}

DAILY_FILE="projects/${PROJECT_NAME}/daily/${DATE_UTC}.csv"
mkdir -p "$(dirname "$DAILY_FILE")"
migrate_summary_schema "$DAILY_FILE"
if [ ! -f "$DAILY_FILE" ]; then
  echo "timestamp,branch,authors,commits,files_changed,insertions,deletions,summary,developer_summary,quality_rating,quality_notes,after_sha" > "$DAILY_FILE"
fi
echo "\"${TIMESHEET_TIMESTAMP}\",\"${TIMESHEET_BRANCH}\",\"${TIMESHEET_AUTHORS}\",${TIMESHEET_COMMITS},${TIMESHEET_FILES_CHANGED},${TIMESHEET_INSERTIONS},${TIMESHEET_DELETIONS},\"${TIMESHEET_SUMMARY}\",\"${DEV_SUMMARY}\",\"${QUALITY_RATING}\",\"${QUALITY_NOTES}\",\"${TIMESHEET_AFTER_SHA}\"" >> "$DAILY_FILE"

# TIMESHEET_AUTHOR_BREAKDOWN is tab-separated per line: author, commits,
# files, insertions, deletions — already limited to non-merge commits, each
# credited to its own real author (see generate-entry.sh). A push where
# someone only merged/fast-forwarded another person's branch produces no
# line here for the merger; the original author's commits are attributed to
# them directly.
while IFS=$'\t' read -r author commits files ins del; do
  [ -z "$author" ] && continue
  SLUG=$(slugify "$author")

  # contributors/<slug>/<year>/<month>/ — this person's pushes across all projects.
  # (Their per-project activity is just this same data filtered by project — no
  # need for a separate projects/<project>/contributors/<slug>/... tree.)
  append_and_summarize \
    "contributors/${SLUG}/${YEAR_UTC}/${MONTH_UTC}" \
    "${SLUG} — ${YEAR_UTC}-${MONTH_UTC}" \
    "$commits" "$files" "$ins" "$del"
done <<< "${TIMESHEET_AUTHOR_BREAKDOWN:-}"

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
