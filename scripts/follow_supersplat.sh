#!/usr/bin/env bash
set -euo pipefail

# Propose the latest SuperSplat release: when it is newer than the commit
# pinned in scripts/bundle.sh, move the pin there, run the full build (patches,
# SuperSplat, Swift) and open a pull request that reports how the build went.
# Publishing stays manual: review the PR, merge, then /release on a Mac.
#
# The work is split so that SuperSplat's code and its npm dependencies never
# run next to a token that can write to this repository:
#
#   check     decide whether to propose. Prints tag=, sha=, current=,
#             branch=, propose= (also to $GITHUB_OUTPUT)
#   build     move the pin to $SHA and run bundle.sh. Writes the result to
#             $OUT_DIR/result and the log to $OUT_DIR/build.log. Run with no
#             credentials.
#   propose   move the pin to $SHA, commit, push $BRANCH and open the PR, with
#             the result from $OUT_DIR. Runs nothing from SuperSplat.
#
# The workflow runs each step in its own job. Locally, with no command, it
# runs check and build and leaves the pin moved in the working tree:
#
#   ./scripts/follow_supersplat.sh                    # nothing to do unless a newer release exists
#   TAG=v3.7.0 FORCE=1 ./scripts/follow_supersplat.sh # try any release
#
#   TAG=<tag>   propose this release instead of the latest
#   FORCE=1     propose it even when it is not newer than the pin

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="playcanvas/supersplat"
BUNDLE="${ROOT_DIR}/scripts/bundle.sh"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/build/follow}"
cd "$ROOT_DIR"

output() {
  echo "$1"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$1" >> "$GITHUB_OUTPUT"; fi
}

pinned() {
  sed -n 's/^SUPERSPLAT_COMMIT="\([0-9a-f]*\)"$/\1/p' "$BUNDLE"
}

move_pin() {
  if ! [[ "$1" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Error: not a commit: $1" >&2
    exit 1
  fi
  sed -i '' "s/^SUPERSPLAT_COMMIT=\"[0-9a-f]*\"$/SUPERSPLAT_COMMIT=\"$1\"/" "$BUNDLE"
}

check() {
  local current tag sha status branch
  current=$(pinned)
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
  # 'ahead' means the release has commits the pin lacks. The pin may itself
  # be ahead of the latest release (a fix taken from main), which is not a
  # reason to move back.
  status=$(gh api "repos/${UPSTREAM}/compare/${current}...${sha}" --jq .status)
  branch="supersplat/${tag}"
  echo "pinned ${current:0:7}, ${tag} is ${sha:0:7} (${status} of the pin)"
  output "tag=${tag}"
  output "sha=${sha}"
  output "current=${current}"
  output "branch=${branch}"

  if [[ "$status" != "ahead" && -z "${FORCE:-}" ]]; then
    output "propose=false"
  elif git ls-remote --exit-code --heads origin "$branch" >/dev/null; then
    echo "${branch} already exists; leaving the open proposal alone"
    output "propose=false"
  else
    output "propose=true"
  fi
}

build() {
  move_pin "${SHA:?}"
  mkdir -p "$OUT_DIR"
  if ./scripts/bundle.sh > "$OUT_DIR/build.log" 2>&1; then
    echo passed > "$OUT_DIR/result"
  else
    echo failed > "$OUT_DIR/result"
  fi
  echo "build $(cat "$OUT_DIR/result")"
  tail -40 "$OUT_DIR/build.log"
}

propose() {
  local tag="${TAG:?}" sha="${SHA:?}" current="${CURRENT:?}" branch="${BRANCH:?}" result title body
  result=$(cat "$OUT_DIR/result" 2>/dev/null || echo "did not finish")
  case "$result" in passed | failed) ;; *) result="did not finish" ;; esac
  title="Update SuperSplat to ${tag}"
  if [[ "$result" != "passed" ]]; then title="${title} (build ${result})"; fi

  body=$(mktemp)
  {
    echo "SuperSplat [${tag}](https://github.com/${UPSTREAM}/releases/tag/${tag}) is out. This moves the pin in \`scripts/bundle.sh\` from \`${current:0:7}\` to \`${sha:0:7}\` ([changes](https://github.com/${UPSTREAM}/compare/${current}...${sha}))."
    echo
    echo "**Build ${result}** on the runner: patches applied to SuperSplat, SuperSplat built, app built and bundled (ad hoc signed)."
    echo
    echo "<details><summary>Last lines of the build log</summary>"
    echo
    echo '```'
    tail -40 "$OUT_DIR/build.log" 2>/dev/null | sed 's/```/` ` `/g' || true
    echo '```'
    echo
    echo "</details>"
    echo
    echo "Before merging, open a large scene in the bundled app and fly around: the runner cannot render. Then \`/release\` on a Mac (a new SuperSplat version is a minor version bump)."
  } > "$body"

  move_pin "$sha"
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git switch -c "$branch"
  git add "$BUNDLE"
  git commit -m "Update SuperSplat to ${tag}

- Pin SuperSplat ${sha:0:7}, the ${tag} release
- Build ${result} on the follow-supersplat workflow"
  git push origin "$branch"
  gh pr create --base main --head "$branch" --title "$title" --body-file "$body"
  rm -f "$body"
}

case "${1:-local}" in
  check) check ;;
  build) build ;;
  propose) propose ;;
  local)
    result=$(check)
    echo "$result"
    if grep -q '^propose=true$' <<< "$result"; then
      SHA=$(sed -n 's/^sha=//p' <<< "$result") build
    fi
    ;;
  *)
    echo "Usage: $0 [check|build|propose]" >&2
    exit 1
    ;;
esac
