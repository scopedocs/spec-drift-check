#!/usr/bin/env bash
#
# Runs one ScopeDocs spec drift check and reports the result.
#
# Two calls to the public v1 API: POST /api/v1/drift/check to start the run,
# then GET /api/v1/drift/runs/{id} until it lands. The report comes back as
# rendered markdown, so this script formats nothing.
#
# Every failure mode reports and exits 0 by default — a drift check that cannot
# run must not break someone's build. The only deliberate non-zero exit is the
# fail-under coverage gate.

set -euo pipefail

readonly SPEC_MIN_CHARS=20
readonly SPEC_MAX_CHARS=40000
readonly POLL_INTERVAL_SECONDS=10

WORK_DIR="$(mktemp -d)"
readonly WORK_DIR
readonly BODY_FILE="$WORK_DIR/body.json"
readonly RESP_FILE="$WORK_DIR/resp.json"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# ---------------------------------------------------------------- reporting

log() { printf '%s\n' "$*"; }

# Appends to the job summary when enabled, and always to the log so the
# reason is visible in a re-run without expanding the summary.
report() {
  printf '%s\n' "$*"
  if [ "${INPUT_JOB_SUMMARY:-true}" = "true" ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"
  fi
}

set_output() {
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
}

# Report why nothing ran and finish successfully. A missing spec or an
# unreachable backend is not the pull request's fault.
give_up() {
  local status="$1"
  shift
  set_output "status" "$status"
  set_output "coverage-score" ""
  report "$@"
  exit 0
}

# ------------------------------------------------------------------- inputs

REPO="${INPUT_REPO:-}"
[ -n "$REPO" ] || REPO="${DEFAULT_REPO:-}"
[ -n "$REPO" ] || give_up "error" "No repository to check: pass \`repo\` or run this inside a GitHub repository."

[ -n "${SCOPEDOCS_API_KEY:-}" ] || give_up "error" \
  "\`api-key\` is empty. Set it from a repository secret — note that a pull_request run from a fork receives no secrets."
[ -n "${SCOPEDOCS_API_URL:-}" ] || give_up "error" "\`api-url\` is empty."

API_URL="${SCOPEDOCS_API_URL%/}"

WAIT_SECONDS="${INPUT_WAIT_SECONDS:-20}"
case "$WAIT_SECONDS" in
  ''|*[!0-9]*) give_up "error" "\`wait-seconds\` must be a whole number, got \"$WAIT_SECONDS\"." ;;
esac
[ "$WAIT_SECONDS" -le 240 ] || give_up "error" "\`wait-seconds\` caps at 240, got $WAIT_SECONDS."

POLL_TIMEOUT="${INPUT_POLL_TIMEOUT_SECONDS:-600}"
case "$POLL_TIMEOUT" in
  ''|*[!0-9]*) give_up "error" "\`poll-timeout-seconds\` must be a whole number, got \"$POLL_TIMEOUT\"." ;;
esac

FAIL_UNDER="${INPUT_FAIL_UNDER:-}"
if [ -n "$FAIL_UNDER" ]; then
  case "$FAIL_UNDER" in
    *[!0-9.]*|.|'') give_up "error" "\`fail-under\` must be a number between 0 and 1, got \"$FAIL_UNDER\"." ;;
  esac
fi

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || give_up "error" \
    "\`$tool\` is not installed on this runner. It is preinstalled on GitHub-hosted runners; add it in a self-hosted image."
done

# ------------------------------------------------------------------- target
#
# Branch-compare when a base is given (the push shape), otherwise the pull
# request that triggered the run. Being explicit beats inferring from the
# event: a workflow that checks a release base on push should keep doing that
# even when re-run manually.

TARGET_KIND=""
PR_NUMBER="${INPUT_PR_NUMBER:-}"
BASE_REF="${INPUT_BASE_REF:-}"
HEAD_REF="${INPUT_HEAD_REF:-}"

if [ -n "$BASE_REF" ]; then
  TARGET_KIND="branch"
  [ -n "$HEAD_REF" ] || HEAD_REF="${DEFAULT_HEAD_REF:-}"
  [ -n "$HEAD_REF" ] || give_up "error" "\`base-ref\` was given without a \`head-ref\`, and no branch could be inferred."
  if [ "$BASE_REF" = "$HEAD_REF" ]; then
    give_up "skipped" \
      "\`base-ref\` and \`head-ref\` are both \`$HEAD_REF\` — there is nothing to compare. Point \`base-ref\` at the release base."
  fi
else
  [ -n "$PR_NUMBER" ] || PR_NUMBER="${EVENT_PR_NUMBER:-}"
  case "$PR_NUMBER" in
    ''|*[!0-9]*)
      give_up "error" \
        "No target to check. On a pull_request trigger this is automatic; on a push trigger set \`base-ref\` (and optionally \`head-ref\`)."
      ;;
  esac
  TARGET_KIND="pr"
fi

# --------------------------------------------------------------------- spec

SPEC_FILE="${INPUT_SPEC_FILE:-.scopedocs/drift-spec.md}"
SPEC_SOURCE=""

if [ -f "$SPEC_FILE" ]; then
  SPEC_SOURCE="$SPEC_FILE"
elif [ "$TARGET_KIND" = "pr" ] && [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "${GITHUB_EVENT_PATH}" ]; then
  # A push event carries no PR body, so this fallback is PR-only.
  SPEC_SOURCE="$WORK_DIR/spec.md"
  jq -r '.pull_request.body // empty' "$GITHUB_EVENT_PATH" > "$SPEC_SOURCE" 2>/dev/null || : > "$SPEC_SOURCE"
  log "No $SPEC_FILE in the repository — falling back to the pull request description."
else
  give_up "skipped" "No spec to check against: \`$SPEC_FILE\` is not in the repository."
fi

SPEC_CHARS="$(wc -m < "$SPEC_SOURCE" | tr -d '[:space:]')"

if [ "$SPEC_CHARS" -lt "$SPEC_MIN_CHARS" ]; then
  if [ "$SPEC_SOURCE" = "$SPEC_FILE" ]; then
    give_up "skipped" "\`$SPEC_FILE\` holds $SPEC_CHARS characters; a spec needs at least $SPEC_MIN_CHARS."
  fi
  give_up "skipped" \
    "No spec to check against: \`$SPEC_FILE\` is missing and the pull request description is empty."
fi

if [ "$SPEC_CHARS" -gt "$SPEC_MAX_CHARS" ]; then
  give_up "skipped" \
    "The spec is $SPEC_CHARS characters; the limit is $SPEC_MAX_CHARS. Trim it to the requirements this change is meant to satisfy."
fi

# ------------------------------------------------------------- request body
#
# --rawfile keeps the spec out of the process table and the logs, and jq owns
# every bit of escaping — quotes, backticks, newlines and unicode all survive.

if [ "$TARGET_KIND" = "pr" ]; then
  jq -n \
    --arg repo "$REPO" \
    --rawfile spec "$SPEC_SOURCE" \
    --argjson pr "$PR_NUMBER" \
    --argjson wait "$WAIT_SECONDS" \
    --arg ws "${INPUT_WORKSPACE_ID:-}" \
    '{repo: $repo, spec_text: $spec, pr_number: $pr,
      wait_seconds: $wait, spec_source: "api"}
     + (if $ws == "" then {} else {workspace_id: $ws} end)' > "$BODY_FILE"
  TARGET_LABEL="pull request #$PR_NUMBER in $REPO"
else
  jq -n \
    --arg repo "$REPO" \
    --rawfile spec "$SPEC_SOURCE" \
    --arg base "$BASE_REF" \
    --arg head "$HEAD_REF" \
    --argjson wait "$WAIT_SECONDS" \
    --arg ws "${INPUT_WORKSPACE_ID:-}" \
    '{repo: $repo, spec_text: $spec, base_ref: $base, head_ref: $head,
      wait_seconds: $wait, spec_source: "api"}
     + (if $ws == "" then {} else {workspace_id: $ws} end)' > "$BODY_FILE"
  TARGET_LABEL="$BASE_REF...$HEAD_REF in $REPO"
fi

log "Checking $TARGET_LABEL against $SPEC_CHARS characters of spec."

# ------------------------------------------------------------------ the run

# curl's exit code is swallowed on purpose: a transport failure must produce a
# reported reason, not an unexplained non-zero step.
HTTP="$(curl -sS --max-time 90 -o "$RESP_FILE" -w '%{http_code}' \
  -X POST "$API_URL/api/v1/drift/check" \
  -H "X-API-Key: $SCOPEDOCS_API_KEY" \
  -H "Content-Type: application/json" \
  --data @"$BODY_FILE" 2>"$WORK_DIR/curl.err")" || HTTP="000"

if [ "$HTTP" != "200" ]; then
  DETAIL="$(jq -r '.detail // empty' "$RESP_FILE" 2>/dev/null || true)"
  [ -n "$DETAIL" ] || DETAIL="$(head -c 500 "$RESP_FILE" 2>/dev/null || true)"
  [ -n "$DETAIL" ] || DETAIL="$(head -c 300 "$WORK_DIR/curl.err" 2>/dev/null || true)"
  [ -n "$DETAIL" ] || DETAIL="(no response body)"

  HINT="Check the api-key and api-url inputs."
  case "$HTTP" in
    000) HINT="The backend did not answer. Check that api-url is reachable from this runner." ;;
    401) HINT="The key is wrong, expired, or absent — a pull_request run from a fork gets no secrets." ;;
    403) HINT="The key is valid but lacks the prs:read scope." ;;
    400) HINT="An organization-wide key spanning several workspaces needs the workspace-id input." ;;
    404) HINT="The repository is not connected to the workspace this key resolves to." ;;
    422) HINT="The request was rejected as invalid — usually the spec length or a missing branch ref." ;;
    5??) HINT="The backend errored. Re-running usually clears a transient failure." ;;
  esac

  # Backticks below are markdown code spans in the printf format, not
  # command substitution — printf fills every value through %s.
  # shellcheck disable=SC2016
  give_up "error" "$(printf '### Drift check could not start (HTTP %s)\n\n```\n%s\n```\n\n%s' "$HTTP" "$DETAIL" "$HINT")"
fi

RUN_ID="$(jq -r '.run_id // empty' "$RESP_FILE")"
STATUS="$(jq -r '.status // "unknown"' "$RESP_FILE")"

[ -n "$RUN_ID" ] || give_up "error" \
  "The API accepted the request but returned no run id, so there is nothing to poll."

set_output "run-id" "$RUN_ID"
log "Drift run $RUN_ID started (status: $STATUS)."

# --------------------------------------------------------------------- poll
#
# Every response is validated as JSON before jq reads it: a gateway that
# answers with an HTML error page must not crash the step.

WAITED=0
while [ "$STATUS" != "complete" ] && [ "$STATUS" != "failed" ]; do
  if [ "$WAITED" -ge "$POLL_TIMEOUT" ]; then
    # Backticks below are markdown code spans in the printf format, not
    # command substitution — printf fills every value through %s.
    # shellcheck disable=SC2016
    give_up "timeout" \
      "$(printf 'The drift check was still running after %ss. It keeps going server-side — the report will appear in the ScopeDocs Drift page for run `%s`.' "$POLL_TIMEOUT" "$RUN_ID")"
  fi

  sleep "$POLL_INTERVAL_SECONDS"
  WAITED=$((WAITED + POLL_INTERVAL_SECONDS))

  HTTP="$(curl -sS --max-time 30 -o "$RESP_FILE" -w '%{http_code}' \
    "$API_URL/api/v1/drift/runs/$RUN_ID" \
    -H "X-API-Key: $SCOPEDOCS_API_KEY" 2>/dev/null)" || HTTP="000"

  if [ "$HTTP" != "200" ] || ! jq -e . "$RESP_FILE" >/dev/null 2>&1; then
    log "Poll returned HTTP $HTTP after ${WAITED}s — retrying."
    continue
  fi

  STATUS="$(jq -r '.status // "unknown"' "$RESP_FILE")"
done

set_output "status" "$STATUS"

# ------------------------------------------------------------------- report

REPORT_PATH="${INPUT_REPORT_PATH:-drift-report.md}"

if [ "$STATUS" = "failed" ]; then
  ERROR="$(jq -r '.error // "no reason given"' "$RESP_FILE")"
  set_output "coverage-score" ""
  # Backticks below are markdown code spans in the printf format, not
  # command substitution — printf fills every value through %s.
  # shellcheck disable=SC2016
  report "$(printf '### Drift check did not finish\n\nChecked %s.\n\n```\n%s\n```' "$TARGET_LABEL" "$ERROR")"
  exit 0
fi

jq -r '.report_markdown // empty' "$RESP_FILE" > "$REPORT_PATH"

if [ ! -s "$REPORT_PATH" ]; then
  set_output "coverage-score" ""
  report "The run completed but returned no report. Open run \`$RUN_ID\` in the ScopeDocs Drift page."
  exit 0
fi

COVERAGE="$(jq -r '.coverage_score // empty' "$RESP_FILE")"
set_output "coverage-score" "$COVERAGE"
set_output "report-path" "$REPORT_PATH"

cat "$REPORT_PATH"
if [ "${INPUT_JOB_SUMMARY:-true}" = "true" ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$REPORT_PATH" >> "$GITHUB_STEP_SUMMARY"
fi

# --------------------------------------------------------------------- gate

if [ -n "$FAIL_UNDER" ]; then
  [ -n "$COVERAGE" ] || COVERAGE="0"
  if ! awk -v c="$COVERAGE" -v f="$FAIL_UNDER" 'BEGIN { exit (c + 0 >= f + 0 ? 0 : 1) }'; then
    report "$(printf '\n**Coverage %s is below the %s floor.**' "$COVERAGE" "$FAIL_UNDER")"
    exit 1
  fi
  log "Coverage $COVERAGE meets the $FAIL_UNDER floor."
fi
