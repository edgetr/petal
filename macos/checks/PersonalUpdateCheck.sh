#!/usr/bin/env bash
# Checks where petal-personal takes a release's source from (macos/Resources/personal/petal-personal), on a throwaway
# source in the temporary folder and with a stand-in for curl that only writes down what it was asked for: nothing
# is downloaded, and nothing of the person's is read. An update given its release's commit (as Petal's updater gives
# it, read from the release it checked) asks for that commit's source and no other, never a tag and never an address
# made from the version's text; a version that isn't plain numbers, or a commit that isn't a whole one, asks for
# nothing at all; and the source must be the version asked for. Run with macos/checks/run.sh.
set -uo pipefail
script="$(cd "$(dirname "$0")/.." && pwd)/Resources/personal/petal-personal"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
expect() { if ! eval "$1"; then failures=$((failures + 1)); echo "FAIL: $2"; fi; }

# A release's source as a folder (what `--from` and a release dir take), and the same as GitHub's tarball would be.
release() {   # release <folder> <version>
    mkdir -p "$1/macos/Sources/Petal"
    printf '%s\n' "$2" > "$1/macos/VERSION"
    printf '// swift-tools-version: 6.2\n' > "$1/macos/Package.swift"
    printf 'let version = "%s"\n' "$2" > "$1/macos/Sources/Petal/main.swift"
}
release "$work/r1/petal" 2.1.3
release "$work/r2/petal" 2.1.4
release "$work/r3/petal" 2.1.9
tar -czf "$work/2.1.4.tar.gz" -C "$work/r2" petal
tar -czf "$work/2.1.9.tar.gz" -C "$work/r3" petal

# The stand-in for curl: one line per call with the address asked for; it hands over $FAKE_TARBALL when there is one.
mkdir -p "$work/bin"
cat > "$work/bin/curl" <<'EOF'
#!/bin/bash
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
        --retry) shift ;;
        -*) ;;
        *) url="$1" ;;
    esac
    shift
done
printf '%s\n' "$url" >> "$CURL_LOG"
[ -n "${FAKE_TARBALL:-}" ] && [ -n "$out" ] && cp "$FAKE_TARBALL" "$out" && exit 0
exit 22
EOF
chmod +x "$work/bin/curl"

export PETAL_PERSONAL_SOURCE="$work/source" PETAL_INSTALLED_VERSION=2.1.3 PETAL_SOURCE_COMMIT="" PETAL_AI=none
export CURL_LOG="$work/curl.log" PATH="$work/bin:$PATH" HOME="$work/home"
mkdir -p "$HOME"
personal() { python3 -I "$script" "$@" 2>&1; }
asked() { [ -f "$CURL_LOG" ] && cat "$CURL_LOG" || true; }
fresh() { rm -f "$CURL_LOG"; }

# The person's source, with a change of their own.
personal init --from "$work/r1/petal" > /dev/null
printf '// mine\n' > "$work/source/macos/Sources/Petal/Mine.swift"
personal save "A change of my own" > /dev/null
expect '[ "$(personal status --json | python3 -I -c "import json,sys; print(json.load(sys.stdin)[\"changes\"])")" = 1 ]' "the throwaway source has one change"

sha=0123456789abcdef0123456789abcdef01234567

# A version that isn't plain numbers asks GitHub for nothing, with a commit or without.
for version in "9.0/../../../../other/repo/archive/refs/tags/x" "2.1.4/" " 2.1.4" "v2.1.4" "2..4" "2.1.4-beta" "1234567.0" "1.2.3.4.5"; do
    fresh
    reply=$(personal update --version "$version" --commit "$sha" --json)
    expect '[ -z "$(asked)" ] && [[ "$reply" == *"\"status\": \"error\""* ]]' "a version of $version with a commit asks for nothing: $reply $(asked)"
    fresh
    reply=$(personal update --version "$version" --json)
    expect '[ -z "$(asked)" ] && [[ "$reply" == *"\"status\": \"error\""* ]]' "a version of $version asks for nothing: $reply $(asked)"
done

# A commit that isn't a whole one asks for nothing either: never the tag instead.
for commit in "" "main" "refs/tags/macos-v2.1.4" "${sha%?}" "${sha}0" "0123456789ABCDEF0123456789ABCDEF01234567" "0123456789abcdef/../../other/repo/archive/x"; do
    fresh
    reply=$(personal update --version 2.1.4 --commit "$commit" --json)
    expect '[ -z "$(asked)" ] && [[ "$reply" == *"\"status\": \"error\""* ]]' "a commit of '$commit' asks for nothing: $reply $(asked)"
done

# With its commit, an update asks for that commit's source, once, and nothing else when it can't be had.
fresh
reply=$(personal update --version 2.1.4 --commit "$sha" --json)
expect '[ "$(asked)" = "https://github.com/edgetr/petal/archive/$sha.tar.gz" ]' "an update asks only for its commit's source: $(asked)"
expect '[[ "$reply" == *"\"status\": \"error\""* ]]' "and says so when it can't be downloaded: $reply"

# The source must be the version asked for.
fresh
reply=$(FAKE_TARBALL="$work/2.1.9.tar.gz" personal update --version 2.1.4 --commit "$sha" --json)
expect '[[ "$reply" == *"\"status\": \"error\""* ]] && [ "$(personal status --json | python3 -I -c "import json,sys; print(json.load(sys.stdin)[\"version\"])")" = 2.1.3 ]' \
    "a source that is another version isn't used: $reply"

# And when it is, the person's change comes over to it.
fresh
reply=$(FAKE_TARBALL="$work/2.1.4.tar.gz" personal update --version 2.1.4 --commit "$sha" --json)
expect '[[ "$reply" == *"\"status\": \"updated\""* ]] && [ "$(asked)" = "https://github.com/edgetr/petal/archive/$sha.tar.gz" ]' "an update from its commit's source: $reply $(asked)"
expect 'grep -q "version = \"2.1.4\"" "$work/source/macos/Sources/Petal/main.swift" && grep -q "// mine" "$work/source/macos/Sources/Petal/Mine.swift"' \
    "the release and the person's change are both in the source"

# Without a commit (the installed version's own source, as before): the installed Petal's commit first, then its tag.
fresh
PETAL_INSTALLED_VERSION=2.1.5 PETAL_SOURCE_COMMIT="$sha" personal update --version 2.1.5 --json > /dev/null
expect '[ "$(asked)" = "https://github.com/edgetr/petal/archive/$sha.tar.gz
https://github.com/edgetr/petal/archive/refs/tags/macos-v2.1.5.tar.gz" ]' "the installed version's source: its own commit, then its tag: $(asked)"

if [ "$failures" -gt 0 ]; then echo "$failures personal update check(s) failed"; exit 1; fi
echo "personal update: all checks passed"
