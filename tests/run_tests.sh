#!/usr/bin/env bash
# Run every ServerInator local test file. No VPS/phone/network access required.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
