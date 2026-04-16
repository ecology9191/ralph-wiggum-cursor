# Ralph Wiggum for Cursor

An implementation of [Geoffrey Huntley's Ralph Wiggum technique](https://ghuntley.com/ralph/) for Cursor, enabling autonomous AI development with deliberate context management.

> "That's the beauty of Ralph - the technique is deterministically bad in an undeterministic world."

## What is Ralph?

Ralph is a technique for autonomous AI development that treats LLM context like memory:

```bash
while :; do cat PROMPT.md | agent ; done
```

The same prompt is fed repeatedly to an AI agent. Progress persists in **files and git**, not in the LLM's context window. When context fills up, you get a fresh agent with fresh context.

### The malloc/free Problem

In traditional programming:
- `malloc()` allocates memory
- `free()` releases memory

In LLM context:
- Reading files, tool outputs, conversation = `malloc()`
- **There is no `free()`** - context cannot be selectively released
- Only way to free: start a new conversation

This creates two problems:

1. **Context pollution** - Failed attempts, unrelated code, and mixed concerns accumulate and confuse the model
2. **The gutter** - Once polluted, the model keeps referencing bad context. Like a bowling ball in the gutter, there's no saving it.

**Ralph's solution:** Deliberately rotate to fresh context before pollution builds up. State lives in files and git, not in the LLM's memory.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      ralph-setup.sh                          │
│                           │                                  │
│              ┌────────────┴────────────┐                    │
│              ▼                         ▼                    │
│         [gum UI]                  [fallback]                │
│     Model selection            Simple prompts               │
│     Max iterations                                          │
│     Options (branch, PR)                                    │
│              │                         │                    │
│              └────────────┬────────────┘                    │
│                           ▼                                  │
│    cursor-agent -p --force --output-format stream-json       │
│                           │                                  │
│                           ▼                                  │
│                   stream-parser.sh                           │
│                      │        │                              │
│     ┌────────────────┴────────┴────────────────┐            │
│     ▼                                           ▼            │
│  .ralph/                                    Signals          │
│  ├── activity.log  (tool calls)            ├── WARN at 70k  │
│  ├── errors.log    (failures)              ├── ROTATE at 80k│
│  ├── progress.md   (agent writes)          ├── COMPLETE     │
│  ├── guardrails.md (lessons learned)       ├── GUTTER       │
│  └── tasks.yaml    (cached task state)     └── DEFER        │
│                                                              │
│  When ROTATE → fresh context, continue from git             │
│  When DEFER → exponential backoff, retry same task          │
└─────────────────────────────────────────────────────────────┘
```

**Key features:**
- **Interactive setup** - Beautiful gum-based UI for model selection and options
- **Accurate token tracking** - Parser counts actual bytes from every file read/write
- **Gutter detection** - Detects when agent is stuck (same command failed 3x, file thrashing)
- **Rate limit handling** - Detects rate limits/network errors, waits with exponential backoff
- **Task caching** - YAML backend with mtime invalidation for efficient task parsing
- **Learning from failures** - Agent updates `.ralph/guardrails.md` with lessons
- **State in git** - Commits frequently so next agent picks up from git history
- **Branch/PR workflow** - Optionally work on a branch and open PR when complete

## Prerequisites

| Requirement | Check | How to Set Up |
|-------------|-------|---------------|
| **Git repo** | `git status` works | `git init` |
| **cursor-agent CLI** | `which cursor-agent` | `curl https://cursor.com/install -fsS \| bash` |
| **gum** (optional) | `which gum` | Installer offers to install, or `brew install gum` |

## Quick Start

### 1. Install Ralph

```bash
cd your-project
curl -fsSL https://raw.githubusercontent.com/agrimsingh/ralph-wiggum-cursor/main/install.sh | bash
```

This creates:
```
your-project/
├── .cursor/ralph-scripts/      # Ralph scripts
│   ├── ralph-setup.sh          # Main entry point (interactive)
│   ├── ralph-loop.sh           # CLI mode (for scripting)
│   ├── ralph-once.sh           # Single iteration (testing)
│   ├── ralph-parallel.sh       # Parallel execution with worktrees
│   ├── stream-parser.sh        # Token tracking + error detection
│   ├── ralph-common.sh         # Shared functions
│   ├── ralph-retry.sh          # Exponential backoff retry logic
│   ├── task-parser.sh          # YAML-backed task parsing
│   └── init-ralph.sh           # Re-initialize if needed
├── .ralph/                     # State files (tracked in git)
│   ├── progress.md             # Agent updates: what's done
│   ├── guardrails.md           # Lessons learned (Signs)
│   ├── activity.log            # Tool call log (parser writes)
│   ├── errors.log              # Failure log (parser writes)
│   └── tasks.yaml              # Cached task state (auto-generated)
├── .ralph-worktrees/           # Temporary (parallel mode only)
└── RALPH_TASK.md               # Your task definition
```

### 2. (Optional) gum for Enhanced UI

The installer will offer to install gum automatically. You can also:
- Skip the prompt and auto-install: `curl ... | INSTALL_GUM=1 bash`
- Install manually: `brew install gum` (macOS) or see [gum installation](https://github.com/charmbracelet/gum#installation)

With gum, you get a beautiful interactive menu for selecting models and options:

```
? Select model:
  ◉ composer-2                        ← list auto-populated from cursor-agent --list-models
  ◯ claude-4.6-opus-max-thinking
  ◯ gpt-5.2-high
  ◯ claude-4.5-sonnet-thinking
  ◯ Custom...

? Max iterations: 20

? Options:
  ◯ Commit to current branch
  ◯ Run single iteration first
  ◯ Work on new branch
  ◯ Open PR when complete
  ◯ Run in parallel mode         ← runs multiple agents concurrently
```

If you select "Run in parallel mode", you'll be prompted for:

```
? Max parallel agents: 3         ← default is 3, enter any number
```

Without gum, Ralph falls back to simple numbered prompts.

### 3. Define Your Task

Edit `RALPH_TASK.md`:

```markdown
---
task: Build a REST API
test_command: "pnpm test"
---

# Task: REST API

Build a REST API with user management.

## Success Criteria

1. [ ] GET /health returns 200
2. [ ] POST /users creates a user  
3. [ ] GET /users/:id returns user
4. [ ] All tests pass

## Context

- Use Express.js
- Store users in memory (no database needed)
```

**Important:** Use `[ ]` checkboxes. Ralph tracks completion by counting unchecked boxes.

### 4. Start the Loop

```bash
./.cursor/ralph-scripts/ralph-setup.sh
```

Ralph will:
1. Show interactive UI for model and options (or simple prompts if gum not installed)
2. Run `cursor-agent` with your task
3. Parse output in real-time, tracking token usage
4. At 70k tokens: warn agent to wrap up current work
5. At 80k tokens: rotate to fresh context
6. Repeat until all `[ ]` are `[x]` (or max iterations reached)

### 5. Monitor Progress

```bash
# Watch activity in real-time
tail -f .ralph/activity.log

# Example output:
# [12:34:56] 🟢 READ src/index.ts (245 lines, ~24.5KB)
# [12:34:58] 🟢 WRITE src/routes/users.ts (50 lines, 2.1KB)
# [12:35:01] 🟢 SHELL pnpm test → exit 0
# [12:35:10] 🟢 TOKENS: 45,230 / 80,000 (56%) [read:30KB write:5KB assist:10KB shell:0KB]

# Check for failures
cat .ralph/errors.log
```

## Commands

| Command | Description |
|---------|-------------|
| `ralph-setup.sh` | **Primary** - Interactive setup + run loop |
| `ralph-once.sh` | Test single iteration before going AFK |
| `ralph-loop.sh` | CLI mode for scripting (see flags below) |
| `init-ralph.sh` | Re-initialize Ralph state |

### ralph-loop.sh Flags (for scripting/CI)

```bash
./ralph-loop.sh [options] [workspace]

Options:
  -n, --iterations N     Max iterations (default: 20)
  -m, --model MODEL      Model to use (default: auto-detected via cursor-agent)
  --branch NAME          Sequential: create/work on branch; Parallel: integration branch name
  --pr                   Sequential: open PR (requires --branch); Parallel: open ONE integration PR (branch optional)
  --parallel             Run tasks in parallel with worktrees
  --max-parallel N       Max parallel agents (default: 3)
  --no-merge             Skip auto-merge in parallel mode
  -y, --yes              Skip confirmation prompt
```

**Examples:**

```bash
# Scripted PR workflow
./ralph-loop.sh --branch feature/api --pr -y

# Use a different model with more iterations
./ralph-loop.sh -n 50 -m composer-2

# Run 4 agents in parallel
./ralph-loop.sh --parallel --max-parallel 4

# Parallel: keep branches separate
./ralph-loop.sh --parallel --no-merge

# Parallel: merge into an integration branch + open ONE PR
./ralph-loop.sh --parallel --max-parallel 5 --branch feature/multi-task --pr

# Parallel: open ONE PR using an auto-named integration branch
./ralph-loop.sh --parallel --max-parallel 5 --pr
```

## Parallel Execution

Ralph can run multiple agents concurrently, each in an isolated git worktree.

### Starting Parallel Mode

**Via gum UI (interactive):**
```bash
./ralph-setup.sh
# Select "Run in parallel mode" in options
# Enter number of agents when prompted (default: 3, no upper limit)
```

**Via CLI (scripting/CI):**
```bash
# Run 3 agents in parallel (default)
./ralph-loop.sh --parallel

# Run 10 agents in parallel (no hard cap)
./ralph-loop.sh --parallel --max-parallel 10

# Keep branches separate (no auto-merge)
./ralph-loop.sh --parallel --no-merge

# Merge into an integration branch (no PR)
./ralph-loop.sh --parallel --max-parallel 5 --branch feature/multi-task

# Merge into an integration branch and open ONE PR
./ralph-loop.sh --parallel --max-parallel 5 --branch feature/multi-task --pr

# Open ONE PR using an auto-named integration branch
./ralph-loop.sh --parallel --max-parallel 5 --pr
```

> **Note:** There's no hard limit on `--max-parallel`. The practical limit depends on your machine's resources and API rate limits.

### Integration branch + single PR

Parallel `--pr` creates **one integration branch** (either your `--branch NAME` or an auto-named `ralph/parallel-<run_id>`), merges all successful agent branches into it, then opens **one PR** back to the base branch.

This avoids “one PR per task” spam while keeping agents isolated.

### How Parallel Mode Works

```
┌────────────────────────────────────────────────────────────────┐
│                    Parallel Execution Flow                      │
├────────────────────────────────────────────────────────────────┤
│                                                                  │
│  RALPH_TASK.md                                                  │
│  - [ ] Task A                                                    │
│  - [ ] Task B           ┌──────────────────────────┐            │
│  - [ ] Task C     ───▶  │   Create Worktrees       │            │
│                         └──────────────────────────┘            │
│                                    │                             │
│                    ┌───────────────┼───────────────┐            │
│                    ▼               ▼               ▼            │
│              ┌──────────┐   ┌──────────┐   ┌──────────┐         │
│              │ Agent 1  │   │ Agent 2  │   │ Agent 3  │         │
│              │ worktree │   │ worktree │   │ worktree │         │
│              │  Task A  │   │  Task B  │   │  Task C  │         │
│              └────┬─────┘   └────┬─────┘   └────┬─────┘         │
│                   │              │              │                │
│                   ▼              ▼              ▼                │
│              branch-a       branch-b       branch-c              │
│                   │              │              │                │
│                   └──────────────┼──────────────┘                │
│                                  ▼                               │
│                         ┌──────────────┐                        │
│                         │  Auto-Merge  │                        │
│                         │  to base     │                        │
│                         └──────────────┘                        │
└────────────────────────────────────────────────────────────────┘
```

**Key benefits:**
- Each agent works in complete isolation (separate git worktree)
- No interference between agents working on different tasks
- Branches auto-merge after completion (or keep separate with `--no-merge`)
- Conflict detection and reporting
- Tasks are processed in batches (e.g., 5 agents = 5 tasks per batch)
- In parallel mode, agents do **not** update `.ralph/progress.md` (they write per-agent reports instead)

**When to use parallel mode:**
- Multiple independent tasks that don't conflict
- Large task lists you want completed faster
- CI/CD pipelines with parallelization budget

**When to use sequential mode:**
- Tasks that depend on each other
- Single complex task that needs focused attention
- Limited API rate limits

### Recommended Workflow: Parallel + Integration Pass

For best results, structure your work in two phases:

**Phase 1: Parallel execution** (isolated, independent tasks)
```markdown
# Tasks
- [ ] Add user authentication to /api/auth
- [ ] Create dashboard component
- [ ] Implement data export feature
- [ ] Add unit tests for utils/
```

**Phase 2: Integration pass** (one sequential agent, repo-wide polish)
```markdown
# Tasks
- [ ] Update README with new features
- [ ] Bump version in package.json
- [ ] Update CHANGELOG
- [ ] Fix any integration issues from parallel work
```

This pattern maximizes parallelism while avoiding merge conflicts on shared files.
The integration pass runs after parallel agents finish and handles all "touch everything" work.

### Task Groups (Phased Execution)

Control execution order with `<!-- group: N -->` annotations:

```markdown
# Tasks

- [ ] Create database schema <!-- group: 1 -->
- [ ] Create User model <!-- group: 1 -->
- [ ] Create Post model <!-- group: 1 -->
- [ ] Add relationships between models <!-- group: 2 -->
- [ ] Build API endpoints <!-- group: 3 -->
- [ ] Update README  # no annotation = runs LAST
```

**Execution order:**
1. Group 1 - runs first (all tasks in parallel, up to `--max-parallel`)
2. Group 2 - runs after group 1 merges complete
3. Group 3 - runs after group 2 merges complete
4. Unannotated tasks - run LAST (after all annotated groups)

**Why unannotated = last?**
- Safer default: forgetting to annotate doesn't jump the queue
- Integration/polish tasks naturally go last
- Override with `DEFAULT_GROUP=0` env var if you prefer unannotated first

**Within each group:**
- Tasks run in parallel (up to `--max-parallel`)
- All merges complete before next group starts
- RALPH_TASK.md checkboxes updated per group

**Worktree structure:**
```
project/
├── .ralph-worktrees/           # Temporary worktrees (auto-cleaned)
│   ├── <run_id>-job1/          # Agent worktree (isolated)
│   ├── <run_id>-job2/          # Agent worktree (isolated)
│   └── <run_id>-job3/          # Agent worktree (isolated)
└── (original project files)
```

Worktrees are automatically cleaned up after agents complete. Failed agents preserve their worktree for manual inspection.

### Parallel logs & per-agent reports

Each parallel run creates a run directory:

```
.ralph/parallel/<run_id>/
├── manifest.tsv                # job_id -> task_id -> branch -> status -> log
└── jobN.log                    # full cursor-agent output for that job
```

Agents are instructed to write a committed per-agent report (to avoid `.ralph/progress.md` merge conflicts):

```
.ralph/parallel/<run_id>/agent-jobN.md
```

## How It Works

### The Loop

```
Iteration 1                    Iteration 2                    Iteration N
┌──────────────────┐          ┌──────────────────┐          ┌──────────────────┐
│ Fresh context    │          │ Fresh context    │          │ Fresh context    │
│       │          │          │       │          │          │       │          │
│       ▼          │          │       ▼          │          │       ▼          │
│ Read RALPH_TASK  │          │ Read RALPH_TASK  │          │ Read RALPH_TASK  │
│ Read guardrails  │──────────│ Read guardrails  │──────────│ Read guardrails  │
│ Read progress    │  (state  │ Read progress    │  (state  │ Read progress    │
│       │          │  in git) │       │          │  in git) │       │          │
│       ▼          │          │       ▼          │          │       ▼          │
│ Work on criteria │          │ Work on criteria │          │ Work on criteria │
│ Commit to git    │          │ Commit to git    │          │ Commit to git    │
│       │          │          │       │          │          │       │          │
│       ▼          │          │       ▼          │          │       ▼          │
│ 80k tokens       │          │ 80k tokens       │          │ All [x] done!    │
│ ROTATE ──────────┼──────────┼──────────────────┼──────────┼──► COMPLETE      │
└──────────────────┘          └──────────────────┘          └──────────────────┘
```

Each iteration:
1. Reads task and state from files (not from previous context)
2. Works on unchecked criteria
3. Commits progress to git
4. Updates `.ralph/progress.md` and `.ralph/guardrails.md`
5. Rotates when context is full

### Git Protocol

The agent is instructed to commit frequently:

```bash
# After each criterion
git add -A && git commit -m 'ralph: [criterion] - description'

# Push periodically
git push
```

**Commits are the agent's memory.** The next iteration picks up from git history.

### The Learning Loop (Signs)

When something fails, the agent adds a "Sign" to `.ralph/guardrails.md`:

```markdown
### Sign: Check imports before adding
- **Trigger**: Adding a new import statement
- **Instruction**: First check if import already exists in file
- **Added after**: Iteration 3 - duplicate import caused build failure
```

Future iterations read guardrails first and follow them, preventing repeated mistakes.

```
Error occurs → errors.log → Agent analyzes → Updates guardrails.md → Future agents follow
```

## Context Health Indicators

The activity log shows context health with emoji:

| Emoji | Status | Token % | Meaning |
|-------|--------|---------|---------|
| 🟢 | Healthy | < 60% | Plenty of room |
| 🟡 | Warning | 60-80% | Approaching limit |
| 🔴 | Critical | > 80% | Rotation imminent |

Example:
```
[12:34:56] 🟢 READ src/index.ts (245 lines, ~24.5KB)
[12:40:22] 🟡 TOKENS: 58,000 / 80,000 (72%) - approaching limit [read:40KB write:8KB assist:10KB shell:0KB]
[12:45:33] 🔴 TOKENS: 72,500 / 80,000 (90%) - rotation imminent
```

## Gutter Detection

The parser detects when the agent is stuck:

| Pattern | Trigger | What Happens |
|---------|---------|--------------|
| Repeated failure | Same command failed 3x | GUTTER signal |
| File thrashing | Same file written 5x in 10 min | GUTTER signal |
| Agent signals | Agent outputs `<ralph>GUTTER</ralph>` | GUTTER signal |

When gutter is detected:
1. Check `.ralph/errors.log` for the pattern
2. Fix the issue manually or add a guardrail
3. Re-run the loop

## Rate Limit & Transient Error Handling

The parser detects retryable API errors and handles them gracefully:

| Error Type | Examples | What Happens |
|------------|----------|--------------|
| Rate limits | 429, "rate limit exceeded", "quota" | DEFER signal |
| Network errors | timeout, connection reset, ECONNRESET | DEFER signal |
| Server errors | 502, 503, 504, "service unavailable" | DEFER signal |

When DEFER is triggered:
1. Agent stops current iteration
2. Waits with **exponential backoff** (15s base, doubles each retry, max 120s)
3. Adds jitter (0-25%) to prevent thundering herd
4. Retries the same task (does not increment iteration)

Example log:
```
⏸️  Rate limit or transient error detected.
   Waiting 32s before retrying (attempt 2)...
   Resuming...
```

## Completion Detection

Ralph detects completion in two ways:

1. **Checkbox check**: All `[ ]` in RALPH_TASK.md changed to `[x]`
2. **Agent sigil**: Agent outputs `<ralph>COMPLETE</ralph>`

Both are verified before declaring success.

## File Reference

| File | Purpose | Who Uses It |
|------|---------|-------------|
| `RALPH_TASK.md` | Task definition + success criteria | You define, agent reads |
| `.ralph/progress.md` | What's been accomplished | Agent writes after work |
| `.ralph/guardrails.md` | Lessons learned (Signs) | Agent reads first, writes after failures |
| `.ralph/activity.log` | Tool call log with token counts | Parser writes, you monitor |
| `.ralph/errors.log` | Failures + gutter detection | Parser writes, agent reads |
| `.ralph/tasks.yaml` | Cached task state (auto-generated) | Task parser writes/reads |
| `.ralph/tasks.mtime` | Task file modification time | Cache invalidation |
| `.ralph/.iteration` | Current iteration number | Parser reads/writes |

## Configuration

Configuration is set via command-line flags or environment variables:

```bash
# Via flags (recommended)
./ralph-loop.sh -n 50 -m composer-2

# Via environment
RALPH_MODEL=composer-2 MAX_ITERATIONS=50 ./ralph-loop.sh
```

| Variable | Default | Description |
|----------|---------|-------------|
| `RALPH_MODEL` | auto-detected | Model slug for `cursor-agent`. Skips the interactive model prompt when set. |
| `MAX_ITERATIONS` | `20` | Max rotations before giving up |
| `WARN_THRESHOLD` | `70000` | Token count at which the agent receives a wrap-up warning |
| `ROTATE_THRESHOLD` | `80000` | Token count at which context is force-rotated |
| `RALPH_FORCE_MODEL` | unset | Set to `true` to bypass model validation (use when the model is valid but not in `cursor-agent --list-models`) |
| `SKIP_CONFIRM` | `false` | Set to `true` to skip the "Start Ralph loop?" confirmation in `ralph-setup.sh` |

All threshold and iteration variables are exported to child processes (e.g. `stream-parser.sh`), so overrides set in the parent shell take effect everywhere.

## Troubleshooting

### "cursor-agent CLI not found"

```bash
curl https://cursor.com/install -fsS | bash
```

### Agent keeps failing on same thing

Check `.ralph/errors.log` for the pattern. Either:
1. Fix the underlying issue manually
2. Add a guardrail to `.ralph/guardrails.md` explaining what to do differently

### Context rotates too frequently

The agent might be reading too many large files. Check `activity.log` for large READs and consider:
1. Adding a guardrail: "Don't read the entire file, use grep to find relevant sections"
2. Breaking the task into smaller pieces

### Loop exits with "Model is not available"

The model name doesn't match any slug from `cursor-agent --list-models`. Either fix the name or bypass validation:

```bash
RALPH_FORCE_MODEL=true RALPH_MODEL=my-custom-model ./ralph-loop.sh
```

### Loop exits with "consecutive no-op iterations"

Three consecutive iterations produced no git commits. This usually means the agent is running but not making progress. Check `.ralph/activity.log` and `.ralph/errors.log` for clues, then fix the blocking issue and re-run.

### Task never completes

Check if criteria are too vague. Each criterion should be:
- Specific and testable
- Achievable in a single iteration
- Not dependent on manual steps

## Workflows

### Basic (default)

```bash
./ralph-setup.sh  # Interactive setup → runs loop → done
```

### Human-in-the-loop (recommended for new tasks)

```bash
./ralph-once.sh   # Run ONE iteration
# Review changes...
./ralph-setup.sh  # Continue with full loop
```

### Scripted/CI

```bash
./ralph-loop.sh --branch feature/foo --pr -y
```

## Learn More

- [Original Ralph technique](https://ghuntley.com/ralph/) - Geoffrey Huntley
- [Context as memory](https://ghuntley.com/allocations/) - The malloc/free metaphor
- [Cursor CLI docs](https://cursor.com/docs/cli/headless)
- [gum - A tool for glamorous shell scripts](https://github.com/charmbracelet/gum)

## Credits

- **Original technique**: [Geoffrey Huntley](https://ghuntley.com/ralph/) - the Ralph Wiggum methodology
- **Cursor port**: [Agrim Singh](https://x.com/agrimsingh) - this implementation

## License

MIT
