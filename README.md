# code-ranker-ci

Reusable GitHub Actions workflow for **code-ranker Reports**. Drop in one file, get an HTML report generated on your CI and posted as a PR comment by the code-ranker GitHub App — no secrets, no OIDC, and by default only `contents: read`.

Part of the [code-ranker](https://github.com/code-ranker-com/code-ranker) Reports product.

## License

Proprietary. This repository may only be used to integrate your repositories with the code-ranker service. All other uses are prohibited. See [LICENSE](LICENSE) for details.

## How it works

On every pull request (and every push) the workflow:

1. Installs `code-ranker` (precompiled binary, seconds)
2. Builds a self-contained HTML report for your code, plus the rendered comment body
3. Publishes report-\<H\>.html + comment.md + snap.json as the `code-ranker-report` build artifact (same-repo and fork PRs alike)
4. The code-ranker backend downloads that artifact via a `workflow_run` webhook and the code-ranker GitHub App posts/updates the PR comment (backend-side — this workflow never needs `pull-requests: write`, and never mints an OIDC token)

By default code-ranker is advisory (`do_check: false`): findings show up in the PR comment and, if you opt into `sarif: true`, in code scanning — but never red the job. Pass `do_check: true` — and mark `code-ranker` a required status check — to gate merges on them instead.

The comment reflects the mode: advisory findings are listed neutrally (e.g. "3 findings"), a gate run marks them "error ❌" with a collapsible Violations list. Either way an AI fix-prompt is always included, and a language with nothing new to report (no findings, no real metric change) is simply omitted — no "no baseline yet" filler.

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

`push` is left unfiltered on purpose: the stat-diff baseline is refreshed on your repo's actual default branch (checked at runtime), so this works out of the box whatever your default branch is called — no need to edit the trigger.

> If installed via GitHub App, the onboarding PR already adds this workflow for you — pinned to the exact release commit SHA rather than the floating `@v1` tag shown above, for a reproducible first install.

## No secrets, no OIDC

The workflow never mints an OIDC token and never calls an upload API directly. It publishes the report, rendered comment, and snapshot as the `code-ranker-report` build artifact; the code-ranker backend picks that up itself via a `workflow_run` webhook (a privileged, base-repo context regardless of where the run came from). Nothing goes in **Settings → Secrets**, and no `id-token: write` is requested.

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

## Versioning `@v1`

The stub pins the floating major tag `@v1`. Compatible improvements (new analysis flags, install speed, fixes) land automatically — we move `v1` to new releases.

- Backwards-compatible changes → patch/minor release, `v1` tag follows.
- Breaking changes → new major `v2`; **`v1` never breaks in place**.

For full reproducibility, pin to a SHA and use Dependabot:  
`uses: code-ranker-com/actions/.github/workflows/report.yml@<sha>`

## Fork PRs

Same-repo and fork PRs are handled identically: the workflow always publishes the HTML report, rendered comment, and snapshot as the `code-ranker-report` build artifact (no secrets, no OIDC), and the code-ranker backend picks it up itself via a `workflow_run` webhook, uploads the report, and posts the PR comment through the GitHub App. **`pull_request_target` is never used.**

No extra setup is needed in your repo for this — it works out of the box with the same stub.

## Repository files

| File | Role |
|---|---|
| `.github/workflows/report.yml` | Reusable workflow |
| `caller-stub.yml` | Stub to copy into your repository |
