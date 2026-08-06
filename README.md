# ai-commit-timesheet

A reusable GitHub Action that logs one row per push to a `timesheet.csv` file
in your repo: **who** pushed, **when**, **how many lines changed**, and a
one-sentence **AI-generated summary** of what the push did. Drop it into any
repo's workflow — no copy-pasted scripts, no shared server.

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
| after_sha | a1b2c3d... |

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

That's it. Every push (any branch) appends a row to `timesheet.csv` and
commits it back with `[skip ci]` so it doesn't re-trigger the workflow.

## Inputs

| input | default | description |
|---|---|---|
| `claude-oauth-token` | *(none)* | Token from `claude setup-token`. If omitted, the raw commit message is used as the summary instead of an AI-generated one. |
| `timesheet-path` | `timesheet.csv` | Where to write/append the log, relative to repo root. |
| `max-diff-chars` | `8000` | How much of the diff to send to Claude for summarization. |
| `commit-and-push` | `true` | Set `false` if you'd rather handle committing the file yourself (e.g. as part of a larger job). |
| `git-user-name` / `git-user-email` | bot defaults | Identity used for the automated commit. |

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
