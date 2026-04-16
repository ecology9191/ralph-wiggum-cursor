#!/bin/bash
# Ralph Wiggum: Common utilities and loop logic
#
# Shared functions for ralph-loop.sh and ralph-setup.sh
# All state lives in .ralph/ within the project.

# =============================================================================
# SOURCE DEPENDENCIES
# =============================================================================

# Get the directory where this script lives
_RALPH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the task parser for YAML backend support
if [[ -f "$_RALPH_SCRIPT_DIR/task-parser.sh" ]]; then
  source "$_RALPH_SCRIPT_DIR/task-parser.sh"
  _TASK_PARSER_AVAILABLE=1
else
  _TASK_PARSER_AVAILABLE=0
fi

# =============================================================================
# CONFIGURATION (can be overridden before sourcing)
# =============================================================================

# Resolved by resolve_ralph_runtime_config() after DEFAULT_MODEL is set.
# Callers (ralph-setup.sh) handle exports.

# Model selection — dynamic discovery from cursor-agent --list-models
_RALPH_MODELS_CACHE=""

get_available_models() {
  if [[ -n "$_RALPH_MODELS_CACHE" ]]; then
    echo "$_RALPH_MODELS_CACHE"
    return
  fi

  local raw slugs
  raw=$(cursor-agent --list-models 2>/dev/null) || {
    _RALPH_MODELS_CACHE=$(printf '%s\n' "composer-2" "claude-4.6-opus-max-thinking" "gpt-5.2-high" "claude-4.5-sonnet-thinking")
    echo "$_RALPH_MODELS_CACHE"
    return
  }

  slugs=$(echo "$raw" \
    | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' \
    | grep ' - ' \
    | awk -F' - ' '{print $1}' \
    | sed 's/^[[:space:]]*//' \
    | grep -v '^$')

  if [[ -z "$slugs" ]]; then
    _RALPH_MODELS_CACHE=$(printf '%s\n' "composer-2" "claude-4.6-opus-max-thinking" "gpt-5.2-high" "claude-4.5-sonnet-thinking")
  else
    _RALPH_MODELS_CACHE="$slugs"
  fi
  echo "$_RALPH_MODELS_CACHE"
}

get_default_model() {
  local raw default_slug
  raw=$(cursor-agent --list-models 2>/dev/null) || {
    echo "composer-2"
    return
  }

  default_slug=$(echo "$raw" \
    | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' \
    | grep '(default)' \
    | awk -F' - ' '{print $1}' \
    | sed 's/^[[:space:]]*//' \
    | head -1)

  if [[ -n "$default_slug" ]]; then
    echo "$default_slug"
  else
    get_available_models | head -1
  fi
}

validate_model() {
  local model="$1"
  local available
  available=$(get_available_models)

  if echo "$available" | grep -qxF "$model"; then
    return 0
  else
    echo "⚠️  Model '$model' not found in available models. It may still work if it's a private/custom model." >&2
    return 1
  fi
}

model_value_invalid_reason() {
  local val="$1"
  [[ -z "$val" ]] && echo "empty" && return
  [[ "$val" == *$'\n'* ]] || [[ "$val" == *$'\r'* ]] && echo "contains newline" && return
  [[ "$val" =~ [[:space:]] ]] && echo "contains whitespace" && return
  [[ "$val" == *"Select model"* ]] || [[ "$val" == *"Keep current"* ]] && echo "contains menu text" && return
  [[ ! "$val" =~ ^[a-zA-Z0-9._-]+$ ]] && echo "invalid characters for CLI model ID" && return
  echo ""
}

DEFAULT_MODEL="$(get_default_model 2>/dev/null || echo 'composer-2')"

resolve_ralph_runtime_config() {
  WARN_THRESHOLD="${WARN_THRESHOLD:-70000}"
  ROTATE_THRESHOLD="${ROTATE_THRESHOLD:-80000}"
  MAX_ITERATIONS="${MAX_ITERATIONS:-20}"
  APPROVE_MCPS="${APPROVE_MCPS:-${RALPH_APPROVE_MCPS:-true}}"
  MODEL="${MODEL:-${RALPH_MODEL:-$DEFAULT_MODEL}}"
}

resolve_ralph_runtime_config

# Feature flags (set by caller)
USE_BRANCH="${USE_BRANCH:-}"
OPEN_PR="${OPEN_PR:-false}"
SKIP_CONFIRM="${SKIP_CONFIRM:-false}"

# =============================================================================
# SOURCE RETRY UTILITIES
# =============================================================================

# Source retry logic utilities
SCRIPT_DIR="${SCRIPT_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
if [[ -f "$SCRIPT_DIR/ralph-retry.sh" ]]; then
  source "$SCRIPT_DIR/ralph-retry.sh"
fi

# Classify pipeline error strings as retryable (DEFER) or fatal (GUTTER).
# Mirrors is_retryable_api_error from stream-parser.sh but works on raw
# error text captured from pipeline failures (no structured JSON available).
is_retryable_runtime_error() {
  local error_msg="$1"
  local lower_msg
  lower_msg=$(echo "$error_msg" | tr '[:upper:]' '[:lower:]')

  if [[ "$lower_msg" =~ (rate[[:space:]]*limit|rate_limit|rate-limit) ]] || \
     [[ "$lower_msg" =~ (quota[[:space:]]*exceeded|too[[:space:]]*many[[:space:]]*requests|429) ]] || \
     [[ "$lower_msg" =~ (timeout|timed[[:space:]]*out|connection[[:space:]]*timeout) ]] || \
     [[ "$lower_msg" =~ (network[[:space:]]*error|connection[[:space:]]*refused|econnreset) ]] || \
     [[ "$lower_msg" =~ (service[[:space:]]*unavailable|503|bad[[:space:]]*gateway|502) ]] || \
     [[ "$lower_msg" =~ (gateway[[:space:]]*timeout|504|overloaded|try[[:space:]]*again) ]]; then
    return 0
  fi
  return 1
}

# =============================================================================
# BASIC HELPERS
# =============================================================================

# Cross-platform sed -i
sedi() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# Get the .ralph directory for a workspace
get_ralph_dir() {
  local workspace="${1:-.}"
  echo "$workspace/.ralph"
}

# Get current iteration from .ralph/.iteration
get_iteration() {
  local workspace="${1:-.}"
  local state_file="$workspace/.ralph/.iteration"
  
  if [[ -f "$state_file" ]]; then
    cat "$state_file"
  else
    echo "0"
  fi
}

# Set iteration number
set_iteration() {
  local workspace="${1:-.}"
  local iteration="$2"
  local ralph_dir="$workspace/.ralph"
  
  mkdir -p "$ralph_dir"
  echo "$iteration" > "$ralph_dir/.iteration"
}

# Increment iteration and return new value
increment_iteration() {
  local workspace="${1:-.}"
  local current=$(get_iteration "$workspace")
  local next=$((current + 1))
  set_iteration "$workspace" "$next"
  echo "$next"
}

# Get context health emoji based on token count
get_health_emoji() {
  local tokens="$1"
  local pct=$((tokens * 100 / ROTATE_THRESHOLD))
  
  if [[ $pct -lt 60 ]]; then
    echo "🟢"
  elif [[ $pct -lt 80 ]]; then
    echo "🟡"
  else
    echo "🔴"
  fi
}

# Submodule-safe checkpoint commit.
# Stages all changes while skipping submodule recursion and tolerating
# individual file errors (e.g. broken submodule metadata).
checkpoint_commit_if_needed() {
  local workspace="${1:-.}"
  local msg="$2"
  if [[ -z "$(git -C "$workspace" status --porcelain --ignore-submodules=all 2>/dev/null)" ]]; then
    return 0
  fi
  echo "📦 Committing uncommitted changes..."
  git -C "$workspace" -c submodule.recurse=false add --all --ignore-errors 2>/dev/null || true
  git -C "$workspace" commit -m "$msg" 2>/dev/null || true
}

# =============================================================================
# LOGGING
# =============================================================================

# Log a message to activity.log
log_activity() {
  local workspace="${1:-.}"
  local message="$2"
  local ralph_dir="$workspace/.ralph"
  local timestamp=$(date '+%H:%M:%S')
  
  mkdir -p "$ralph_dir"
  echo "[$timestamp] $message" >> "$ralph_dir/activity.log"
}

# Log an error to errors.log
log_error() {
  local workspace="${1:-.}"
  local message="$2"
  local ralph_dir="$workspace/.ralph"
  local timestamp=$(date '+%H:%M:%S')
  
  mkdir -p "$ralph_dir"
  echo "[$timestamp] $message" >> "$ralph_dir/errors.log"
}

# Log to progress.md (called by the loop, not the agent)
log_progress() {
  local workspace="$1"
  local message="$2"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local progress_file="$workspace/.ralph/progress.md"
  
  echo "" >> "$progress_file"
  echo "### $timestamp" >> "$progress_file"
  echo "$message" >> "$progress_file"
}

# =============================================================================
# INITIALIZATION
# =============================================================================

# Initialize .ralph directory with default files
init_ralph_dir() {
  local workspace="$1"
  local ralph_dir="$workspace/.ralph"
  
  mkdir -p "$ralph_dir"
  
  # Initialize progress.md if it doesn't exist
  if [[ ! -f "$ralph_dir/progress.md" ]]; then
    cat > "$ralph_dir/progress.md" << 'EOF'
# Progress Log

> Updated by the agent after significant work.

---

## Session History

EOF
  fi
  
  # Initialize guardrails.md if it doesn't exist
  if [[ ! -f "$ralph_dir/guardrails.md" ]]; then
    cat > "$ralph_dir/guardrails.md" << 'EOF'
# Ralph Guardrails (Signs)

> Lessons learned from past failures. READ THESE BEFORE ACTING.

## Core Signs

### Sign: Read Before Writing
- **Trigger**: Before modifying any file
- **Instruction**: Always read the existing file first
- **Added after**: Core principle

### Sign: Test After Changes
- **Trigger**: After any code change
- **Instruction**: Run tests to verify nothing broke
- **Added after**: Core principle

### Sign: Commit Checkpoints
- **Trigger**: Before risky changes
- **Instruction**: Commit current working state first
- **Added after**: Core principle

---

## Learned Signs

EOF
  fi
  
  # Initialize errors.log if it doesn't exist
  if [[ ! -f "$ralph_dir/errors.log" ]]; then
    cat > "$ralph_dir/errors.log" << 'EOF'
# Error Log

> Failures detected by stream-parser. Use to update guardrails.

EOF
  fi
  
  # Initialize activity.log if it doesn't exist
  if [[ ! -f "$ralph_dir/activity.log" ]]; then
    cat > "$ralph_dir/activity.log" << 'EOF'
# Activity Log

> Real-time tool call logging from stream-parser.

EOF
  fi
}

# =============================================================================
# TASK MANAGEMENT
# =============================================================================

# Check if task is complete
# Uses task-parser.sh when available for cached/YAML support
check_task_complete() {
  local workspace="$1"
  local task_file="$workspace/RALPH_TASK.md"
  
  if [[ ! -f "$task_file" ]]; then
    echo "NO_TASK_FILE"
    return
  fi
  
  # Use task parser if available (provides caching)
  if [[ "${_TASK_PARSER_AVAILABLE:-0}" -eq 1 ]]; then
    local remaining
    remaining=$(count_remaining "$workspace" 2>/dev/null) || remaining=-1
    
    if [[ "$remaining" -eq 0 ]]; then
      echo "COMPLETE"
    elif [[ "$remaining" -gt 0 ]]; then
      echo "INCOMPLETE:$remaining"
    else
      # Fallback to direct grep if parser fails
      _check_task_complete_direct "$workspace"
    fi
  else
    _check_task_complete_direct "$workspace"
  fi
}

# Direct task completion check (fallback)
_check_task_complete_direct() {
  local workspace="$1"
  local task_file="$workspace/RALPH_TASK.md"
  
  # Only count actual checkbox list items, not [ ] in prose/examples
  # Matches: "- [ ]", "* [ ]", "1. [ ]", etc.
  local unchecked
  unchecked=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[ \]' "$task_file" 2>/dev/null) || unchecked=0
  
  if [[ "$unchecked" -eq 0 ]]; then
    echo "COMPLETE"
  else
    echo "INCOMPLETE:$unchecked"
  fi
}

# Count task criteria (returns done:total)
# Uses task-parser.sh when available for cached/YAML support
count_criteria() {
  local workspace="${1:-.}"
  local task_file="$workspace/RALPH_TASK.md"
  
  if [[ ! -f "$task_file" ]]; then
    echo "0:0"
    return
  fi
  
  # Use task parser if available (provides caching)
  if [[ "${_TASK_PARSER_AVAILABLE:-0}" -eq 1 ]]; then
    local progress
    progress=$(get_progress "$workspace" 2>/dev/null) || progress=""
    
    if [[ -n "$progress" ]] && [[ "$progress" =~ ^[0-9]+:[0-9]+$ ]]; then
      echo "$progress"
    else
      # Fallback to direct grep if parser fails
      _count_criteria_direct "$workspace"
    fi
  else
    _count_criteria_direct "$workspace"
  fi
}

# Direct criteria counting (fallback)
_count_criteria_direct() {
  local workspace="${1:-.}"
  local task_file="$workspace/RALPH_TASK.md"
  
  # Only count actual checkbox list items, not [x] or [ ] in prose/examples
  # Matches: "- [ ]", "* [x]", "1. [ ]", etc.
  local total done_count
  total=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x| )\]' "$task_file" 2>/dev/null) || total=0
  done_count=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[x\]' "$task_file" 2>/dev/null) || done_count=0
  
  echo "$done_count:$total"
}

# =============================================================================
# TASK PARSER CONVENIENCE WRAPPERS
# =============================================================================

# Get the next task to work on (wrapper for task-parser.sh)
# Returns: task_id|status|description or empty
get_next_task_info() {
  local workspace="${1:-.}"
  
  if [[ "${_TASK_PARSER_AVAILABLE:-0}" -eq 1 ]]; then
    get_next_task "$workspace"
  else
    echo ""
  fi
}

# Mark a specific task complete by line-based ID
# Usage: complete_task "$workspace" "line_15"
complete_task() {
  local workspace="${1:-.}"
  local task_id="$2"
  
  if [[ "${_TASK_PARSER_AVAILABLE:-0}" -eq 1 ]]; then
    mark_task_complete "$workspace" "$task_id"
  else
    echo "ERROR: Task parser not available" >&2
    return 1
  fi
}

# List all tasks with their status
# Usage: list_all_tasks "$workspace"
list_all_tasks() {
  local workspace="${1:-.}"
  
  if [[ "${_TASK_PARSER_AVAILABLE:-0}" -eq 1 ]]; then
    get_all_tasks "$workspace"
  else
    echo "ERROR: Task parser not available" >&2
    return 1
  fi
}

# Refresh task cache (useful after external edits)
refresh_task_cache() {
  local workspace="${1:-.}"
  
  if [[ "${_TASK_PARSER_AVAILABLE:-0}" -eq 1 ]]; then
    # Invalidate and re-parse
    rm -f "$workspace/.ralph/$TASK_MTIME_FILE" 2>/dev/null
    parse_tasks "$workspace"
  fi
}

# =============================================================================
# PROMPT BUILDING
# =============================================================================

# Build the Ralph prompt for an iteration
build_prompt() {
  local workspace="$1"
  local iteration="$2"
  
  cat << EOF
# Ralph Iteration $iteration

You are an autonomous development agent using the Ralph methodology.

## FIRST: Read State Files

Before doing anything:
1. Read \`RALPH_TASK.md\` - your task and completion criteria
2. Read \`.ralph/guardrails.md\` - lessons from past failures (FOLLOW THESE)
3. Read \`.ralph/progress.md\` - what's been accomplished
4. Read \`.ralph/errors.log\` - recent failures to avoid

## Working Directory (Critical)

You are already in a git repository. Work HERE, not in a subdirectory:

- Do NOT run \`git init\` - the repo already exists
- Do NOT run scaffolding commands that create nested directories (\`npx create-*\`, \`pnpm init\`, etc.)
- If you need to scaffold, use flags like \`--no-git\` or scaffold into the current directory (\`.\`)
- All code should live at the repo root or in subdirectories you create manually

## Git Protocol (Critical)

Ralph's strength is state-in-git, not LLM memory. Commit early and often:

1. After completing each criterion, commit your changes:
   \`git add . && git commit -m 'ralph: implement state tracker'\`
   \`git add . && git commit -m 'ralph: fix async race condition'\`
   \`git add . && git commit -m 'ralph: add CLI adapter with commander'\`
   Always describe what you actually did - never use placeholders like '<description>'
   **Warning**: If the repo has git submodules, avoid \`git add -A\` — it can fail on
   incomplete submodule metadata. Use \`git add .\` instead (stages the current directory only).
2. After any significant code change (even partial): commit with descriptive message
3. Before any risky refactor: commit current state as checkpoint
4. Push after every 2-3 commits: \`git push\`

If you get rotated, the next agent picks up from your last commit. Your commits ARE your memory.

## Task Execution

1. Work on the next unchecked criterion in RALPH_TASK.md (look for \`[ ]\`)
2. Run tests after changes (check RALPH_TASK.md for test_command)
3. **Mark completed criteria**: Edit RALPH_TASK.md and change \`[ ]\` to \`[x]\`
   - Example: \`- [ ] Implement parser\` becomes \`- [x] Implement parser\`
   - This is how progress is tracked - YOU MUST update the file
4. Update \`.ralph/progress.md\` with what you accomplished
5. When ALL criteria show \`[x]\`: output \`<ralph>COMPLETE</ralph>\`
6. If stuck 3+ times on same issue: output \`<ralph>GUTTER</ralph>\`

## Learning from Failures

When something fails:
1. Check \`.ralph/errors.log\` for failure history
2. Figure out the root cause
3. Add a Sign to \`.ralph/guardrails.md\` using this format:

\`\`\`
### Sign: [Descriptive Name]
- **Trigger**: When this situation occurs
- **Instruction**: What to do instead
- **Added after**: Iteration $iteration - what happened
\`\`\`

## Context Rotation Warning

You may receive a warning that context is running low. When you see it:
1. Finish your current file edit
2. Commit and push your changes
3. Update .ralph/progress.md with what you accomplished and what's next
4. You will be rotated to a fresh agent that continues your work

Begin by reading the state files.
EOF
}

# =============================================================================
# PROCESS LIFECYCLE
# =============================================================================

stop_process_tree() {
  local pid="$1"
  local children
  children=$(pgrep -P "$pid" 2>/dev/null) || true
  for child in $children; do
    stop_process_tree "$child"
  done
  kill "$pid" 2>/dev/null || true
}

# Globals set by run_iteration(), used by the interrupt handler.
_RALPH_AGENT_PID=""
_RALPH_SPINNER_PID=""

cleanup_iteration_processes() {
  [[ -n "$_RALPH_AGENT_PID" ]] && stop_process_tree "$_RALPH_AGENT_PID"
  [[ -n "$_RALPH_SPINNER_PID" ]] && stop_process_tree "$_RALPH_SPINNER_PID"
  _RALPH_AGENT_PID=""
  _RALPH_SPINNER_PID=""
}

on_iteration_interrupt() {
  echo "" >&2
  echo "🛑 Interrupt received — cleaning up agent processes..." >&2
  cleanup_iteration_processes
  exit 130
}

# =============================================================================
# SPINNER
# =============================================================================

# Spinner to show the loop is alive (not frozen)
# Outputs to stderr so it's not captured by $()
spinner() {
  local workspace="$1"
  local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  while true; do
    printf "\r  🐛 Agent working... %s  (watch: tail -f %s/.ralph/activity.log)" "${spin:i++%${#spin}:1}" "$workspace" >&2
    sleep 0.1
  done
}

# =============================================================================
# ITERATION RUNNER
# =============================================================================

# Run a single agent iteration
# Returns: signal (ROTATE, GUTTER, COMPLETE, CONFIG_ERROR, or empty)
run_iteration() {
  local workspace="$1"
  local iteration="$2"
  local session_id="${3:-}"
  local script_dir="${4:-$(dirname "${BASH_SOURCE[0]}")}"

  local prompt
  prompt=$(build_prompt "$workspace" "$iteration")
  local fifo="$workspace/.ralph/.parser_fifo"
  local pipeline_status_file="$workspace/.ralph/.pipeline_status"

  # Create named pipe for parser signals
  rm -f "$fifo"
  mkfifo "$fifo"

  # Use stderr for display (stdout is captured for signal)
  echo "" >&2
  echo "═══════════════════════════════════════════════════════════════════" >&2
  echo "🐛 Ralph Iteration $iteration" >&2
  echo "═══════════════════════════════════════════════════════════════════" >&2
  echo "" >&2
  echo "Workspace: $workspace" >&2
  echo "Model:     $MODEL" >&2
  echo "Monitor:   tail -f $workspace/.ralph/activity.log" >&2
  echo "" >&2

  # Log session start to progress.md
  log_progress "$workspace" "**Session $iteration started** (model: $MODEL)"

  # --- Structural model validation (first gate) ---
  local bad_reason
  bad_reason=$(model_value_invalid_reason "$MODEL")
  if [[ -n "$bad_reason" ]]; then
    echo "ERROR: Model value is invalid ($bad_reason): '$MODEL'" >&2
    echo "CONFIG_ERROR"
    return 1
  fi

  # --- Semantic model validation (second gate, bypassable) ---
  if ! validate_model "$MODEL" 2>/dev/null; then
    if [[ "${RALPH_FORCE_MODEL:-}" == "true" ]]; then
      echo "Warning: Model '$MODEL' not in known list but RALPH_FORCE_MODEL=true." >&2
    else
      echo "ERROR: Model '$MODEL' not available. Set RALPH_FORCE_MODEL=true to override." >&2
      get_available_models >&2
      echo "CONFIG_ERROR"
      return 1
    fi
  fi

  # --- Build command as bash array (no temp files, no eval) ---
  local -a cmd=(cursor-agent -p --force --output-format stream-json --model "$MODEL")
  if [[ "$APPROVE_MCPS" == "true" ]]; then
    cmd+=(--approve-mcps)
  fi
  if [[ -n "$session_id" ]]; then
    cmd+=(--resume="$session_id")
    echo "Resuming session: $session_id" >&2
  fi

  # Change to workspace
  cd "$workspace"

  # Install trap for clean shutdown
  trap on_iteration_interrupt HUP INT TERM

  # Start spinner to show we're alive
  spinner "$workspace" &
  _RALPH_SPINNER_PID=$!

  # Start pipeline: cursor-agent | stream-parser -> fifo
  # Pass thresholds as explicit positional args to stream-parser.sh
  (
    "${cmd[@]}" "$prompt" 2>&1 \
      | "$script_dir/stream-parser.sh" "$workspace" "$WARN_THRESHOLD" "$ROTATE_THRESHOLD" > "$fifo"
    echo "${PIPESTATUS[*]}" > "$pipeline_status_file"
  ) &
  _RALPH_AGENT_PID=$!

  # Read signals from parser
  local signal=""
  while IFS= read -r line; do
    case "$line" in
      "ROTATE")
        printf "\r\033[K" >&2
        echo "🔄 Context rotation triggered - stopping agent..." >&2
        stop_process_tree "$_RALPH_AGENT_PID"
        signal="ROTATE"
        break
        ;;
      "WARN")
        printf "\r\033[K" >&2
        echo "⚠️  Context warning - agent should wrap up soon..." >&2
        ;;
      "GUTTER")
        printf "\r\033[K" >&2
        echo "🚨 Gutter detected - agent may be stuck..." >&2
        signal="GUTTER"
        ;;
      "COMPLETE")
        printf "\r\033[K" >&2
        echo "✅ Agent signaled completion!" >&2
        signal="COMPLETE"
        ;;
      "DEFER")
        printf "\r\033[K" >&2
        echo "⏸️  Rate limit or transient error - deferring for retry..." >&2
        signal="DEFER"
        stop_process_tree "$_RALPH_AGENT_PID"
        ;;
    esac
  done < "$fifo"

  # Wait for agent pipeline to finish
  wait "$_RALPH_AGENT_PID" 2>/dev/null || true

  # Stop spinner and clear line
  stop_process_tree "$_RALPH_SPINNER_PID"
  wait "$_RALPH_SPINNER_PID" 2>/dev/null || true
  printf "\r\033[K" >&2

  # Clear trap now that processes are down
  trap - HUP INT TERM
  _RALPH_AGENT_PID=""
  _RALPH_SPINNER_PID=""

  # --- PIPESTATUS inference when no signal was emitted ---
  if [[ -z "$signal" ]] && [[ -f "$pipeline_status_file" ]]; then
    local pstat
    pstat=$(cat "$pipeline_status_file" 2>/dev/null || echo "")
    rm -f "$pipeline_status_file"

    local agent_exit parser_exit
    agent_exit=$(echo "$pstat" | awk '{print $1}')
    parser_exit=$(echo "$pstat" | awk '{print $2}')

    if [[ "${agent_exit:-0}" -ne 0 ]] || [[ "${parser_exit:-0}" -ne 0 ]]; then
      local last_err
      last_err=$(tail -1 "$workspace/.ralph/errors.log" 2>/dev/null || echo "")
      if [[ -n "$last_err" ]] && is_retryable_runtime_error "$last_err"; then
        signal="DEFER"
      else
        signal="GUTTER"
      fi
    fi
  else
    rm -f "$pipeline_status_file"
  fi

  # Cleanup fifo
  rm -f "$fifo"

  echo "$signal"
}

# =============================================================================
# MAIN LOOP
# =============================================================================

# Run the main Ralph loop
# Args: workspace
# Uses global: MAX_ITERATIONS, MODEL, USE_BRANCH, OPEN_PR
run_ralph_loop() {
  local workspace="$1"
  local script_dir="${2:-$(dirname "${BASH_SOURCE[0]}")}"
  
  # Create branch if requested (before checkpoint so commit lands on correct branch)
  if [[ -n "$USE_BRANCH" ]]; then
    echo "🌿 Creating branch: $USE_BRANCH"
    git -C "$workspace" checkout -b "$USE_BRANCH" 2>/dev/null || git -C "$workspace" checkout "$USE_BRANCH"
  fi

  # Commit any uncommitted work (submodule-safe)
  checkpoint_commit_if_needed "$workspace" "ralph: initial commit before loop"
  
  echo ""
  echo "🚀 Starting Ralph loop..."
  echo ""
  
  # Main loop
  local iteration=1
  local session_id=""
  local noop_count=0
  
  while [[ $iteration -le $MAX_ITERATIONS ]]; do
    # Capture HEAD before iteration for no-op detection
    local pre_iteration_sha
    pre_iteration_sha=$(git -C "$workspace" rev-parse HEAD 2>/dev/null || echo "")

    # Run iteration
    local signal
    signal=$(run_iteration "$workspace" "$iteration" "$session_id" "$script_dir")
    
    # Check task completion
    local task_status
    task_status=$(check_task_complete "$workspace")
    
    if [[ "$task_status" == "COMPLETE" ]]; then
      log_progress "$workspace" "**Session $iteration ended** - ✅ TASK COMPLETE"
      echo ""
      echo "═══════════════════════════════════════════════════════════════════"
      echo "🎉 RALPH COMPLETE! All criteria satisfied."
      echo "═══════════════════════════════════════════════════════════════════"
      echo ""
      echo "Completed in $iteration iteration(s)."
      echo "Check git log for detailed history."
      
      # Open PR if requested
      if [[ "$OPEN_PR" == "true" ]] && [[ -n "$USE_BRANCH" ]]; then
        echo ""
        echo "📝 Opening pull request..."
        git push -u origin "$USE_BRANCH" 2>/dev/null || git push
        if command -v gh &> /dev/null; then
          gh pr create --fill || echo "⚠️  Could not create PR automatically. Create manually."
        else
          echo "⚠️  gh CLI not found. Push complete, create PR manually."
        fi
      fi
      
      return 0
    fi
    
    # Handle signals
    case "$signal" in
      "COMPLETE")
        # Agent signaled completion - verify with checkbox check
        if [[ "$task_status" == "COMPLETE" ]]; then
          log_progress "$workspace" "**Session $iteration ended** - ✅ TASK COMPLETE (agent signaled)"
          echo ""
          echo "═══════════════════════════════════════════════════════════════════"
          echo "🎉 RALPH COMPLETE! Agent signaled completion and all criteria verified."
          echo "═══════════════════════════════════════════════════════════════════"
          echo ""
          echo "Completed in $iteration iteration(s)."
          echo "Check git log for detailed history."
          
          # Open PR if requested
          if [[ "$OPEN_PR" == "true" ]] && [[ -n "$USE_BRANCH" ]]; then
            echo ""
            echo "📝 Opening pull request..."
            git push -u origin "$USE_BRANCH" 2>/dev/null || git push
            if command -v gh &> /dev/null; then
              gh pr create --fill || echo "⚠️  Could not create PR automatically. Create manually."
            else
              echo "⚠️  gh CLI not found. Push complete, create PR manually."
            fi
          fi
          
          return 0
        else
          # Agent said complete but checkboxes say otherwise - continue
          log_progress "$workspace" "**Session $iteration ended** - Agent signaled complete but criteria remain"
          echo ""
          echo "⚠️  Agent signaled completion but unchecked criteria remain."
          echo "   Continuing with next iteration..."
          iteration=$((iteration + 1))
        fi
        ;;
      "ROTATE")
        log_progress "$workspace" "**Session $iteration ended** - 🔄 Context rotation (token limit reached)"
        echo ""
        echo "🔄 Rotating to fresh context..."
        iteration=$((iteration + 1))
        session_id=""
        ;;
      "GUTTER")
        log_progress "$workspace" "**Session $iteration ended** - 🚨 GUTTER (agent stuck)"
        echo ""
        echo "🚨 Gutter detected. Check .ralph/errors.log for details."
        echo "   The agent may be stuck. Consider:"
        echo "   1. Check .ralph/guardrails.md for lessons"
        echo "   2. Manually fix the blocking issue"
        echo "   3. Re-run the loop"
        return 1
        ;;
      "CONFIG_ERROR")
        log_progress "$workspace" "**Loop ended** - Configuration error"
        echo "Fix the configuration error above and re-run." >&2
        return 1
        ;;
      "DEFER")
        # Rate limit or transient error - wait with exponential backoff then retry
        log_progress "$workspace" "**Session $iteration ended** - ⏸️ DEFERRED (rate limit/transient error)"
        
        # Calculate backoff delay (uses ralph-retry.sh functions if available)
        local defer_delay=30
        if type calculate_backoff_delay &>/dev/null; then
          local defer_attempt=${DEFER_COUNT:-1}
          DEFER_COUNT=$((defer_attempt + 1))
          defer_delay=$(($(calculate_backoff_delay "$defer_attempt" 15 120 true) / 1000))
        fi
        
        echo ""
        echo "⏸️  Rate limit or transient error detected."
        echo "   Waiting ${defer_delay}s before retrying (attempt ${DEFER_COUNT:-1})..."
        sleep "$defer_delay"
        
        # Don't increment iteration - retry the same task
        echo "   Resuming..."
        ;;
      *)
        # Agent finished naturally, check if more work needed
        if [[ "$task_status" == INCOMPLETE:* ]]; then
          local remaining_count=${task_status#INCOMPLETE:}
          log_progress "$workspace" "**Session $iteration ended** - Agent finished naturally ($remaining_count criteria remaining)"
          echo ""
          echo "📋 Agent finished but $remaining_count criteria remaining."

          # No-op detection: check whether any commits were produced
          if [[ -n "$pre_iteration_sha" ]]; then
            local commits_this_iteration
            commits_this_iteration=$(git -C "$workspace" rev-list --count HEAD ^"${pre_iteration_sha}" 2>/dev/null || echo "0")

            if [[ "$commits_this_iteration" -eq 0 ]]; then
              noop_count=$((noop_count + 1))
              echo "⚠️  Iteration $iteration produced no commits (${noop_count} consecutive no-ops)." >&2
              if [[ $noop_count -ge 3 ]]; then
                log_progress "$workspace" "**Loop ended** - 🚨 ${noop_count} consecutive no-op iterations"
                echo "ERROR: ${noop_count} consecutive iterations produced no work. Aborting." >&2
                return 1
              fi
            else
              noop_count=0
            fi
          fi

          echo "   Starting next iteration..."
          iteration=$((iteration + 1))
        fi
        ;;
    esac
    
    # Brief pause between iterations
    sleep 2
  done
  
  log_progress "$workspace" "**Loop ended** - ⚠️ Max iterations ($MAX_ITERATIONS) reached"
  echo ""
  echo "⚠️  Max iterations ($MAX_ITERATIONS) reached."
  echo "   Task may not be complete. Check progress manually."
  return 1
}

# =============================================================================
# PREREQUISITE CHECKS
# =============================================================================

# Check all prerequisites, exit with error message if any fail
check_prerequisites() {
  local workspace="$1"
  local task_file="$workspace/RALPH_TASK.md"
  
  # Check for task file
  if [[ ! -f "$task_file" ]]; then
    echo "❌ No RALPH_TASK.md found in $workspace"
    echo ""
    echo "Create a task file first:"
    echo "  cat > RALPH_TASK.md << 'EOF'"
    echo "  ---"
    echo "  task: Your task description"
    echo "  test_command: \"pnpm test\""
    echo "  ---"
    echo "  # Task"
    echo "  ## Success Criteria"
    echo "  1. [ ] First thing to do"
    echo "  2. [ ] Second thing to do"
    echo "  EOF"
    return 1
  fi
  
  # Check for cursor-agent CLI
  if ! command -v cursor-agent &> /dev/null; then
    echo "❌ cursor-agent CLI not found"
    echo ""
    echo "Install via:"
    echo "  curl https://cursor.com/install -fsS | bash"
    return 1
  fi
  
  # Check for git repo
  if ! git -C "$workspace" rev-parse --git-dir > /dev/null 2>&1; then
    echo "❌ Not a git repository"
    echo "   Ralph requires git for state persistence."
    return 1
  fi
  
  return 0
}

# =============================================================================
# DISPLAY HELPERS
# =============================================================================

# Show task summary
show_task_summary() {
  local workspace="$1"
  local task_file="$workspace/RALPH_TASK.md"
  
  echo "📋 Task Summary:"
  echo "─────────────────────────────────────────────────────────────────"
  head -30 "$task_file"
  echo "─────────────────────────────────────────────────────────────────"
  echo ""
  
  # Count criteria - only actual checkbox list items (- [ ], * [x], 1. [ ], etc.)
  local total_criteria done_criteria remaining
  total_criteria=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x| )\]' "$task_file" 2>/dev/null) || total_criteria=0
  done_criteria=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[x\]' "$task_file" 2>/dev/null) || done_criteria=0
  remaining=$((total_criteria - done_criteria))
  
  echo "Progress: $done_criteria / $total_criteria criteria complete ($remaining remaining)"
  echo "Model:    $MODEL"
  echo ""
  
  # Return remaining count for caller to check
  echo "$remaining"
}

# Show Ralph banner
show_banner() {
  echo "═══════════════════════════════════════════════════════════════════"
  echo "🐛 Ralph Wiggum: Autonomous Development Loop"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  echo "  \"That's the beauty of Ralph - the technique is deterministically"
  echo "   bad in an undeterministic world.\""
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
}
