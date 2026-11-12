#!/usr/bin/env bash
# Intake: validate a pushed clarification file, create/update the story issue and PR,
# set the state to "ready" and dispatch the spec stage.
# Env: REPO BRANCH SHA BEFORE DEFAULT_BRANCH GH_TOKEN PM_USERNAME
#      [PROJECT_TOKEN PROJECT_OWNER PROJECT_NUMBER] STATE_SCRIPT
set -euo pipefail

: "${REPO:?}" "${BRANCH:?}" "${SHA:?}" "${DEFAULT_BRANCH:?}" "${STATE_SCRIPT:?}"
BEFORE="${BEFORE:-}"
PM_USERNAME="${PM_USERNAME:-}"
MAX_BYTES=200000
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---- 1. story id from the branch name
if [[ ! "$BRANCH" =~ ^story/([A-Z][A-Z0-9]*-[0-9]+)$ ]]; then
  echo "::error::Branch '$BRANCH' must be named story/<ID> (for example story/DEMO-1, upper case)" >&2
  exit 1
fi
STORY_ID="${BASH_REMATCH[1]}"
FILE="stories/$STORY_ID/clarification.md"
SHORT="${SHA:0:7}"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/$REPO/actions/runs/${GITHUB_RUN_ID:-0}"

set_state() { REPO="$REPO" ISSUE="$ISSUE" STATE="$1" bash "$STATE_SCRIPT"; }

# ---- 2. find an existing issue (open PR marker first, then title search)
find_issue() {
  local n
  n=$(gh pr list --repo "$REPO" --head "$BRANCH" --state open --json body --jq '.[0].body // ""' \
      | grep -oP '(?<=<!-- story-issue: )[0-9]+' | head -1 || true)
  if [ -n "$n" ]; then echo "$n"; return; fi
  gh issue list --repo "$REPO" --state all --search "$STORY_ID in:title" --json number,title,state --limit 50 \
    --jq "[.[] | select(.title | startswith(\"[$STORY_ID] \"))] | sort_by(.state != \"OPEN\", -.number) | .[0].number // empty"
}

ISSUE=$(find_issue)
EXISTING=false
if [ -n "$ISSUE" ]; then
  EXISTING=true
  LABELS=$(gh issue view "$ISSUE" --repo "$REPO" --json labels --jq '[.labels[].name] | join(",")')
  if [[ ",$LABELS," == *",spec-approved,"* ]]; then
    gh issue comment "$ISSUE" --repo "$REPO" --body "Ignored push \`$SHORT\` to \`$BRANCH\`: the specification for $STORY_ID was already approved and merged. To change it, start a new story or ask the maintainers to reopen this one."
    echo "::warning::$STORY_ID is already approved; push ignored"
    exit 0
  fi
fi

# ---- 3. validate the push
ERRORS=()

changed_files() {
  local base="$BEFORE"
  if [ -z "$base" ] || [[ "$base" =~ ^0+$ ]]; then base="$DEFAULT_BRANCH"; fi
  gh api "repos/$REPO/compare/$base...$SHA" --paginate --jq '.files[].filename' 2>/dev/null \
    || gh api "repos/$REPO/compare/$DEFAULT_BRANCH...$SHA" --paginate --jq '.files[].filename'
}

OTHERS=$(changed_files | grep -E '^stories/[^/]+/clarification\.md$' | grep -vxF "$FILE" || true)
if [ -n "$OTHERS" ]; then
  ERRORS+=("Pushed clarification for a different story than the branch ($(echo "$OTHERS" | paste -sd, -)). The folder name must match the branch: \`$FILE\`.")
fi

TITLE="Specification"
if gh api "repos/$REPO/contents/$FILE?ref=$SHA" >"$TMP/meta.json" 2>"$TMP/err"; then
  if ! jq -e 'type == "object" and .type == "file"' "$TMP/meta.json" >/dev/null; then
    ERRORS+=("\`$FILE\` is not a regular file.")
  else
    gh api -H "Accept: application/vnd.github.raw+json" "repos/$REPO/contents/$FILE?ref=$SHA" >"$TMP/clar.md"
    BYTES=$(wc -c <"$TMP/clar.md")
    if [ "$(tr -d '\000' <"$TMP/clar.md" | wc -c)" -ne "$BYTES" ] || ! iconv -f UTF-8 -t UTF-8 "$TMP/clar.md" >/dev/null 2>&1; then
      ERRORS+=("\`$FILE\` is not valid UTF-8 text.")
    elif [ -z "$(tr -d '[:space:]' <"$TMP/clar.md")" ]; then
      ERRORS+=("\`$FILE\` is empty.")
    elif [ "$BYTES" -gt "$MAX_BYTES" ]; then
      ERRORS+=("\`$FILE\` is $BYTES bytes; the limit is $MAX_BYTES bytes.")
    else
      T=$(sed -n 's/^# \+//p' "$TMP/clar.md" | head -1 | tr -d '\r' | cut -c1-80 | sed 's/[[:space:]]*$//')
      if [ -n "$T" ]; then TITLE="$T"; fi
    fi
  fi
else
  if grep -q '404' "$TMP/err"; then
    ERRORS+=("\`$FILE\` was not found at commit \`$SHORT\`. The file must be at exactly this path.")
  else
    echo "::error::Could not read $FILE: $(cat "$TMP/err")" >&2
    exit 1
  fi
fi

# ---- 4. make sure an issue exists
build_body() {
  local pr_line="_not created yet_"
  [ -n "${PR:-}" ] && pr_line="#$PR"
  cat <<EOF
**Story:** $STORY_ID
**Branch:** \`$BRANCH\`
**Clarification:** [$FILE](${GITHUB_SERVER_URL:-https://github.com}/$REPO/blob/$SHA/$FILE) (commit \`$SHORT\`)
**Specification PR:** $pr_line
**PM (approver):** ${PM_USERNAME:+@$PM_USERNAME}

_Managed by the story pipeline. Progress is shown on the Project board; do not edit this description._
EOF
}

if [ "$EXISTING" = false ]; then
  NEW_TITLE="[$STORY_ID] $TITLE"
  [ ${#ERRORS[@]} -gt 0 ] && NEW_TITLE="[$STORY_ID] Story"
  ISSUE_URL=$(gh issue create --repo "$REPO" --title "$NEW_TITLE" --body "$(PR='' build_body)")
  ISSUE="${ISSUE_URL##*/}"
  echo "Created issue #$ISSUE"
fi

# ---- 5. invalid input: report and stop
if [ ${#ERRORS[@]} -gt 0 ]; then
  {
    echo "### Clarification needs fixes"
    echo "Checked commit \`$SHORT\` on \`$BRANCH\`:"
    for e in "${ERRORS[@]}"; do echo "- $e"; done
    echo
    echo "Push a corrected file to \`$BRANCH\` and the pipeline will run again. ([run]($RUN_URL))"
  } >"$TMP/comment.md"
  gh issue comment "$ISSUE" --repo "$REPO" --body-file "$TMP/comment.md"
  set_state needs-fixes
  echo "::warning::Clarification for $STORY_ID is invalid: ${ERRORS[*]}"
  exit 0
fi

# ---- 6. valid input: reopen if needed, ensure PR, update issue, dispatch
if [ "$EXISTING" = true ]; then
  gh issue reopen "$ISSUE" --repo "$REPO" >/dev/null 2>&1 || true
  gh issue comment "$ISSUE" --repo "$REPO" --body "Clarification updated at \`$SHORT\`. Resetting to Ready and regenerating the specification. ([run]($RUN_URL))"
fi

PR=$(gh pr list --repo "$REPO" --head "$BRANCH" --state open --json number --jq '.[0].number // empty')
if [ -z "$PR" ]; then
  cat >"$TMP/pr.md" <<EOF
Specification review for **$STORY_ID** (issue #$ISSUE).

- **Approve** to accept the specification. It is then merged into \`$DEFAULT_BRANCH\`.
- **Request changes** with feedback to get a new draft on this same PR (maximum 5 revisions).

Only the designated PM's review counts.

Closes #$ISSUE
<!-- story-issue: $ISSUE -->
EOF
  if ! PR_URL=$(gh pr create --repo "$REPO" --base "$DEFAULT_BRANCH" --head "$BRANCH" \
        --title "[$STORY_ID] Specification" --body-file "$TMP/pr.md" 2>"$TMP/prerr"); then
    set_state error
    gh issue comment "$ISSUE" --repo "$REPO" --body "Could not open the specification PR: $(tr '\n' ' ' <"$TMP/prerr") ([run]($RUN_URL))"
    echo "::error::PR creation failed: $(cat "$TMP/prerr")" >&2
    exit 1
  fi
  PR="${PR_URL##*/}"
  echo "Created PR #$PR"
fi

gh issue edit "$ISSUE" --repo "$REPO" --body "$(build_body)" >/dev/null
set_state ready

if ! gh workflow run spec-stage.yml --repo "$REPO" --ref "$DEFAULT_BRANCH" \
      -f story_id="$STORY_ID" -f issue_number="$ISSUE" -f pr_number="$PR" -f mode=initial 2>"$TMP/diserr"; then
  set_state error
  gh issue comment "$ISSUE" --repo "$REPO" --body "Could not start the spec stage: $(tr '\n' ' ' <"$TMP/diserr") ([run]($RUN_URL))"
  echo "::error::Dispatch failed: $(cat "$TMP/diserr")" >&2
  exit 1
fi
echo "Dispatched spec stage for $STORY_ID (issue #$ISSUE, PR #$PR)"