#!/bin/sh
# Delete the temporary keychain created by ci_import_signing_identity.sh.
# Runs as an `if: always()` step so a failed build never leaves the
# project's signing identity on a runner (hosted runners are discarded anyway; this
# matters for a self-hosted one).
set -eu

keychain="${KVOICE_CI_KEYCHAIN:-}"
[ -n "$keychain" ] || exit 0
if [ -f "$keychain" ]; then
    security delete-keychain "$keychain"
    echo "ci_remove_signing_identity: removed $keychain" >&2
fi
