#!/usr/bin/env bash
# Moves a story issue to a pipeline state: swaps the state label and sets the Project Status.
# Env: REPO ISSUE STATE GH_TOKEN [PROJECT_TOKEN PROJECT_OWNER PROJECT_NUMBER]
set -euo pipefail

: "${REPO:?REPO is required}" "${ISSUE:?ISSUE is required}" "${STATE:?STATE is required}"

STATE_LABELS=(needs-fixes ready-for-spec spec-drafting spec-in-review spec-approved spec-error)

# state -> label | Project Status option (empty = leave Status unchanged)
case "$STATE" in
  needs-fixes) LABEL=needs-fixes;    STATUS="Backlog" ;;
  ready)       LABEL=ready-for-spec; STATUS="Ready" ;;
  drafting)    LABEL=spec-drafting;  STATUS="Spec-Drafting" ;;
  in-review)   LABEL=spec-in-review; STATUS="Spec-in-Review" ;;
  approved)    LABEL=spec-approved;  STATUS="Done" ;;
  error)       LABEL=spec-error;     STATUS="" ;;
  *) echo "::error::Unknown state '$STATE'" >&2; exit 2 ;;
esac

declare -A COLORS=(
  [needs-fixes]=d93f0b [ready-for-spec]=0e8a16 [spec-drafting]=fbca04
  [spec-in-review]=1d76db [spec-approved]=5319e7 [spec-error]=b60205
)
for l in "${STATE_LABELS[@]}"; do
  gh label create "$l" --repo "$REPO" --color "${COLORS[$l]}" --description "Story pipeline state" --force >/dev/null
done

REMOVE=$(printf '%s\n' "${STATE_LABELS[@]}" | grep -vx "$LABEL" | paste -sd, -)
gh issue edit "$ISSUE" --repo "$REPO" --add-label "$LABEL" --remove-label "$REMOVE" >/dev/null
echo "Issue #$ISSUE -> state '$STATE' (label $LABEL)"

[ -z "$STATUS" ] && exit 0

if [ -z "${PROJECT_NUMBER:-}" ] || [ -z "${PROJECT_OWNER:-}" ]; then
  echo "::warning::PROJECT_OWNER/PROJECT_NUMBER not set; skipping Project status"
  exit 0
fi
if [ -z "${PROJECT_TOKEN:-}" ]; then
  echo "::error::PROJECT_TOKEN secret is missing; labels were updated but the Project board was not" >&2
  exit 1
fi

export GH_TOKEN="$PROJECT_TOKEN"

PROJECT_JSON=$(gh api graphql -f owner="$PROJECT_OWNER" -F number="$PROJECT_NUMBER" -f query='
  query($owner:String!,$number:Int!){
    repositoryOwner(login:$owner){
      ... on ProjectV2Owner{
        projectV2(number:$number){
          id
          field(name:"Status"){ ... on ProjectV2SingleSelectField{ id options{ id name } } }
        }
      }
    }
  }')

PROJECT_ID=$(jq -r '.data.repositoryOwner.projectV2.id // empty' <<<"$PROJECT_JSON")
FIELD_ID=$(jq -r '.data.repositoryOwner.projectV2.field.id // empty' <<<"$PROJECT_JSON")
[ -n "$PROJECT_ID" ] || { echo "::error::Project $PROJECT_OWNER/$PROJECT_NUMBER not found or token lacks access" >&2; exit 1; }
[ -n "$FIELD_ID" ] || { echo "::error::Project has no single-select 'Status' field" >&2; exit 1; }

# Match option names ignoring case and punctuation, so "Spec-in-Review" == "Spec in review".
OPTION_ID=$(jq -r --arg want "$STATUS" '
  def n: ascii_downcase | gsub("[^a-z0-9]"; "");
  .data.repositoryOwner.projectV2.field.options
  | map(select((.name | n) == ($want | n))) | .[0].id // empty' <<<"$PROJECT_JSON")
if [ -z "$OPTION_ID" ]; then
  AVAILABLE=$(jq -r '.data.repositoryOwner.projectV2.field.options | map(.name) | join(", ")' <<<"$PROJECT_JSON")
  echo "::error::Status option '$STATUS' not found. Available: $AVAILABLE" >&2
  exit 1
fi

ISSUE_NODE=$(gh api "repos/$REPO/issues/$ISSUE" --jq .node_id)

ITEM_ID=$(gh api graphql -f project="$PROJECT_ID" -f content="$ISSUE_NODE" -f query='
  mutation($project:ID!,$content:ID!){
    addProjectV2ItemById(input:{projectId:$project,contentId:$content}){ item{ id } }
  }' --jq .data.addProjectV2ItemById.item.id)

gh api graphql -f project="$PROJECT_ID" -f item="$ITEM_ID" -f field="$FIELD_ID" -f option="$OPTION_ID" -f query='
  mutation($project:ID!,$item:ID!,$field:ID!,$option:String!){
    updateProjectV2ItemFieldValue(input:{
      projectId:$project,itemId:$item,fieldId:$field,value:{singleSelectOptionId:$option}
    }){ projectV2Item{ id } }
  }' >/dev/null
echo "Project $PROJECT_OWNER/$PROJECT_NUMBER: issue #$ISSUE -> Status '$STATUS'"