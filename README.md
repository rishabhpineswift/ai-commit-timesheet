# ai-commit-timesheet

A reusable GitHub Action that logs one row per push to a `timesheet.csv` file
in your repo: **who** pushed, **when**, **how many lines changed**, and a
one-line **AI code-review summary** of what the push actually does. Claude
reads the real diff itself (via `git diff`/`git show`/`Read`/`Grep`, not a
truncated text blob pasted into the prompt) and reports what changed and why
— like a quick code review, not a paraphrase of the commit message. Drop it
into any repo's workflow — no copy-pasted scripts, no shared server.

It works with a **Claude subscription seat** (Pro/Max/Team) instead of an
Anthropic API key, via `claude setup-token`.

## What it logs

| column | example |
|---|---|
| timestamp | 2026-08-06T14:02:11+05:30 |
| branch | main |
| authors | Rishabh Singh |
| commits | 3 |
| files_changed | 5 |
| insertions | 120 |
| deletions | 34 |
| summary | Added CSV export to the reports page |
| developer_summary | Add CSV export button to reports page |
| quality_rating | Good / Fair / Poor / Unrated |
| quality_notes | Missing error handling on the new API call |
| after_sha | a1b2c3d... |

`developer_summary` is the commit's own heading + description, verbatim from
the developer — separate from `summary`, which is Claude's independent read
of the actual diff. Comparing the two shows whether what a developer said
they did matches what really changed.

`quality_rating`/`quality_notes` come from the same AI review pass — it
judges the diff for obvious bugs, missing error handling, missing tests on
risky logic, security issues, and code smells (not style preference).
"Unrated" means the review step was skipped (no `claude-oauth-token`) or
failed for that push.

Note on "lines changed": since a lot of this code is AI-assisted, raw LOC is
a weak productivity signal on its own. This action only *collects* the
number — how (or whether) you factor it into any time/effort calculation is
a separate conversation for your team.

## Setup (per repo that wants this)

### 1. Get a Claude Code OAuth token (once per person adding this, or once for a shared bot account)

On a machine where you're logged into Claude Code with your Team seat:

```bash
claude setup-token
```

This prints a long-lived token tied to your subscription (not an API key —
no per-token API billing).

### 2. Add it as a repo secret

In the consuming repo: **Settings → Secrets and variables → Actions → New
repository secret**

- Name: `CLAUDE_CODE_OAUTH_TOKEN`
- Value: the token from step 1

### 3. Give the workflow push permission

Settings → Actions → General → Workflow permissions → **Read and write
permissions**. (Or set `permissions: contents: write` in the workflow below.)

### 4. Add the workflow file

Create `.github/workflows/timesheet.yml` in the consuming repo:

```yaml
name: Timesheet
on:
  push:
    branches: ["**"]

permissions:
  contents: write

jobs:
  log-timesheet:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: rishabhpineswift/ai-commit-timesheet@main
        with:
          claude-oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

That's it. Every push (any branch) is now reviewed and logged. Nothing is
committed back into this repo by default — point `central-repo` (below) at
a shared data repo instead of cluttering every consuming repo with its own
`timesheet.csv`. (Set `commit-and-push: true` if you actually want that
local file — see Inputs below.)

## Central timesheet-data repo (optional)

If you have multiple project repos and want one place with a daily sheet
per project and a monthly rollup per contributor, point this action at a
central repo (see [rishabhpineswift/timesheet-data](https://github.com/rishabhpineswift/timesheet-data)
for the folder structure it writes).

The default `GITHUB_TOKEN` can't write to a *different* repo, so this needs
its own token:

1. Create a [fine-grained PAT](https://github.com/settings/personal-access-tokens/new)
   scoped to just the central repo, with **Contents: Read and write** permission.
2. Add it as a secret in *this* (project) repo — e.g. `TIMESHEET_REPO_TOKEN`.
3. Pass it to the action:

```yaml
      - uses: rishabhpineswift/ai-commit-timesheet@main
        with:
          claude-oauth-token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
          central-repo: rishabhpineswift/timesheet-data
          central-repo-token: ${{ secrets.TIMESHEET_REPO_TOKEN }}
          # project-name: my-custom-name   # defaults to this repo's name
```

Every project repo that wants to report into the same central repo needs
its own copy of that PAT added as a secret (PATs aren't shared across repos).

## Inputs

| input | default | description |
|---|---|---|
| `claude-oauth-token` | *(none)* | Token from `claude setup-token`. If omitted, the raw commit message is used as the summary instead of an AI-generated one. |
| `timesheet-path` | `timesheet.csv` | Where to write/append the log, relative to repo root. Only matters if `commit-and-push` is `true`. |
| `commit-and-push` | `false` | Commit a per-repo `timesheet.csv` back to this repo. Off by default — redundant clutter once `central-repo` is set. |
| `git-user-name` / `git-user-email` | bot defaults | Identity used for the automated commit. |
| `central-repo` | *(none)* | `owner/repo` of a central timesheet-data repo to also publish into. Leave unset to skip. |
| `central-repo-token` | *(none)* | Fine-grained PAT with `contents: write` on `central-repo`. Required if `central-repo` is set. |
| `project-name` | this repo's name | Folder key used under `projects/` in the central repo. |

## Limitations / notes

- New-branch pushes (no prior `before` SHA) diff against an empty tree and
  only look at the last 20 commits on that branch — first push of a new
  branch may show a larger-than-expected line count.
- Force-pushes and rebases can produce a `before` SHA no longer reachable in
  history; the script falls back to the same empty-tree diff in that case.
- This action commits directly to whatever branch was pushed. If your repo
  has branch protection requiring PRs, either exclude protected branches
  from the `on.push.branches` filter or set `commit-and-push: false` and
  wire up your own delivery (e.g. upload as a workflow artifact instead).
- Contributor-log attribution (in `timesheet-data`) credits lines to whoever
  actually authored the commit, not whoever merged/pulled it in — merge
  commits are skipped entirely for this purpose, since their own diff would
  otherwise include the incoming branch's changes too. Squash-merges are
  attributed to whoever the squash commit's author field says (GitHub's
  squash-merge button preserves the original PR author by default).
