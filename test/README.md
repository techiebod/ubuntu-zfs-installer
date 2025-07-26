# Testing

This directory contains tests for the Ubuntu ZFS Installer project using the [bats-core](https://github.com/bats-core/bats-core) testing framework.

## Test Structure

```
test/
├── unit/              # Unit tests for individual library functions
│   ├── constants.bats
│   ├── logging.bats
│   └── validation.bats
├── integration/       # Integration tests for end-to-end workflows
└── helpers/           # Test helper functions and setup
```

## Running Tests

Use the Docker-based bats wrapper:

```bash
# Run all tests
./tools/bats.sh

# Run specific test file
./tools/bats.sh test/unit/logging.bats

# Run with TAP output
./tools/bats.sh --tap test/unit/

# Run specific test directory
./tools/bats.sh test/unit/
```

## Writing Tests

Tests follow the bats format:

```bash
#!/usr/bin/env bats

setup() {
    # Setup code run before each test
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    source "$PROJECT_ROOT/lib/your-library.sh"
}

teardown() {
    # Cleanup code run after each test
}

@test "descriptive test name" {
    run your_function "arguments"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "expected output" ]]
}
```

## Current Status

- **Unit Tests**: 18/18 passing (100% pass rate)
  - ✅ Constants library (6/6)
  - ✅ Logging library (5/5) - debug issue resolved
  - ✅ Validation library (7/7) - hostname validation issue resolved

See individual test files for specific test cases and current issues.
