#!/usr/bin/env bash
set -euo pipefail

# Publishes the four jars of one SoftClient4ES product (one per Elasticsearch major) to
# GitHub Releases on this repository. Used by the release and snapshot workflows of the
# producer repositories, and runnable locally with an authenticated `gh`.
#
#   publish.sh release  <product> <version> <jar>...   immutable release, tag <product>-v<version>
#   publish.sh snapshot <product> <version> <jar>...   rolling pre-release, tag <product>-snapshot
#
# Products and the jar names they must carry (one per ES major 6, 7, 8 and 9):
#   cli      softclient4es<N>-cli-<version>-assembly.jar
#   cli-all  softclient4es<N>-cli-all-<version>-assembly.jar
#   jdbc     softclient4es<N>-jdbc-driver-<version>.jar
#   adbc     softclient4es<N>-adbc-driver-<version>.jar
#
# A release is never overwritten: publishing an existing version fails. Its assets are uploaded
# to a draft first and the release is made public only once every asset is verified, so a
# download never sees a half-published version.
#
# A snapshot release holds exactly one copy of each jar: the new jars are uploaded first, then
# the assets of the previous snapshot are deleted, so the snapshot is never empty.
#
# Every jar is accompanied by <jar>.sha256 (`shasum -a 256 -c <jar>.sha256` verifies it).
#
# Env:
#   GH_TOKEN        token with contents:write on the releases repository (CI); locally, the
#                   `gh auth login` session is used when unset
#   RELEASES_REPO   owner/repo of the releases repository
#                   (default: SOFTNETWORK-APP/softclient4es-releases)
#   SOURCE_REPO     provenance written into the release notes — named only when it is a public
#                   repository (PUBLIC_SOURCES below), a private one never is
#                   (default: $GITHUB_REPOSITORY, else the origin of the current git checkout)
#   SOURCE_SHA      (default: $GITHUB_SHA, else HEAD of the current git checkout)

REPO="${RELEASES_REPO:-SOFTNETWORK-APP/softclient4es-releases}"
# The source repositories the public release notes may name
PUBLIC_SOURCES="SOFTNETWORK-APP/SoftClient4ES"

die() { echo "Error: $*" >&2; exit 1; }

usage() {
  sed -n '4,15p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

[[ $# -ge 1 && ( "$1" == "-h" || "$1" == "--help" ) ]] && usage 0
[[ $# -ge 4 ]] || usage 1

MODE="$1"; PRODUCT="$2"; VERSION="$3"; shift 3
JARS=("$@")

command -v gh >/dev/null 2>&1 || die "the GitHub CLI (gh) is required"

case "$MODE" in
  release)
    [[ "$VERSION" != *SNAPSHOT* ]] || die "a release version cannot be a snapshot: $VERSION"
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "a release version must be X.Y.Z: $VERSION"
    TAG="$PRODUCT-v$VERSION"
    ;;
  snapshot)
    [[ "$VERSION" == *-SNAPSHOT ]] || die "a snapshot version must end with -SNAPSHOT: $VERSION"
    TAG="$PRODUCT-snapshot"
    ;;
  *) die "unknown mode '$MODE' (release | snapshot)" ;;
esac

# Every product but the plain engine embeds the extensions and the proprietary JOIN engine
MIXED_LICENCE="Apache-2.0 and Elastic License 2.0 components plus the proprietary JOIN engine (free to use)."
case "$PRODUCT" in
  cli)     LABEL="REPL (engine only)";                LICENCE="Apache-2.0.";     PATTERN='cli-%s-assembly\.jar' ;;
  cli-all) LABEL="REPL bundle (engine + extensions)"; LICENCE="$MIXED_LICENCE"; PATTERN='cli-all-%s-assembly\.jar' ;;
  jdbc)    LABEL="JDBC driver";                       LICENCE="$MIXED_LICENCE"; PATTERN='jdbc-driver-%s\.jar' ;;
  adbc)    LABEL="ADBC driver";                       LICENCE="$MIXED_LICENCE"; PATTERN='adbc-driver-%s\.jar' ;;
  *) die "unknown product '$PRODUCT' (cli | cli-all | jdbc | adbc)" ;;
esac

# --- validate the jars: exactly one per ES major 6..9, named for this product and version ---
VERSION_RE="${VERSION//./\\.}"
# shellcheck disable=SC2059
NAME_RE="^softclient4es([6-9])-$(printf "$PATTERN" "$VERSION_RE")\$"
SEEN=""
for jar in "${JARS[@]}"; do
  [[ -f "$jar" ]] || die "not a file: $jar"
  name="$(basename "$jar")"
  [[ "$name" =~ $NAME_RE ]] || die "unexpected jar name for $PRODUCT $VERSION: $name"
  major="${BASH_REMATCH[1]}"
  [[ "$SEEN" != *"$major"* ]] || die "two jars for ES $major"
  SEEN="$SEEN$major"
done
for major in 6 7 8 9; do
  [[ "$SEEN" == *"$major"* ]] || die "no jar for ES $major (expected one per ES major 6, 7, 8 and 9)"
done

# --- checksums, next to copies of the jars, in a scratch directory ---
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi
}
FILES=()
for jar in "${JARS[@]}"; do
  name="$(basename "$jar")"
  cp "$jar" "$WORK/$name"
  (cd "$WORK" && sha256 "$name" > "$name.sha256")
  FILES+=("$WORK/$name" "$WORK/$name.sha256")
done

# --- provenance ---
if [[ -z "${SOURCE_REPO:-}" ]]; then
  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    SOURCE_REPO="$GITHUB_REPOSITORY"
  else
    SOURCE_REPO="$(git remote get-url origin 2>/dev/null | sed -E 's#.*github\.com[:/]##; s#\.git$##' || true)"
  fi
fi
if [[ -z "${SOURCE_SHA:-}" ]]; then
  SOURCE_SHA="${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || true)}"
fi
if [[ -n "${SOURCE_REPO:-}" && " $PUBLIC_SOURCES " == *" $SOURCE_REPO "* ]]; then
  PROVENANCE="Built from $SOURCE_REPO@${SOURCE_SHA:-unknown}."
else
  PROVENANCE="Build: ${SOURCE_SHA:-unknown}."
fi
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- helpers on the releases repository ---
# Prints "release", "prerelease", "draft" or nothing, for the releases whose tag is $1. A
# published release wins over any draft of the same tag (an interrupted or concurrent run).
release_state() {
  local states
  states="$(gh release list --repo "$REPO" --limit 1000 --json tagName,isDraft,isPrerelease \
    -q ".[] | select(.tagName == \"$1\") | if .isDraft then \"draft\" elif .isPrerelease then \"prerelease\" else \"release\" end")"
  if grep -qx release <<< "$states"; then echo release
  elif grep -qx prerelease <<< "$states"; then echo prerelease
  elif grep -qx draft <<< "$states"; then echo draft
  fi
}

# Fails unless every local file is an asset of release $1 with the same size.
verify_assets() {
  local tag="$1" remote f name size
  remote="$(gh release view "$tag" --repo "$REPO" --json assets -q '.assets[] | "\(.name) \(.size)"')"
  for f in "${FILES[@]}"; do
    name="$(basename "$f")"
    size="$(wc -c < "$f" | tr -d ' ')"
    grep -qxF "$name $size" <<< "$remote" || die "asset $name ($size bytes) missing or truncated on $tag"
  done
}

if [[ "$MODE" == "release" ]]; then
  while :; do
    case "$(release_state "$TAG")" in
      release|prerelease) die "$TAG is already published: a release is never republished" ;;
      draft)
        # A draft is never visible to users: it is what an interrupted earlier run left behind.
        echo "Removing the unpublished draft left by an earlier run: $TAG"
        gh release delete "$TAG" --repo "$REPO" --yes
        ;;
      *) break ;;
    esac
  done

  NOTES="SoftClient4ES $LABEL $VERSION, one jar per Elasticsearch major (6, 7, 8, 9).

Licence: $LICENCE

$PROVENANCE

Verify a download with \`shasum -a 256 -c <jar>.sha256\`."

  echo "Uploading $TAG to $REPO (draft)"
  gh release create "$TAG" "${FILES[@]}" --repo "$REPO" --draft \
    --title "$PRODUCT $VERSION" --notes "$NOTES"
  verify_assets "$TAG"
  gh release edit "$TAG" --repo "$REPO" --draft=false
  verify_assets "$TAG"
  echo "Published $TAG: https://github.com/$REPO/releases/tag/$TAG"
else
  NOTES="Rolling snapshot of the SoftClient4ES $LABEL, one jar per Elasticsearch major (6, 7, 8, 9).
Its jars are replaced on every snapshot publish: not for production.

Licence: $LICENCE

Current: $VERSION, published $NOW. $PROVENANCE

Verify a download with \`shasum -a 256 -c <jar>.sha256\`."

  state="$(release_state "$TAG")"
  case "$state" in
    "")
      echo "Creating the rolling pre-release $TAG"
      gh release create "$TAG" --repo "$REPO" --prerelease --title "$PRODUCT snapshot" --notes "$NOTES"
      ;;
    prerelease) ;;
    *) die "$TAG exists but is not a pre-release ($state): refusing to touch it" ;;
  esac

  echo "Uploading $VERSION to $TAG"
  gh release upload "$TAG" "${FILES[@]}" --repo "$REPO" --clobber
  verify_assets "$TAG"

  KEEP=" "
  for f in "${FILES[@]}"; do KEEP="$KEEP$(basename "$f") "; done
  while IFS= read -r name; do
    [[ -z "$name" || "$KEEP" == *" $name "* ]] && continue
    echo "Deleting the previous snapshot asset $name"
    gh release delete-asset "$TAG" "$name" --repo "$REPO" --yes
  done < <(gh release view "$TAG" --repo "$REPO" --json assets -q '.assets[].name')

  gh release edit "$TAG" --repo "$REPO" --notes "$NOTES"
  echo "Published $VERSION to https://github.com/$REPO/releases/tag/$TAG"
fi
