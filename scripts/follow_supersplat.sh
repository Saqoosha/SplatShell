#!/usr/bin/env bash
set -euo pipefail

# Propose the latest SuperSplat release: when it is newer than the commit
# pinned in scripts/bundle.sh, move the pin there, run the full build (patches,
# SuperSplat, Swift) and open a pull request that reports how the build went.
# Publishing stays manual: review the PR, merge, then /release on a Mac.
#
#   TAG=<tag>   propose this release instead of the latest
#   FORCE=1     propose it even when it is not newer than the pin
#   DRY_RUN=1   move the pin and build, but do not commit, push or open a PR
#               (the pin is left changed in the working tree)
#
# Run daily by .github/workflows/follow-supersplat.yml. Needs gh, logged in.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="playcanvas/supersplat"
BUNDLE="${ROOT_DIR}/scripts/bundle.sh"
cd "$ROOT_DIR"

output() {
  echo "$1"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$1" >> "$GITHUB_OUTPUT"; fi
}

current=$(sed -n 's/^SUPERSPLAT_COMMIT="\([0-9a-f]*\)"$/\1/p' "$BUNDLE")
if [[ -z "$current" ]]; then
  echo "Error: no SUPERSPLAT_COMMIT line in $BUNDLE" >&2
  exit 1
fi

tag="${TAG:-$(gh release view -R "$UPSTREAM" --json tagName --jq .tagName)}"
# the tag ends up in an API path, a branch name and the PR text
if ! [[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Error: unexpected tag name: $tag" >&2
  exit 1
fi
sha=$(gh api "repos/${UPSTREAM}/commits/${tag}" --jq .sha)
if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Error: could not resolve ${tag} to a commit" >&2
  exit 1
fi
# 'ahead' means the release has commits the pin lacks. The pin may itself be
# ahead of the latest release (a fix taken from main), which is not a reason
# to move back.
status=$(gh api "repos/${UPSTREAM}/compare/${current}...${sha}" --jq .status)
echo "pinned ${current:0:7}, ${tag} is ${sha:0:7} (${status} of the pin)"

if [[ "$status" != "ahead" && -z "${FORCE:-}" ]]; then
  output "proposed=false"
  exit 0
fi

branch="supersplat/${tag}"
if [[ -z "${DRY_RUN:-}" ]] && git ls-remote --exit-code --heads origin "$branch" >/dev/null; then
  echo "${branch} already exists; leaving the open proposal alone"
  output "proposed=false"
  exit 0
fi

sed -i '' "s/^SUPERSPLAT_COMMIT=\"[0-9a-f]*\"$/SUPERSPLAT_COMMIT=\"${sha}\"/" "$BUNDLE"

log=$(mktemp)
if ./scripts/bundle.sh > "$log" 2>&1; then
  result="passed"
else
  result="failed"
fi
echo "build ${result}"
tail -40 "$log"

if [[ -n "${DRY_RUN:-}" ]]; then
  rm -f "$log"
  output "proposed=false"
  exit 0
fi

title="Update SuperSplat to ${tag}"
if [[ "$result" == "failed" ]]; then title="${title} (build failed)"; fi

body=$(cat <<EOF
SuperSplat [${tag}](https://github.com/${UPSTREAM}/releases/tag/${tag}) is out. This moves the pin in \`scripts/bundle.sh\` from \`${current:0:7}\` to \`${sha:0:7}\` ([changes](https://github.com/${UPSTREAM}/compare/${current}...${sha})).

**Build ${result}** on the runner: patches applied to SuperSplat, SuperSplat built, app built and bundled (ad hoc signed).

<details><summary>Last lines of the build log</summary>

\`\`\`
$(tail -40 "$log")
\`\`\`

</details>

Before merging, open a large scene in the bundled app and fly around: the runner cannot render. Then \`/release\` on a Mac (a new SuperSplat version is a minor version bump).
EOF
)
rm -f "$log"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git switch -c "$branch"
git add "$BUNDLE"
git commit -m "Update SuperSplat to ${tag}

- Pin SuperSplat ${sha:0:7}, the ${tag} release
- Build ${result} on the follow-supersplat workflow"
git push origin "$branch"
gh pr create --base main --head "$branch" --title "$title" --body "$body"
output "proposed=true"
