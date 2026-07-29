# code-ranker-ci

Reusable GitHub Actions workflow for **code-ranker Reports**. Drop in one file, get an HTML report generated on your CI and posted as a PR comment by the code-ranker GitHub App — no secrets, no OIDC, and by default only `contents: read`.

Part of the [code-ranker](https://github.com/code-ranker-com/code-ranker) Reports product.

## License

Proprietary. This repository may only be used to integrate your repositories with the code-ranker service. All other uses are prohibited. See [LICENSE](LICENSE) for details.

## How it works

On every pull request (and every push) the workflow:

1. Installs `code-ranker` (precompiled binary, seconds)
2. Builds a self-contained HTML report for your code, plus the rendered comment body
3. Publishes report-\<H\>.html + comment.md + snap.json + viol.json as the `code-ranker-report` build artifact (same-repo and fork PRs alike)
4. The code-ranker backend downloads that artifact via a `workflow_run` webhook and the code-ranker GitHub App posts/updates the PR comment (backend-side — this workflow never needs `pull-requests: write`)

Repos still on the older caller stub (the one that granted `id-token: write`) keep working: the workflow picks its delivery path per run, and takes exactly one of them — see [Two delivery paths](#two-delivery-paths).

By default code-ranker is advisory (`do_check: false`): findings show up in the PR comment and, if you opt into `sarif: true`, in code scanning — but never red the job. Pass `do_check: true` — and mark `code-ranker` a required status check — to gate merges on them instead.

The comment reflects the mode: advisory findings are listed neutrally (e.g. "3 findings"), a gate run marks them "error ❌" with a collapsible Violations list. The AI fix-prompt section is included whenever there's at least one finding, and omitted on a clean run; a language with nothing new to report (no findings, no real metric change) is likewise simply omitted — no "no baseline yet" filler. And when a run is **fully** clean — no findings and no metric changes anywhere — no PR comment is posted at all; the report is still published and reachable from your dashboard, so a green PR isn't nagged.

## Setup

Copy the stub into your repo as `.github/workflows/code-ranker.yml`:

```yaml
name: code-ranker
on:
  pull_request:
  push:
jobs:
  code-ranker:
    uses: code-ranker-com/actions/.github/workflows/report.yml@v1
    permissions:
      contents: read            # the only permission needed by default
```

`push` is left unfiltered on purpose: every push refreshes that branch's own baseline snapshot, cached under its branch name. A PR diffs against its actual base branch's baseline — whatever that branch is called, not just your default — and a push refreshes the pushed-to branch's own baseline the same way. There's no cross-branch fallback: a branch (or PR base) with no baseline yet renders a report without a diff rather than diffing against the wrong branch.

> If installed via the GitHub App, the [dashboard](https://dashboard.code-ranker.com) offers one-click setup links for each repository that open GitHub's file editor with this workflow prefilled — choose the floating `@v1` (auto-updates) or the exact release commit SHA (immutable, Dependabot-bumpable). You review and commit the file yourself; the App has no write access to your code.

## No secrets, no OIDC

The current stub requests no `id-token: write`: the workflow publishes the report, rendered comment, snapshot, and violations file as the `code-ranker-report` build artifact, and the code-ranker backend picks that up itself via a `workflow_run` webhook (a privileged, base-repo context regardless of where the run came from). Nothing goes in **Settings → Secrets**.

### Two delivery paths

A run takes **exactly one** of these, chosen by whether an OIDC token is available to it:

| Caller stub | What the run does |
|---|---|
| current (`permissions: contents: read`) | publishes the `code-ranker-report` artifact; the backend ingests it via `workflow_run` |
| older stub with `id-token: write` | mints an OIDC token and `POST`s the report straight to `api.code-ranker.com/upload`; no artifact is published |

Why both exist: moving the `v1` tag to the artifact-only version stopped report delivery for
every repo whose stub had not been updated — their runs went green while no report and no PR
comment appeared. The paths are mutually exclusive (`LEGACY_OIDC` is computed in a step, not
an `if:` expression, because `ACTIONS_ID_TOKEN_REQUEST_URL` is not visible to the `env`
context of a condition), so a report is never delivered twice. A fork PR gets no OIDC token
even from a stub that asks for one, so it always falls through to the artifact path.

Both paths are advisory (`continue-on-error`): a delivery failure never reds the caller's job.

## SARIF / code scanning (opt-in)

`sarif` defaults to `false`: by default the workflow does not write to your repo's Security tab. To get inline code-scanning alerts on the PR diff, opt in explicitly:

```yaml
    uses: code-ranker-com/actions/.github/workflows/report.yml@v1
    with:
      sarif: true
    permissions:
      contents: read
      security-events: write   # required only when sarif: true
```

The upload only runs for same-repo events (a push, or a PR from a branch in the same repo): a fork PR gets a read-only token that can't write to code scanning, so the step is skipped there — like the rest of the report/comment pipeline, a SARIF miss is advisory and never fails the job.

## Versioning `@v1`

The stub pins the floating major tag `@v1`. Compatible improvements (new analysis flags, install speed, fixes) land automatically — we move `v1` to new releases.

- Backwards-compatible changes → patch/minor release, `v1` tag follows.
- Breaking changes → new major `v2`; **`v1` never breaks in place**.

For full reproducibility, pin to a SHA and use Dependabot:  
`uses: code-ranker-com/actions/.github/workflows/report.yml@<sha>`

Inside the reusable workflow itself, every action it calls (`actions/checkout`, `actions/cache`, `actions/upload-artifact`, `github/codeql-action/upload-sarif`) is pinned to a commit SHA, and the `code-ranker` CLI is installed from a fixed release download (currently `v5.0.4`) rather than `releases/latest`. So whichever ref you point `uses:` at, that run's actions and CLI build are deterministic — they don't drift underneath you between runs.

## Fork PRs

Same-repo and fork PRs are handled identically: the workflow always publishes the HTML report, rendered comment, snapshot, and violations file as the `code-ranker-report` build artifact (no secrets, no OIDC), and the code-ranker backend picks it up itself via a `workflow_run` webhook, uploads the report, and posts the PR comment through the GitHub App. **`pull_request_target` is never used.**

No extra setup is needed in your repo for this — it works out of the box with the same stub.

## Repository files

| File | Role |
|---|---|
| `.github/workflows/report.yml` | Reusable workflow |
| `caller-stub.yml` | Stub to copy into your repository |
