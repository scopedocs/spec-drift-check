# ScopeDocs spec drift check

Check whether a code change actually implements the spec it was written from —
in CI, on the branch or pull request that is about to ship.

You write the intent in prose. The engine extracts the discrete requirements
from it, then has several models independently judge each one against the real
diff. Every verdict has to cite a quote that mechanically matches the patch, so
a model cannot vouch for code that is not there. It also reports the reverse:
significant changes in the diff that no requirement explains.

The report lands in the workflow's job summary. Nothing to install, no app, no
webhook — the action makes two HTTP requests to the ScopeDocs public API.

```yaml
- uses: actions/checkout@v4
- uses: scopedocs/spec-drift-check@v1
  with:
    api-key: ${{ secrets.SCOPEDOCS_API_KEY }}
```

## Setup

1. **Create an API key** with the `prs:read` scope in the ScopeDocs app under
   Settings → API keys.
2. **Add it as a repository secret**, `SCOPEDOCS_API_KEY` (Settings → Secrets
   and variables → Actions).
3. **Commit a spec** at `.scopedocs/drift-spec.md`.

The spec is prose, not a checklist — the engine does the breaking-down:

```markdown
What: shoppers can apply a discount code at checkout.

How: a code field on the checkout page, validated against the discount table
and applied to the order total before shipping is calculated.

Expected: a valid code lowers the total; an expired or unknown code shows an
error and leaves the total unchanged; the applied code is stored on the order.

How would you know: entering a valid code at checkout lowers the displayed
total, and the order record shows which code was used.
```

Anything from 20 to 40 000 characters works — a pasted ticket, a section of
meeting notes, or a paragraph you typed. Keep it in version control next to the
code it describes: a spec written *before* the change, by whoever asked for it,
is what makes the check meaningful. A description written afterwards by the
author always agrees with itself.

## On a release pull request

```yaml
name: Spec drift check

on:
  pull_request:
    branches: [main]        # your release branch

permissions:
  contents: read

# One check per branch — a force-push shouldn't pay for a second jury run.
concurrency:
  group: drift-${{ github.ref }}
  cancel-in-progress: true

jobs:
  drift:
    if: github.event.pull_request.draft == false
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: scopedocs/spec-drift-check@v1
        with:
          api-key: ${{ secrets.SCOPEDOCS_API_KEY }}
```

The pull request number comes from the event, and the spec falls back to the PR
description when `.scopedocs/drift-spec.md` is absent.

## On every push to an integration branch

Before the release PR exists, compare the branch against its release base:

```yaml
on:
  push:
    branches: [qa]

jobs:
  drift:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: scopedocs/spec-drift-check@v1
        with:
          api-key: ${{ secrets.SCOPEDOCS_API_KEY }}
          base-ref: main        # the release base to compare against
```

`head-ref` defaults to the branch that was pushed. A push event carries no PR
body, so the committed spec file is the only source here.

## Failing the build on drift

Report-only is the default: the job succeeds whatever the report says. Surface
the drift first, enforce once the team trusts the verdicts.

```yaml
      - uses: scopedocs/spec-drift-check@v1
        with:
          api-key: ${{ secrets.SCOPEDOCS_API_KEY }}
          base-ref: main
          fail-under: "0.6"     # fail below 60% coverage
```

A floor between 0.6 and 0.8 is a reasonable start. Prefer gating the release
boundary only — blocking every feature branch on a coverage number teaches
people to write specs that score well rather than specs that are true.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `api-key` | — | **Required.** ScopeDocs API key with the `prs:read` scope. |
| `api-url` | `https://api.scopedocs.ai` | Backend base URL. Change it for a self-hosted deployment. |
| `spec-file` | `.scopedocs/drift-spec.md` | Path to the committed spec. |
| `repo` | this repository | Repository to check, `owner/name`. |
| `pr-number` | the triggering PR | Pull request to check. |
| `base-ref` | — | Release base. Setting it selects branch-compare mode. |
| `head-ref` | the pushed branch | Branch carrying the change, used with `base-ref`. |
| `workspace-id` | — | Only for organization-wide keys spanning several workspaces. |
| `wait-seconds` | `20` | How long the API holds the request open before the action polls (max 240). |
| `poll-timeout-seconds` | `600` | How long to keep polling before giving up on the run. |
| `fail-under` | — | Fail the job below this coverage score. Empty means report-only. |
| `report-path` | `drift-report.md` | Where the report markdown is written. |
| `job-summary` | `true` | Write the report into the job summary. |

## Outputs

| Output | Description |
| --- | --- |
| `status` | `complete`, `failed`, `timeout`, `error`, or `skipped`. |
| `coverage-score` | Share of the intent that shipped, `0`..`1`. Empty unless `status` is `complete`. |
| `run-id` | Drift run id, for fetching the report again later. |
| `report-path` | Path of the written report, when one was produced. |

Use them to post the report wherever your team reads:

```yaml
      - uses: scopedocs/spec-drift-check@v1
        id: drift
        with:
          api-key: ${{ secrets.SCOPEDOCS_API_KEY }}

      - uses: actions/upload-artifact@v4
        if: steps.drift.outputs.report-path != ''
        with:
          name: drift-report
          path: ${{ steps.drift.outputs.report-path }}
```

## Reading the report

```markdown
## Drift check: 70% of the intent shipped
`main...qa` in acme/backend · 5 requirements · jury of 3

### Missing — no evidence in the diff (1)
- an expired discount code shows an error
  - The diff validates the code against the table but never checks its
    expiry date, and no error path exists for an expired code.

### Partial — started but incomplete, or shipped switched off (1)
- the applied discount code is stored on the order
  - The order model gained a discount_code column, but nothing writes to it.

### Covered (3)
…
```

| Verdict | Meaning |
| --- | --- |
| `covered` | implemented, with a diff quote that proves it |
| `partial` | started but incomplete, or shipped behind an off switch |
| `missing` | no evidence in the diff |
| `contested` | the models disagreed, or none could cite valid evidence |

The same run also appears on the workspace's Drift page in the ScopeDocs app,
so whoever wrote the spec can read the result without opening your CI.

## Notes

- **A drift check never breaks your build by accident.** A missing spec, a bad
  key, an unreachable backend, a failed run — each reports its reason and exits
  successfully. The only deliberate failure is the `fail-under` gate.
- **Fork pull requests get no secrets.** `api-key` arrives empty and the action
  reports that. Checking fork contributions needs `pull_request_target`, with
  the usual caution about secrets and untrusted code.
- **Each check is a full jury pass over the diff**, so be deliberate about when
  one runs: keep the `concurrency` block, skip draft PRs, and prefer the
  integration or release branch over every feature branch.
- **Other pipelines** can call the same two endpoints directly — see the
  [Drift API reference](https://docs.scopedocs.ai/api-reference/drift-api).
- `curl` and `jq` are preinstalled on GitHub-hosted runners. On a self-hosted
  image, add them.

## Versioning

`@v1` tracks the latest v1.x release, so fixes reach you without editing your
workflow. Pin `@v1.2.3` to freeze a specific release.

## Links

- [Drift checks in CI](https://docs.scopedocs.ai/getting-started/drift-in-ci) — the full guide
- [Drift API reference](https://docs.scopedocs.ai/api-reference/drift-api) — the endpoints this action calls
