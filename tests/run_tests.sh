#!/usr/bin/env bash
# Run every ServerInator local test file. No VPS/phone/network access required.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Without these many files fail with errors that don't say why.
missing=()
for c in jq ssh-keygen flock curl; do command -v "$c" > /dev/null || missing+=("$c"); done
if (( ${#missing[@]} )); then
    echo "The tests need: ${missing[*]} (Debian/Ubuntu: apt install jq openssh-client util-linux curl)" >&2
    exit 1
fi

overall=0
for t in "$here"/test_*.sh; do
    [[ -e "$t" ]] || continue
    echo ""
    echo "### $(basename "$t")"
    if bash "$t"; then
        echo "### $(basename "$t"): OK"
    else
        echo "### $(basename "$t"): FAILED"
        overall=1
    fi
done

echo ""
if [[ "$overall" -eq 0 ]]; then
    echo "ALL TEST FILES PASSED"
else
    echo "SOME TEST FILES FAILED"
fi
exit "$overall"
