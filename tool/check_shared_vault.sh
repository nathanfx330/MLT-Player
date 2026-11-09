#!/usr/bin/env bash
# tool/check_shared_vault.sh
# Verify that both desktop apps ship byte-identical vault implementations.
# When matching feature branches exist in both repos, compare those during
# PR review; otherwise compare against the other repository's main branch.
set -euo pipefail

other_repo="${1:?usage: bash tool/check_shared_vault.sh owner/other-repo}"
vault="lib/services/redleaf_shared_credential_vault.dart"
branch="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-main}}"

if [[ ! -f "$vault" ]]; then
  echo "::error::Missing shared vault implementation: $vault"
  exit 1
fi

other_copy="$(mktemp)"
trap 'rm -f "$other_copy"' EXIT

fetch_counterpart() {
  local ref="$1"
  curl --fail --silent --location --retry 2 --max-time 30 \
    "https://raw.githubusercontent.com/$other_repo/$ref/$vault" \
    --output "$other_copy"
}

if fetch_counterpart "$branch"; then
  echo "Comparing local shared vault against $other_repo ($branch)"
elif [[ "$branch" != "main" ]] && fetch_counterpart main; then
  echo "Matching branch not found. Comparing against $other_repo (main)"
else
  echo "::error::Cannot retrieve the counterpart shared vault from $other_repo"
  exit 1
fi

echo "Local and counterpart SHA256 digests:"
sha256sum "$vault" "$other_copy"

if ! cmp -s "$vault" "$other_copy"; then
  echo "::error::Shared Redleaf credential vault has drifted across apps."
  echo "::error::Apply the same source change to both repos on the same branch before merging."
  exit 1
fi

echo "Shared Redleaf credential vault parity verified."
