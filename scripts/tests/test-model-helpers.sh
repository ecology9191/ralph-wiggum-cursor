#!/bin/bash
# Tests for dynamic model helper functions in ralph-common.sh
#
# Mocks cursor-agent so no live binary is needed.
# Run: bash scripts/tests/test-model-helpers.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected: $(echo "$expected" | head -5)"
    echo "    actual:   $(echo "$actual"   | head -5)"
    FAIL=$((FAIL + 1))
  fi
}

assert_rc() {
  local label="$1" expected_rc="$2"
  shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq "$expected_rc" ]]; then
    echo "  PASS: $label (rc=$rc)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected rc=$expected_rc, got rc=$rc)"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Sample output captured from a real cursor-agent --list-models invocation.
# Includes ANSI escape codes for realistic parsing.
# ---------------------------------------------------------------------------
SAMPLE_OUTPUT=$'\e[1mAvailable models:\e[0m
  \e[36mcomposer-2\e[0m - Composer 2  \e[33m(default)\e[0m
  \e[36mclaude-4.6-opus-max-thinking\e[0m - Claude 4.6 Opus Max (Thinking)
  \e[36mgpt-5.2-high\e[0m - GPT 5.2 High
  \e[36mclaude-4.5-sonnet-thinking\e[0m - Claude 4.5 Sonnet (Thinking)
'

SAMPLE_NO_DEFAULT=$'\e[1mAvailable models:\e[0m
  \e[36malpha-model\e[0m - Alpha Model
  \e[36mbeta-model\e[0m - Beta Model
'

# ---------------------------------------------------------------------------
# Helpers: override cursor-agent with a mock function
# ---------------------------------------------------------------------------
_MOCK_CURSOR_OUTPUT=""
mock_cursor_agent_with() {
  _MOCK_CURSOR_OUTPUT="$1"
  cursor-agent() { echo "$_MOCK_CURSOR_OUTPUT"; }
  export -f cursor-agent
  _RALPH_MODELS_CACHE=""
}

mock_cursor_agent_missing() {
  cursor-agent() { return 127; }
  export -f cursor-agent
  _RALPH_MODELS_CACHE=""
}

# Source ralph-common.sh (which defines the helpers).
# We already mocked cursor-agent before sourcing so the top-level
# DEFAULT_MODEL assignment calls our mock.
mock_cursor_agent_with "$SAMPLE_OUTPUT"
source "$SCRIPT_DIR/ralph-common.sh"

echo "=== Dynamic model helper tests ==="
echo ""

# ---- Test 1 ---------------------------------------------------------------
echo "Test 1: get_available_models parses output correctly"
mock_cursor_agent_with "$SAMPLE_OUTPUT"
actual=$(get_available_models)
expected=$(printf '%s\n' "composer-2" "claude-4.6-opus-max-thinking" "gpt-5.2-high" "claude-4.5-sonnet-thinking")
assert_eq "slug list matches" "$expected" "$actual"

# ---- Test 2 ---------------------------------------------------------------
echo "Test 2: get_available_models strips ANSI codes"
mock_cursor_agent_with "$SAMPLE_OUTPUT"
actual=$(get_available_models)
if echo "$actual" | grep -qP '\e\['; then
  echo "  FAIL: output still contains ANSI escape sequences"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: no ANSI escapes in output"
  PASS=$((PASS + 1))
fi

# ---- Test 3 ---------------------------------------------------------------
echo "Test 3: get_available_models falls back when cursor-agent absent"
mock_cursor_agent_missing
actual=$(get_available_models)
expected=$(printf '%s\n' "composer-2" "claude-4.6-opus-max-thinking" "gpt-5.2-high" "claude-4.5-sonnet-thinking")
assert_eq "fallback list matches" "$expected" "$actual"

# ---- Test 4 ---------------------------------------------------------------
echo "Test 4: get_default_model picks the (default) model"
mock_cursor_agent_with "$SAMPLE_OUTPUT"
actual=$(get_default_model)
assert_eq "default is composer-2" "composer-2" "$actual"

# ---- Test 5 ---------------------------------------------------------------
echo "Test 5: get_default_model picks first when no (default) marker"
mock_cursor_agent_with "$SAMPLE_NO_DEFAULT"
actual=$(get_default_model)
assert_eq "first model returned" "alpha-model" "$actual"

# ---- Test 6 ---------------------------------------------------------------
echo "Test 6: validate_model returns 0 for valid model"
mock_cursor_agent_with "$SAMPLE_OUTPUT"
assert_rc "valid model rc=0" 0 validate_model "gpt-5.2-high"

# ---- Test 7 ---------------------------------------------------------------
echo "Test 7: validate_model returns 1 for invalid model"
mock_cursor_agent_with "$SAMPLE_OUTPUT"
assert_rc "invalid model rc=1" 1 validate_model "nonexistent-model-xyz"

# ---- Test 8 ---------------------------------------------------------------
echo "Test 8: MODELS array has no stale hardcoded slugs in ralph-setup.sh"
stale_slugs=("opus-4.5-thinking" "sonnet-4.5-thinking" "composer-1")
stale_found=0
for slug in "${stale_slugs[@]}"; do
  if grep -qF "\"$slug\"" "$SCRIPT_DIR/ralph-setup.sh"; then
    echo "  FAIL: stale slug '$slug' still hardcoded in ralph-setup.sh"
    stale_found=1
  fi
done
if [[ "$stale_found" -eq 0 ]]; then
  echo "  PASS: no stale slugs in ralph-setup.sh"
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit "$FAIL"
