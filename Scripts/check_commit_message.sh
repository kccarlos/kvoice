#!/bin/sh
# Conventional Commits check. Used by the `commit-msg`
# hook in .githooks/ on one message file, and by CI on a commit range.
#
#   check_commit_message.sh --file <path>       one message (git hook)
#   check_commit_message.sh --range <a>..<b>    every commit in the range
#
# Accepted subject line:
#   <type>(<scope>)!: <summary>      scope and "!" optional
# with type one of the list below. Merge commits, reverts and fixup!/squash!
# subjects are accepted as-is. The summary must be non-empty; there is no length limit
# because the existing history has long, useful subjects, and published
# history is never rewritten to shorten them.
set -eu

types='feat|fix|docs|test|refactor|perf|build|ci|chore|style|revert|sync'
pattern="^($types)(\\([A-Za-z0-9_./ ,+-]+\\))?!?: [^ ].*$"
exempt='^(Merge |Revert |fixup! |squash! |amend! )'

check_subject() {
    subject="$1"
    label="$2"
    if printf '%s' "$subject" | grep -Eq "$exempt"; then return 0; fi
    if printf '%s' "$subject" | grep -Eq "$pattern"; then return 0; fi
    cat >&2 <<EOF
$label: not a Conventional Commit subject:
    $subject
Expected: <type>(<scope>)!: <summary>
  with <type> one of: $(printf '%s' "$types" | tr '|' ' ')
  e.g.  feat(models): add Apple Speech as a runtime
        fix(shell): bound the terminate handshake
        docs: release pipeline
EOF
    return 1
}

case "${1:-}" in
    --file)
        file="${2:?usage: check_commit_message.sh --file <path>}"
        # First line that is not a comment or blank is the subject.
        subject="$(grep -v '^#' "$file" | sed '/^[[:space:]]*$/d' | head -1)"
        check_subject "$subject" "commit-msg"
        ;;
    --range)
        range="${2:?usage: check_commit_message.sh --range <a>..<b>}"
        status=0
        git log --format='%H %s' "$range" | while IFS= read -r line; do
            sha="${line%% *}"
            subject="${line#* }"
            check_subject "$subject" "${sha}" || exit 1
        done || status=1
        exit "$status"
        ;;
    *)
        echo "usage: check_commit_message.sh --file <path> | --range <a>..<b>" >&2
        exit 2
        ;;
esac
