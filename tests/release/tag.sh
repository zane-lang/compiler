#!/usr/bin/env bash
# Real Git tags, offline GitHub responses: exercise recovery without publishing.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/repo"
export ZANE_TEST_RELEASES="$scratch/releases"
export ZANE_TEST_CREATIONS="$scratch/creations"
export ZANE_TEST_API_FAILURE='' ZANE_TEST_CREATE_FAILURE=''
export GH_REPO=zane-lang/compiler VERSION=v0.0
touch "$ZANE_TEST_RELEASES" "$ZANE_TEST_CREATIONS"
cat > "$scratch/bin/gh" <<'SH'
#!/bin/sh
set -eu
[ -z "$ZANE_TEST_API_FAILURE" ] || exit 25
if [ "$*" = "api --paginate repos/$GH_REPO/releases?per_page=100 --jq .[].tag_name" ]; then
    cat "$ZANE_TEST_RELEASES"
elif [ "$*" = "api --method POST repos/$GH_REPO/git/refs --silent -f ref=refs/tags/$VERSION -f sha=$SOURCE_SHA" ]; then
    [ -z "$ZANE_TEST_CREATE_FAILURE" ] || exit 26
    printf '%s\n' "$VERSION" >> "$ZANE_TEST_CREATIONS"
    git tag "$VERSION" "$SOURCE_SHA"
else
    echo "Unexpected gh arguments: $*" >&2
    exit 1
fi
SH
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH"
cd "$scratch/repo"
git init --quiet
git config user.name Test
git config user.email test@example.invalid
git commit --quiet --allow-empty -m 'release source'
git remote add origin "$scratch/repo"
export SOURCE_SHA
SOURCE_SHA=$(git rev-parse HEAD)
original=$SOURCE_SHA

expect_failure() {
    if bash "$root/.github/scripts/release-tag" "$@" > "$scratch/output" 2>&1; then
        echo "Release tag check unexpectedly succeeded: $*" >&2
        exit 1
    fi
}

# Preflight is read-only; publish creates the absent tag exactly once.
bash "$root/.github/scripts/release-tag" check
test ! -s "$ZANE_TEST_CREATIONS"
bash "$root/.github/scripts/release-tag" create
test "$(git rev-parse refs/tags/v0.0)" = "$original"
test "$(wc -l < "$ZANE_TEST_CREATIONS" | tr -d ' ')" = 1
# Simulate failure before a release was created: both retry phases reuse the tag.
bash "$root/.github/scripts/release-tag" check
bash "$root/.github/scripts/release-tag" create
test "$(wc -l < "$ZANE_TEST_CREATIONS" | tr -d ' ')" = 1
# Listing includes all release tags, including drafts visible to publish's token.
printf 'v0.0\n' > "$ZANE_TEST_RELEASES"
expect_failure check
expect_failure create
: > "$ZANE_TEST_RELEASES"
git commit --quiet --allow-empty -m 'different source'
SOURCE_SHA=$(git rev-parse HEAD)
expect_failure check
expect_failure create
test "$(git rev-parse refs/tags/v0.0)" = "$original"
# Annotated tags must compare their peeled commit, not their tag-object hash.
VERSION=v0.1
git tag -a "$VERSION" "$SOURCE_SHA" -m 'annotated release'
bash "$root/.github/scripts/release-tag" check
bash "$root/.github/scripts/release-tag" create
SOURCE_SHA=$original
expect_failure create
# Network/auth errors cannot be treated as absence, nor can an atomic create fail.
VERSION=v0.2
export ZANE_TEST_API_FAILURE=yes
expect_failure check
expect_failure create
export ZANE_TEST_API_FAILURE='' ZANE_TEST_CREATE_FAILURE=yes
expect_failure create
test "$(wc -l < "$ZANE_TEST_CREATIONS" | tr -d ' ')" = 1
export ZANE_TEST_CREATE_FAILURE=
for invalid in 'v01.0' 'v0.1.0' '../v0.1' 'v0.1;echo bad'; do
    VERSION=$invalid
    expect_failure create
done
VERSION=v0.2
git remote set-url origin "$scratch/missing"
expect_failure create
test "$(wc -l < "$ZANE_TEST_CREATIONS" | tr -d ' ')" = 1
echo 'Release tag recovery tests passed'
