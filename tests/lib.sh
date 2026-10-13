#!/usr/bin/env bash
# Shared helpers for ServerInator local tests. Sourced by tests/test_*.sh.
# Deliberately does not enable `set -e` so the harness itself keeps running
# after an assertion fails.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHONE_SCRIPT="$REPO_ROOT/core/core-phone.sh"
VPS_SCRIPT="$REPO_ROOT/core/core-vps.sh"

TESTS_PASSED=0
TESTS_FAILED=0

pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); echo "  PASS: $*"; }
failtest() { TESTS_FAILED=$((TESTS_FAILED + 1)); echo "  FAIL: $*" >&2; }

assert_eq() { # expected actual label
    if [[ "$1" == "$2" ]]; then
        pass "$3"
    else
        failtest "$3 (expected: '$1', got: '$2')"
    fi
}

assert_contains() { # haystack needle label
    if [[ "$1" == *"$2"* ]]; then
        pass "$3"
    else
        failtest "$3 (missing: '$2')"
    fi
}

assert_not_contains() { # haystack needle label
    if [[ "$1" != *"$2"* ]]; then
        pass "$3"
    else
        failtest "$3 (unexpectedly present: '$2')"
    fi
}

assert_file_exists() { # path label
    if [[ -f "$1" ]]; then
        pass "$2"
    else
        failtest "$2 (missing file: $1)"
    fi
}

assert_file_missing() { # path label
    if [[ ! -e "$1" ]]; then
        pass "$2"
    else
        failtest "$2 (unexpected path exists: $1)"
    fi
}

export TEST_PHONE_IP="10.66.69.$((1 + 1))"
