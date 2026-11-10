#!/usr/bin/env bash
# tool/check_shared_vault.sh
# Protect the byte-identical shared credential vault contract.
#
# Pull requests: strict parity against the matching branch in the other repo,
# falling back to its main when no matching branch exists.
# Main pushes: advisory because cross-repository merges are not atomic.
# Scheduled checks: strict against the other repository's main to catch drift.
#
# Resolve the branch via git first and fetch immutable commit content so that
# raw.githubusercontent.com's branch-ref cache cannot yield stale file bytes.
set -euo pipefail

other_repo="${1:?usage: bash tool/check_shared_vault.sh owner/other-repo [strict|advisory]}"
mode="${2:-strict}"
vault="lib/services/redleaf_shared_credential_vault.dart"
branch="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-main}}"

if [[ "$mode" != "strict" && "$mode" != "advisory" ]]; then
  echo "::error::Invalid vault parity mode: $mode"
  exit 2
fi

if [[ ! -f "$vault" ]]; then
  echo "::error::Missing local vault implementation: $vault"
  exit 1
fi

other_copy="$(mktemp)"
trap 'rm -f "$other_copy"' EXIT

report_issue() {
  local message="$1"
  if [[ "$mode" == "advisory" ]]; then
    echo "::warning::$message"
  else
    echo "::error::$message"
    return 1
  fi
}

resolve_branch_sha() {
  local ref="$1"
  local sha
  sha="$(git ls-remote --exit-code --heads \
    "https://github.com/$other_repo.git" "refs/heads/$ref" | \
    awk 'NR == 1 { print $1 }')" || return 1
  if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    return 1
  fi
  printf '%s\n' "$sha"
}

selected_ref="$branch"
if sha="$(resolve_branch_sha "$selected_ref")"; then
  :
elif [[ "$selected_ref" != "main" ]] && sha="$(resolve_branch_sha main)"; then
  selected_ref="main"
else
  report_issue "Cannot resolve counterpart branch in $other_repo."
  exit 0
fi

if ! curl --fail --silent --show-error --location \
  --retry 3 --retry-all-errors --retry-delay 2 --max-time 60 \
  "https://raw.githubusercontent.com/$other_repo/$sha/$vault" \
  --output "$other_copy"; then
  report_issue "Cannot fetch immutable vault content from $other_repo at $sha."
  exit 0
fi

echo "Counterpart: $other_repo ($selected_ref at $sha)"
echo "Local and counterpart SHA256:"
sha256sum "$vault" "$other_copy"

if ! cmp -s "$vault" "$other_copy"; then
  report_issue "Shared Redleaf credential vault differs from $other_repo ($selected_ref at $sha). Keep both source files synchronized."
  exit 0
fi

echo "Shared Redleaf credential vault parity verified."
