#!/usr/bin/env bash
# Stop hook: refuse to let Claude finish while lint / typecheck / tests fail.
#
# Exit codes (Claude Code hook contract):
#   0 -> checks passed (or nothing to check): Claude may stop.
#   2 -> checks failed: Claude is BLOCKED from stopping and receives stderr
#        as feedback, so it keeps working until the checks pass.
#   Exit 1 would only show a non-blocking warning, which is why this script
#   never uses it (and deliberately avoids `set -e`).
#
# Override auto-detection by listing your own commands here:
CHECKS=(
  # "npm run lint"
  # "npm run typecheck"
  # "npm test"
)

# Give up blocking after this many consecutive failed attempts in one session,
# so a genuinely stuck task can't loop forever. Override with env var.
MAX_ATTEMPTS="${CLAUDE_CHECKS_MAX_ATTEMPTS:-5}"

# ---------------------------------------------------------------------------

INPUT="$(cat 2>/dev/null || true)"
json_field() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
  else
    printf '%s' "$INPUT" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\).*/\1/p" | head -n1
  fi
}
SESSION_ID="$(json_field session_id)"
SESSION_ID="${SESSION_ID:-nosession}"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT_DIR" || exit 0

have() { command -v "$1" >/dev/null 2>&1; }

detect_checks() {
  # --- Node (npm / pnpm / yarn / bun) ---
  if [[ -f package.json ]]; then
    local pm="npm"
    [[ -f pnpm-lock.yaml ]] && pm="pnpm"
    [[ -f yarn.lock ]] && pm="yarn"
    [[ -f bun.lockb || -f bun.lock ]] && pm="bun"
    local s
    for s in lint typecheck type-check test; do
      if have node && node -e '
        const s = (require("./package.json").scripts || {})[process.argv[1]];
        process.exit(s && !/no test specified/.test(s) ? 0 : 1);' "$s" 2>/dev/null; then
        CHECKS+=("$pm run $s")
      fi
    done
  fi

  # --- Python ---
  if [[ -f pyproject.toml || -f setup.py || -f setup.cfg || -f requirements.txt ]]; then
    have ruff && CHECKS+=("ruff check .")
    if have mypy && { [[ -f mypy.ini || -f .mypy.ini ]] || grep -qs '\[tool.mypy\]' pyproject.toml setup.cfg; }; then
      CHECKS+=("mypy .")
    fi
    if have pytest && [[ -n "$(find . -path ./node_modules -prune -o -path ./.venv -prune -o \
         \( -name 'test_*.py' -o -name '*_test.py' \) -print -quit 2>/dev/null)" ]]; then
      CHECKS+=("pytest -q")
    fi
  fi

  # --- Go ---
  if [[ -f go.mod ]] && have go; then
    CHECKS+=("go vet ./...")
    have golangci-lint && CHECKS+=("golangci-lint run")
    CHECKS+=("go test ./...")
  fi

  # --- Rust ---
  if [[ -f Cargo.toml ]] && have cargo; then
    cargo clippy --version >/dev/null 2>&1 && CHECKS+=("cargo clippy --all-targets -- -D warnings")
    CHECKS+=("cargo test")
  fi
}

if [[ ${#CHECKS[@]} -eq 0 ]]; then
  detect_checks
fi

STATE_DIR="${TMPDIR:-/tmp}/claude-require-checks"
mkdir -p "$STATE_DIR" 2>/dev/null
STATE_FILE="$STATE_DIR/${SESSION_ID//[^A-Za-z0-9_-]/_}"

if [[ ${#CHECKS[@]} -eq 0 ]]; then
  exit 0  # nothing to check
fi

FAILED=()
REPORT=""
for cmd in "${CHECKS[@]}"; do
  out="$(bash -c "$cmd" 2>&1)"
  status=$?
  if [[ $status -ne 0 ]]; then
    FAILED+=("$cmd")
    REPORT+=$'\n'"### \`$cmd\` failed (exit $status)"$'\n'"$(printf '%s\n' "$out" | tail -n 40)"$'\n'
  fi
done

if [[ ${#FAILED[@]} -eq 0 ]]; then
  rm -f "$STATE_FILE" 2>/dev/null
  exit 0
fi

attempts=$(( $(cat "$STATE_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$attempts" > "$STATE_FILE" 2>/dev/null

if (( attempts > MAX_ATTEMPTS )); then
  rm -f "$STATE_FILE" 2>/dev/null
  echo "require-checks: checks still failing after $MAX_ATTEMPTS attempts; letting Claude stop. Failing: ${FAILED[*]}" >&2
  exit 0
fi

{
  echo "Checks failed — you are not done. Fix these before finishing (attempt $attempts/$MAX_ATTEMPTS):"
  printf '%s\n' "$REPORT"
  echo "Do not disable, skip, or weaken the checks to make them pass."
} >&2
exit 2
