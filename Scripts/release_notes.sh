#!/bin/sh
# Assemble the GitHub Release body for a tag (the release documentation).
# Runs in the public repository, whose history is one `sync:` commit per
# export:
#
#   1. the CHANGELOG.md section for the version — the user-facing notes,
#      written by the maintainers before the tag. `## 0.2.0` or
#      `## 0.2.0 — 2026-10-01` (or `## [0.2.0]`). A pre-release tag
#      (v0.2.0-rc.1) may use its own section, else the 0.2.0 one, else
#      `## Unreleased`. A release without a section is refused.
#   2. the sync commits since the previous `v*` tag, each with its body —
#      where the export credits outside contributors ("Includes #12 by
#      @someone");
#   3. the DMG's SHA-256 and the install note — the notarized one when
#      KVOICE_NOTARIZED=true (the release workflow passes the build job's
#      result), otherwise the "Open Anyway" note for a build signed with a
#      non-Apple identity.
#
# Usage: release_notes.sh <tag> [dmg-sha256-file] > notes.md
# Standard tools only (git, awk, sed).
set -eu
cd "$(dirname "$0")/.."

tag="${1:?usage: release_notes.sh <tag> [dmg-sha256-file]}"
sha_file="${2:-}"
version="${tag#v}"
changelog="${KVOICE_CHANGELOG:-CHANGELOG.md}"

[ -f "$changelog" ] || { echo "release_notes: no $changelog" >&2; exit 2; }
git rev-parse -q --verify "refs/tags/$tag" >/dev/null \
    || { echo "release_notes: no tag $tag in this clone (fetch tags: git fetch --tags)" >&2; exit 2; }

# section <heading-version>: the body of `## <v>` (optionally `[<v>]`, and
# optionally followed by a date), up to the next `## `.
section() {
    awk -v wanted="$1" '
        /^## / {
            if (keep) exit
            heading = substr($0, 4)
            sub(/^\[/, "", heading)
            split(heading, words, /[] \t]/)
            keep = (words[1] == wanted)
            next
        }
        keep { print }
    ' "$changelog" | sed -e '/./,$!d'
}

notes="$(section "$version")"
source_heading="$version"
case "$version" in
    *-*)
        if [ -z "$notes" ]; then
            notes="$(section "${version%%-*}")"
            source_heading="${version%%-*}"
        fi
        if [ -z "$notes" ]; then
            notes="$(section Unreleased)"
            source_heading="Unreleased"
        fi
        ;;
esac
if [ -z "$notes" ]; then
    echo "release_notes: $changelog has no '## $version' section. Rename '## Unreleased' to" >&2
    echo "  '## $version — <date>' in the development repository's Public/CHANGELOG.md, export," >&2
    echo "  push the sync commit, then tag it (the release documentation)." >&2
    exit 1
fi

previous_tag="$(git describe --tags --abbrev=0 --match 'v*' "${tag}^" 2>/dev/null || true)"
if [ -n "$previous_tag" ]; then
    range="${previous_tag}..${tag}"
else
    range="$tag"
fi

echo "## KVoice $version"
echo
if [ "$source_heading" != "$version" ]; then
    echo "_Pre-release. The notes below are the CHANGELOG's \"$source_heading\" section._"
    echo
fi
printf '%s\n' "$notes"
echo

echo "### Source"
echo
if [ -n "$previous_tag" ]; then
    echo "Synced from the development line since $previous_tag:"
else
    echo "Synced from the development line:"
fi
echo
# Subject, then any body lines (the contributor credits) indented under it.
git log --reverse --format='%h%x09%s%x09%b%x1e' "$range" | awk -v RS='\036' -F '\t' '
    NF >= 2 {
        sub(/^\n/, "", $1)
        printf "- %s (%s)\n", $2, $1
        body = $3
        for (i = 4; i <= NF; i++) body = body "\t" $i
        n = split(body, lines, "\n")
        for (i = 1; i <= n; i++) if (lines[i] != "") printf "  %s\n", lines[i]
    }
'
echo

echo "### Install"
echo
if [ -n "$sha_file" ] && [ -f "$sha_file" ]; then
    echo '```'
    cat "$sha_file"
    echo '```'
    echo
fi
if [ "${KVOICE_NOTARIZED:-false}" = "true" ]; then
    cat <<'EOF'
Open the DMG and drag **kvoice** to Applications. This build is signed with
an Apple Developer ID and notarized by Apple, so it opens without a
Gatekeeper warning. Grants for Accessibility and Microphone survive updates
signed with the same Developer ID. If a KVoice build signed with a different
certificate is installed, macOS treats this one as a new app once: grant
Accessibility and Microphone again when asked. The third-party notices are
inside the image.

The Mac App Store edition of the same version reaches the store separately,
after Apple's review.
EOF
else
    cat <<'EOF'
Open the DMG and drag **kvoice** to Applications. This build is not signed
with an Apple Developer ID, so the first launch needs Finder's **Open** from
the context menu (or System Settings › Privacy & Security › Open Anyway).
The third-party notices are inside the image.
EOF
fi
