#!/bin/bash

# Mock commands that will simulate different scenarios
success_cmd() {
    echo "Command succeeded"
    return 0
}

fail_exists_cmd() {
    echo "Error from server (AlreadyExists): thing already exists" >&2
    return 1
}

fail_other_cmd() {
    echo "Error: something else went wrong" >&2
    return 1
}
create_if_not_exists() {
    output=$("$@" 2>&1) || {
        if ! grep -q "already exists" <<<"$output"; then
            echo "$output" >&2  # Print error if it's not "already exists"
            return 1
        fi
        echo "ignoring already exists error."
    }
    return 0
}


# Test cases
echo "Test 1: Command succeeds"
create_if_not_exists success_cmd
echo "Exit code: $?"
echo

echo "Test 2: Command fails with 'already exists'"
create_if_not_exists fail_exists_cmd
echo "Exit code: $?"
echo

echo "Test 3: Command fails with other error"
create_if_not_exists fail_other_cmd
echo "Exit code: $?"