#!/usr/bin/env bash
set -euo pipefail

# Deletes from JFrog the fat jars of one SoftClient4ES product that GitHub Releases now serves.
#
#   jfrog-delete.sh plan   <product> <version>...   check every version, list what would be deleted
#   jfrog-delete.sh delete <product> <version>...   check again, delete, verify, purge the trash can
#
# Products and the JFrog modules of one version (one per ES major):
#   cli      softclient4es<N>-cli_2.13 and softclient4es<N>-cli_2.12
#   cli-all  softclient4es<N>-cli-all_2.13 and softclient4es<N>-cli-all_2.12
#   jdbc     softclient4es<N>-jdbc-driver
#   adbc     softclient4es<N>-adbc-driver
#
# A release version (X.Y.Z) is deleted from libs-release-local only when it has been copied: for
# every ES major, the GitHub release <product>-v<version> carries the jar's .sha256 and, when JFrog
# still holds the jar, the two sha256 agree. Scala 2.12 builds are dropped, so their folders go with
# their version. A snapshot version (...-SNAPSHOT) is deleted from libs-snapshot-local: the rolling
# <product>-snapshot pre-releases superseded it.
#
# Every version is checked before anything is deleted: one failed check deletes nothing. A deleted
# folder must hold no file afterwards (JFrog may re-create a deleted version folder EMPTY), then it
# is purged from the trash can (JFrog keeps deleted files there, still billed, until its retention
# expires). An empty folder left by an earlier deletion is deleted and purged again, so a rerun
# also empties the trash of a run that stopped before purging.
#
# Env:
#   JFROG_TOKEN     access token with delete permission on both repositories (delete only; plan
#                   reads anonymously)
#   JFROG_URL       default https://softnetwork.jfrog.io/artifactory
#   RELEASES_REPO   default SOFTNETWORK-APP/softclient4es-releases
#   RELEASES_DOWNLOAD_URL  default https://github.com/$RELEASES_REPO/releases/download

JFROG_URL="${JFROG_URL:-https://softnetwork.jfrog.io/artifactory}"
RELEASES_REPO="${RELEASES_REPO:-SOFTNETWORK-APP/softclient4es-releases}"
RELEASES_DOWNLOAD_URL="${RELEASES_DOWNLOAD_URL:-https://github.com/$RELEASES_REPO/releases/download}"
GROUP_PATH="app/softnetwork/elastic"

die() { echo "Error: $*" >&2; exit 1; }

usage() {
  sed -n '4,9p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

[[ $# -ge 1 && ( "$1" == "-h" || "$1" == "--help" ) ]] && usage 0
[[ $# -ge 3 ]] || usage 1

MODE="$1"; PRODUCT="$2"; shift 2
VERSIONS=("$@")

case "$MODE" in
  plan) ;;
  delete) [[ -n "${JFROG_TOKEN:-}" ]] || die "JFROG_TOKEN is required to delete" ;;
  *) die "unknown mode '$MODE' (plan | delete)" ;;
esac
case "$PRODUCT" in
  cli|cli-all|jdbc|adbc) ;;
  *) die "unknown product '$PRODUCT' (cli | cli-all | jdbc | adbc)" ;;
esac

SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
say() { echo "$*"; echo "$*" >> "$SUMMARY"; }

# curl against JFrog: authenticated when a token is set, anonymous otherwise
jfrog() {
  if [[ -n "${JFROG_TOKEN:-}" ]]; then
    curl -sS -H "Authorization: Bearer $JFROG_TOKEN" "$@"
  else
    curl -sS "$@"
  fi
}

# Prints "<name> <size> <sha256>" for each file of a JFrog folder; nothing when it is absent.
folder_files() {
  local repo="$1" path="$2" body code
  body="$(jfrog -w '\n%{http_code}' "$JFROG_URL/api/storage/$repo/$path")"
  code="${body##*$'\n'}"
  body="${body%$'\n'*}"
  case "$code" in
    404) return 0 ;;
    200) ;;
    *) die "JFrog answered HTTP $code for $repo/$path" ;;
  esac
  local name
  for name in $(python3 -c 'import sys,json
for c in json.loads(sys.argv[1]).get("children",[]):
    if not c["folder"]: print(c["uri"].strip("/"))' "$body"); do
    jfrog "$JFROG_URL/api/storage/$repo/$path/$name" | python3 -c 'import sys,json
d=json.load(sys.stdin); print(sys.argv[1], d.get("size",0), d.get("checksums",{}).get("sha256",""))' "$name"
  done
}

# HTTP status of a JFrog folder: 200 present (possibly empty), 404 absent.
folder_status() {
  jfrog -o /dev/null -w '%{http_code}' "$JFROG_URL/api/storage/$1/$2"
}

# The JFrog modules of one product for ES major $1, the copied (GitHub) one first.
modules_of() {
  case "$PRODUCT" in
    cli)     echo "softclient4es$1-cli_2.13 softclient4es$1-cli_2.12" ;;
    cli-all) echo "softclient4es$1-cli-all_2.13 softclient4es$1-cli-all_2.12" ;;
    jdbc)    echo "softclient4es$1-jdbc-driver" ;;
    adbc)    echo "softclient4es$1-adbc-driver" ;;
  esac
}

# "<JFrog jar name> <GitHub asset name>" of the copied jar of ES major $1, version $2.
copied_jar() {
  case "$PRODUCT" in
    cli)     echo "softclient4es$1-cli_2.13-$2-assembly.jar softclient4es$1-cli-$2-assembly.jar" ;;
    cli-all) echo "softclient4es$1-cli-all_2.13-$2-assembly.jar softclient4es$1-cli-all-$2-assembly.jar" ;;
    jdbc)    echo "softclient4es$1-jdbc-driver-$2.jar softclient4es$1-jdbc-driver-$2.jar" ;;
    adbc)    echo "softclient4es$1-adbc-driver-$2.jar softclient4es$1-adbc-driver-$2.jar" ;;
  esac
}

# --- check every version; collect the folders to delete as "<repo> <path> <bytes>" ---
TARGETS=()
TOTAL=0
say "### JFrog cleanup — $PRODUCT ($MODE)"
for version in "${VERSIONS[@]}"; do
  [[ "$version" =~ ^[0-9]+(\.[0-9]+){1,3}(-SNAPSHOT)?$ ]] || die "not a version: '$version'"
  if [[ "$version" == *-SNAPSHOT ]]; then
    repo="libs-snapshot-local"
  else
    repo="libs-release-local"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$PRODUCT $version: a release on GitHub is X.Y.Z, so this one was never copied"
    tag="$PRODUCT-v$version"
    for major in 6 7 8 9; do
      read -r jfrog_jar github_jar <<< "$(copied_jar "$major" "$version")"
      expected="$(curl -fsSL "$RELEASES_DOWNLOAD_URL/$tag/$github_jar.sha256" 2>/dev/null | cut -d' ' -f1)" ||
        expected=""
      [[ -n "$expected" ]] || die "$PRODUCT $version: no GitHub copy ($tag/$github_jar.sha256 not found) — nothing deleted"
      module="$(modules_of "$major" | cut -d' ' -f1)"
      actual="$(folder_files "$repo" "$GROUP_PATH/$module/$version" | awk -v n="$jfrog_jar" '$1 == n { print $3 }')"
      if [[ -n "$actual" && "$actual" != "$expected" ]]; then
        die "$PRODUCT $version: $jfrog_jar on JFrog ($actual) differs from its GitHub copy ($expected) — nothing deleted"
      fi
    done
  fi

  for major in 6 7 8 9; do
    for module in $(modules_of "$major"); do
      path="$GROUP_PATH/$module/$version"
      listing="$(folder_files "$repo" "$path")"
      if [[ -z "$listing" ]]; then
        # An empty folder is what a deletion leaves when JFrog re-creates the version folder: its
        # files may still be in the trash can, so it is deleted and purged again
        if [[ "$(folder_status "$repo" "$path")" == 200 ]]; then
          TARGETS+=("$repo $path 0")
          say "- \`$repo/$path\` — empty folder left by an earlier deletion (trash can purged again)"
        fi
        continue
      fi
      bytes="$(awk '{ s += $2 } END { print s + 0 }' <<< "$listing")"
      files="$(wc -l <<< "$listing" | tr -d ' ')"
      TARGETS+=("$repo $path $bytes")
      TOTAL=$((TOTAL + bytes))
      say "- \`$repo/$path\` — $files files, $((bytes / 1000000)) MB"
    done
  done
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  say "Nothing on JFrog for $PRODUCT ${VERSIONS[*]}."
  exit 0
fi
say "**${#TARGETS[@]} folders, $((TOTAL / 1000000)) MB.**"

if [[ "$MODE" == "plan" ]]; then
  say "Plan only: nothing deleted."
  exit 0
fi

# --- delete, verify, purge ---
failed=0
for target in "${TARGETS[@]}"; do
  read -r repo path _ <<< "$target"
  code="$(jfrog -o /dev/null -w '%{http_code}' -X DELETE "$JFROG_URL/$repo/$path")"
  if [[ "$code" != "204" && "$code" != "404" ]]; then
    say "- FAILED to delete \`$repo/$path\` (HTTP $code)"
    failed=1
    continue
  fi
  # Deleted = absent, or present but EMPTY: JFrog may re-create a deleted version folder empty
  if ! remaining="$(folder_files "$repo" "$path")"; then
    say "- deleted \`$repo/$path\`, but could not check it afterwards"
    failed=1
    continue
  fi
  if [[ -n "$remaining" ]]; then
    say "- \`$repo/$path\` still holds files after its deletion"
    failed=1
    continue
  fi
  code="$(jfrog -o /dev/null -w '%{http_code}' -X DELETE "$JFROG_URL/api/trash/clean/$repo/$path")"
  case "$code" in
    204) say "- deleted and purged \`$repo/$path\`" ;;
    404) say "- deleted \`$repo/$path\` (not in the trash can)" ;;
    *)   say "- deleted \`$repo/$path\`, but purging it from the trash can FAILED (HTTP $code)"; failed=1 ;;
  esac
done

[[ "$failed" -eq 0 ]] || die "some folders were not deleted or purged (see above)"
say "Done: $((TOTAL / 1000000)) MB deleted."
