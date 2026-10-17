#!/usr/bin/env bash
# Cut a new dude release in one command.
#
#   ./scripts/release.sh <version> [notes-file]
#   ./scripts/release.sh 1.2
#   ./scripts/release.sh 1.2 notes.md
#
# It will: bump the version in project.yml, regenerate the Xcode project, build
# a Release app, package Dude.dmg, commit + push the bump, and publish a GitHub
# release (tag vX.Y) with the DMG attached.
#
# Prereqs (one-time):
#   brew install xcodegen create-dmg
#   gh auth login
#   Xcode installed at /Applications/Xcode.app
set -euo pipefail

# ---- args ----
#   --dry-run : run preflight + show the plan, change nothing, publish nothing
#   -y/--yes  : skip the confirmation prompt (for CI / when you're sure)
DRY=0; ASSUME_YES=0; POS=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    -y|--yes)  ASSUME_YES=1 ;;
    -*) echo "unknown flag: $a" >&2; exit 2 ;;
    *) POS+=("$a") ;;
  esac
done
if [ "${#POS[@]}" -lt 1 ]; then
  echo "usage: $0 [--dry-run] [-y] <version> [notes-file]   e.g. $0 1.2" >&2
  exit 2
fi
VERSION="${POS[0]}"
NOTES_FILE="${POS[1]:-}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "✖ version must look like 1.2 or 1.2.3 (got '$VERSION')" >&2
  exit 2
fi
TAG="v$VERSION"

cd "$(dirname "$0")/.."   # repo root
ROOT="$PWD"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

step() { printf "\n\033[1;32m▸ %s\033[0m\n" "$1"; }
die()  { printf "\033[1;31m✖ %s\033[0m\n" "$1" >&2; exit 1; }

# ---- preflight ----
step "Preflight"
for tool in xcodegen create-dmg gh git; do
  command -v "$tool" >/dev/null || die "missing '$tool' (see prereqs at the top of this script)"
done
[ -d "$DEVELOPER_DIR" ] || die "Xcode not found at $DEVELOPER_DIR (set DEVELOPER_DIR)"
gh auth status >/dev/null 2>&1 || die "not logged in to GitHub — run: gh auth login"

# Must be on a clean tree so the tag matches exactly what we ship.
[ -z "$(git status --porcelain --untracked-files=no)" ] || \
  die "you have uncommitted changes — commit or stash them first, then re-run."

# Don't clobber an existing release.
if gh release view "$TAG" >/dev/null 2>&1; then die "release $TAG already exists."; fi
git rev-parse "$TAG" >/dev/null 2>&1 && die "tag $TAG already exists."

CURRENT="$(grep -E 'MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
echo "  $CURRENT  →  $VERSION"

# Collect changelog (commits since the last tag) BEFORE we add the release commit.
LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [ -n "$LAST_TAG" ]; then
  CHANGES="$(git log --no-merges --pretty='- %s' "$LAST_TAG"..HEAD)"
else
  CHANGES="$(git log --no-merges --pretty='- %s')"
fi
[ -n "$CHANGES" ] || CHANGES="- Maintenance and fixes."

# ---- plan / confirm ----
step "Plan"
cat <<PLAN
  version:   $CURRENT  →  $VERSION   (tag $TAG)
  changes since ${LAST_TAG:-'(first tag)'}:
$(echo "$CHANGES" | sed 's/^/    /')
PLAN
if [ "$DRY" = 1 ]; then
  step "Dry run — nothing changed, nothing published."
  exit 0
fi
if [ "$ASSUME_YES" != 1 ]; then
  printf "\nPublish %s to GitHub now? [y/N] " "$TAG"
  read -r reply </dev/tty || reply=""
  case "$reply" in y|Y|yes|YES) ;; *) die "aborted — nothing changed." ;; esac
fi

# ---- bump version ----
step "Bumping version in project.yml"
BUILD_NUM="$(grep -E 'CURRENT_PROJECT_VERSION:' project.yml | head -1 | sed -E 's/[^0-9]//g')"
NEXT_BUILD=$(( ${BUILD_NUM:-0} + 1 ))
sed -i '' -E "s/(MARKETING_VERSION:) \"[^\"]*\"/\1 \"$VERSION\"/" project.yml
sed -i '' -E "s/(CURRENT_PROJECT_VERSION:) \"[^\"]*\"/\1 \"$NEXT_BUILD\"/" project.yml

step "Regenerating Xcode project"
xcodegen generate >/dev/null

# ---- build ----
step "Building Release app"
xcodebuild -project Dude.xcodeproj -scheme Dude -configuration Release build >/tmp/dude-release-build.log 2>&1 \
  || { tail -30 /tmp/dude-release-build.log; die "Release build failed (full log: /tmp/dude-release-build.log)"; }

# ---- package ----
step "Building Dude.dmg"
rm -f "$ROOT/Dude.dmg"
./scripts/make-dmg.sh >/tmp/dude-dmg.log 2>&1 || true
if [ ! -f "$ROOT/Dude.dmg" ]; then
  echo "  first DMG attempt failed (Finder styling is flaky) — retrying once…"
  for d in $(mount | grep -o '/Volumes/dmg\.[^ ]*' || true); do diskutil eject "$d" >/dev/null 2>&1 || true; done
  ./scripts/make-dmg.sh >/tmp/dude-dmg.log 2>&1 || true
fi
[ -f "$ROOT/Dude.dmg" ] || { tail -20 /tmp/dude-dmg.log; die "DMG build failed (full log: /tmp/dude-dmg.log)"; }

# ---- commit + tag + release ----
step "Committing version bump"
git add project.yml
git commit -q -m "Release $TAG"
git push -q origin HEAD

step "Publishing GitHub release $TAG"
if [ -n "$NOTES_FILE" ]; then
  [ -f "$NOTES_FILE" ] || die "notes file '$NOTES_FILE' not found"
  NOTES_ARG=(--notes-file "$NOTES_FILE")
else
  TMP_NOTES="$(mktemp)"
  cat > "$TMP_NOTES" <<EOF
### Changes
$CHANGES

### Install
1. Download **Dude.dmg**, open it, and drag **dude** onto **Applications**.
2. If macOS says it's "damaged" or won't open (self-signed, not notarized):
   \`\`\`sh
   xattr -dr com.apple.quarantine /Applications/dude.app
   \`\`\`
3. dude lives in your **menu bar**. Add a free Gemini key via **Setup…** — grab one at https://aistudio.google.com/apikey
EOF
  NOTES_ARG=(--notes-file "$TMP_NOTES")
fi

gh release create "$TAG" "$ROOT/Dude.dmg" \
  --title "dude $VERSION" \
  --target main \
  "${NOTES_ARG[@]}"

step "Done"
echo "  Released $TAG"
echo "  $(gh release view "$TAG" --json url --jq .url)"
echo "  Download: https://github.com/JcakPhleps/dude/releases/latest"
