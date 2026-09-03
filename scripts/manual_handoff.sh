#!/usr/bin/env bash
set -euo pipefail

issue=${1:?usage: scripts/manual_handoff.sh SYM-NN [commit] [workspace]}
commit=${2:-}
workspace=${3:-${SYMPHONY_MANUAL_HANDOFF_WORKSPACE:-}}
branch=${SYMPHONY_MANUAL_HANDOFF_BRANCH:-vikingmew-${issue,,}}

if [[ -z "$workspace" ]]; then
  echo "MANUAL_HANDOFF_REQUIRED: set SYMPHONY_MANUAL_HANDOFF_WORKSPACE to the preserved worker workspace" >&2
  exit 2
fi
[[ -d "$workspace/.git" ]] || { echo "workspace is not a git checkout: $workspace" >&2; exit 2; }
cd "$workspace"
commit=${commit:-$(git rev-parse HEAD)}
git cat-file -e "$commit^{commit}"
if git branch -r --contains "$commit" | grep -q .; then
  echo "commit $commit is already pushed; refusing duplicate rescue"
  exit 0
fi
repo=$(git remote get-url origin)
git fetch origin main
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git format-patch -1 --stdout "$commit" > "$tmp/commit.patch"
git -C "$tmp" init -q
git -C "$tmp" fetch -q "$repo" main
git -C "$tmp" checkout -q -b "$branch" FETCH_HEAD
git -C "$tmp" am --3way "$tmp/commit.patch"
if gh pr view "$branch" --json url >/dev/null 2>&1; then
  echo "PR already exists for $branch; nothing to do"
  exit 0
fi
git -C "$tmp" push origin "HEAD:$branch"
body=$'#### Summary\n\n- Host-assisted rescue of a worker commit blocked by GitHub workflow scope.\n\n#### Test Plan\n\n- [ ] Reuse worker validation evidence; review CI checks.\n\nFixes '"$issue"
url=$(gh pr create --head "$branch" --base main --title "Manual handoff: $issue" --body "$body")
echo "Created $url; update Linear with host-assisted manual handoff for $issue"
