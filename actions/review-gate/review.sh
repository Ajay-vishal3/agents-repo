#!/usr/bin/env bash
# Review gate: turn the PM's PR review into a pipeline action.
#   approved          -> merge the PR, state "approved"
#   changes_requested -> state "drafting", dispatch the spec stage with the feedback
# Env: REPO GH_TOKEN EVENT_PATH PM_USERNAME STATE_SCRIPT [MAX_REVISIONS PROJECT_TOKEN PROJECT_OWNER PROJECT_NUMBER]
set -euo pipefail

: "${REPO:?}" "${EVENT_PATH:?}" "${PM_USERNAME:?PM_USERNAME is required}" "${STATE_SCRIPT:?}"
MAX_REVISIONS="${MAX_REVISIONS:-5}"
MAX_FEEDBACK=20000
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ev() { jq -r "$1" "$EVENT_PATH"; }

ACTION=$(ev '.action // ""')
REVIEW_STATE=$(ev '.review.state // "" | ascii_downcase')
REVIEWER=$(ev '.review.user.login // ""')
REVIEW_ID=$(ev '.review.id // ""')
REVIEW_COMMIT=$(ev '.review.commit_id // ""')
PR=$(ev '.pull_request.number // ""')
HEAD_REF=$(ev '.pull_request.head.ref // ""')
HEAD_SHA=$(ev '.pull_request.head.sha // ""')
PR_STATE=$(ev '.pull_request.state // ""')
DEFAULT_BRANCH=$(ev '.repository.default_branch // "main"')
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/$REPO/actions/runs/${GITHUB_RUN_ID:-0}"

set_state() { REPO="$REPO" ISSUE="$ISSUE" STATE="$1" bash "$STATE_SCRIPT"; }
say_pr() { gh pr comment "$PR" --repo "$REPO" --body "$1" >/dev/null; }

[ "$ACTION" = "submitted" ] || { echo "Ignoring action '$ACTION'"; exit 0; }
[[ "$HEAD_REF" =~ ^story/([A-Z][A-Z0-9]*-[0-9]+)$ ]] || { echo "Not a story PR; ignoring"; exit 0; }
STORY_ID="${BASH_REMATCH[1]}"
case "$REVIEW_STATE" in approved|changes_requested) ;; *) echo "Review state '$REVIEW_STATE' needs no action"; exit 0 ;; esac
[ "$PR_STATE" = "open" ] || { echo "PR is not open; ignoring"; exit 0; }

if [ "${REVIEWER,,}" != "${PM_USERNAME,,}" ]; then
  say_pr "Review by @$REVIEWER ignored: only @$PM_USERNAME can approve or request changes on a specification."
  exit 0
fi

ISSUE=$(gh pr view "$PR" --repo "$REPO" --json body --jq .body | grep -oP '(?<=<!-- story-issue: )[0-9]+' | head -1 || true)
if [ -z "$ISSUE" ]; then
  say_pr "Cannot find the linked story issue (missing \`story-issue\` marker in the PR description), so this review was not processed."
  echo "::error::No story-issue marker on PR #$PR" >&2
  exit 1
fi

LABELS=$(gh issue view "$ISSUE" --repo "$REPO" --json labels --jq '[.labels[].name] | join(",")')
if [[ ",$LABELS," != *",spec-in-review,"* ]]; then
  say_pr "Review ignored: $STORY_ID is not waiting for review right now (current labels: ${LABELS:-none}). Review again once a draft is ready."
  exit 0
fi

# A review of an older commit must not approve or revise a newer draft.
if [ "$REVIEW_COMMIT" != "$HEAD_SHA" ]; then
  say_pr "Review ignored: it was submitted on \`${REVIEW_COMMIT:0:7}\` but the PR is now at \`${HEAD_SHA:0:7}\`. Please review the latest draft."
  exit 0
fi

if [ "$REVIEW_STATE" = "approved" ]; then
  if ! gh pr merge "$PR" --repo "$REPO" --squash --match-head-commit "$HEAD_SHA" 2>"$TMP/err"; then
    gh issue comment "$ISSUE" --repo "$REPO" --body "Approved by @$REVIEWER, but the PR could not be merged: $(tr '\n' ' ' <"$TMP/err") The story stays in review. ([run]($RUN_URL))"
    echo "::error::Merge failed: $(cat "$TMP/err")" >&2
    exit 1
  fi
  set_state approved
  gh issue comment "$ISSUE" --repo "$REPO" --body "Specification for $STORY_ID approved by @$REVIEWER and merged into \`$DEFAULT_BRANCH\` at \`stories/$STORY_ID/specification.md\`."
  exit 0
fi

# ---- changes requested
{
  jq -r '.review.body // ""' "$EVENT_PATH"
  gh api "repos/$REPO/pulls/$PR/reviews/$REVIEW_ID/comments" --paginate \
    --jq '.[] | "- `\(.path):\(.line // .original_line // 0)` \(.body)"' 2>/dev/null || true
} >"$TMP/feedback.md"

if [ -z "$(tr -d '[:space:]' <"$TMP/feedback.md")" ]; then
  say_pr "Feedback is empty. Add review comments explaining what to change, then request changes again."
  exit 0
fi

DONE=$(gh api "repos/$REPO/pulls/$PR/reviews" --paginate \
  --jq ".[] | select((.user.login | ascii_downcase) == \"${PM_USERNAME,,}\" and .state == \"CHANGES_REQUESTED\") | 1" | wc -l | tr -d ' ')
# DONE includes the review being processed.
REVISION="$DONE"
if [ "$REVISION" -gt "$MAX_REVISIONS" ]; then
  say_pr "Revision limit reached ($MAX_REVISIONS). No new draft will be generated. Approve the current draft, edit the clarification file, or close this PR."
  exit 0
fi

FEEDBACK=$(head -c "$MAX_FEEDBACK" "$TMP/feedback.md")
set_state drafting
gh issue comment "$ISSUE" --repo "$REPO" --body "Revision $REVISION of $MAX_REVISIONS requested by @$REVIEWER. Regenerating the specification with your feedback. ([run]($RUN_URL))"

if ! gh workflow run spec-stage.yml --repo "$REPO" --ref "$DEFAULT_BRANCH" \
      -f story_id="$STORY_ID" -f issue_number="$ISSUE" -f pr_number="$PR" -f mode=revise -f feedback="$FEEDBACK" 2>"$TMP/err"; then
  set_state error
  gh issue comment "$ISSUE" --repo "$REPO" --body "Could not start the revision: $(tr '\n' ' ' <"$TMP/err") ([run]($RUN_URL))"
  echo "::error::Dispatch failed: $(cat "$TMP/err")" >&2
  exit 1
fi
echo "Dispatched revision $REVISION for $STORY_ID"