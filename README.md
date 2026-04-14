# Terra

A multi-agent orchestrator for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Terra coordinates multiple Claude Code sessions working in parallel on the same codebase, using git worktrees for isolation and tmux for session management.

## How It Works

```
You ←→ Mayor (Claude Code, long-running)
              ├── Worker Agent 1 (coder, in worktree)
              ├── Worker Agent 2 (planner, in worktree)
              ├── Worker Agent 3 (reviewer, in worktree)
              └── Sub-Mayor (bash, autonomous pipeline)
                    ├── Agent 4 → auto-merge
                    └── Agent 5 → auto-merge
```

**Mayor** — A persistent Claude Code session that acts as orchestrator. You talk to the Mayor, it breaks your goal into tasks, spawns worker agents, monitors progress, and merges results.

**Worker Agents** — Independent Claude Code sessions, each running in a git worktree with its own branch. They read a task file (`.task.json`), do the work, commit, and mark themselves done.

**Sub-Mayor** — A bash script that autonomously manages a pipeline: spawning agents wave-by-wave, respecting dependencies, retrying failures, and auto-merging completed work. No human in the loop.

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`claude` command available)
- `tmux`
- `jq`
- `git`
- macOS or Linux

Optional:
- [`ccusage`](https://github.com/ryoppippi/ccusage) — for per-agent cost tracking

## Quickstart

### 1. Clone and set up

```bash
git clone <this-repo> Terra
cd Terra
cp .env.sample .env
# Edit .env if you want to change defaults
```

### 2. Add a project

Clone or symlink a git repo into `projects/`:

```bash
git clone https://github.com/you/my-app.git projects/my-app
```

### 3. Create a task

```bash
cp examples/sample-task.json tasks/queue/task-demo1.json
# Edit the task to describe what you want built
```

Then move it to `tasks/active/` when ready to assign:

```bash
mv tasks/queue/task-demo1.json tasks/active/
```

### 4. Spawn an agent

```bash
bash scripts/spawn-agent.sh my-app task-demo1 coder
```

This:
- Creates a git worktree at `projects/my-app/worktrees/task-demo1`
- Copies the `coder` role into the worktree's `.claude/CLAUDE.md`
- Copies the task file into `.task.json`
- Launches a Claude Code session in a tmux session named `terra-task-demo1`

### 5. Monitor

```bash
# Dashboard showing all agents, status, cost
bash scripts/check-agents.sh

# Attach to watch an agent work
tmux attach -t terra-task-demo1

# Tail an agent's log
tail -f logs/task-demo1.log
```

### 6. Merge completed work

```bash
bash scripts/merge-work.sh my-app task-demo1
```

This merges the agent's branch into main, harvests cost data, and moves the task to `tasks/done/`.

## Running the Mayor

For the full orchestrator experience, start the Mayor as a persistent Claude Code session:

```bash
bash scripts/start-mayor.sh
```

The Mayor reads `CLAUDE.md` and becomes your orchestrator. Tell it what you want to build, and it will:
1. Break the goal into tasks
2. Create task files and assign roles
3. Spawn worker agents
4. Monitor progress, retry failures
5. Merge completed work

### Watchdog (optional)

Auto-restart the Mayor if it crashes or hangs:

```bash
# Edit the plist to set your Terra path
vim scripts/com.terra.watchdog.plist

# Install (macOS)
cp scripts/com.terra.watchdog.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.terra.watchdog.plist
```

## Concepts

### Tasks

Tasks are JSON files that move through directories as they progress:

```
tasks/queue/    → pending, waiting for dependencies
tasks/active/   → assigned to an agent, work in progress
tasks/done/     → completed and merged
```

Each task specifies a `role` (which agent template to use), `depends_on` (task IDs that must complete first), and `acceptance` (how to verify completion).

### Roles

Roles are markdown files in `agents/roles/` that define an agent's identity, scope, and constraints. They become the agent's `CLAUDE.md` at spawn time.

**Templates** (`agents/roles/_templates/`) — Generic archetypes:
- `coder.md` — Implements features and fixes
- `planner.md` — Produces implementation plans and product specs
- `explorer.md` — Scans codebases, produces structured maps
- `researcher.md` — Investigates questions, produces findings
- `reviewer.md` — Reviews code for correctness and security

**Active** (`agents/roles/active/`) — Ready-to-use roles including visual coding, security review, code auditing, and more. Create your own here for project-specific needs.

### Model Tiering

Each role specifies a model (`haiku`, `sonnet`, `opus`). The spawn script reads this and passes it to Claude Code:

| Model | Use For |
|---|---|
| **haiku** | Scanning, indexing, simple transforms |
| **sonnet** | Standard coding, most tasks (default) |
| **opus** | Architecture, complex refactors, security |

### Pipelines

The recommended pattern for complex work:

```
Explorer (haiku) → Planner (opus) → Debater (opus) → Coder (sonnet) → Reviewer (opus)
```

The **Sub-Mayor** (`scripts/sub-mayor.sh`) automates this. It:
- Spawns tasks respecting `depends_on` ordering
- Limits concurrency (default: 4 agents)
- Auto-merges completed worktrees
- Retries failed tasks (up to 2 retries, with predecessor log context)
- Discovers new tasks created mid-pipeline by planner agents

```bash
# Create a planner task, then let sub-mayor handle everything
tmux new-session -d -s terra-sub-mayor-feat \
  "bash scripts/sub-mayor.sh feat my-app task-feat01"
tail -f logs/sub-mayor-feat.log
```

### Project Wikis

`wikis/<project>/` stores persistent knowledge about each project (architecture, data models, conventions). Agents read these on startup instead of re-exploring the codebase. Update wikis after significant changes.

## Scripts Reference

| Script | Purpose |
|---|---|
| `spawn-agent.sh` | Create worktree + launch agent in tmux |
| `sub-mayor.sh` | Autonomous pipeline orchestrator |
| `check-agents.sh` | Dashboard: status, cost, logs |
| `merge-work.sh` | Merge agent branch + harvest cost |
| `merge-queue.sh` | Auto-merge all clean done tasks |
| `run-janitor.sh` | Detect stale tasks, dead agents, orphaned worktrees |
| `list-tasks.sh` | Task board (queue/active/done) |
| `cost-report.sh` | Cost aggregation by task/role/model |
| `start-mayor.sh` | Launch Mayor in tmux |
| `watchdog.sh` | Health check + auto-restart |
| `state-save.sh` | PostToolUse heartbeat hook |

## Configuration

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `TERRA_MAX_AGENTS` | `8` | Max concurrent agents |
| `TERRA_MODEL` | `opus` | Model for the Mayor session |
| `TELEGRAM_BOT_TOKEN` | — | Optional: Telegram alerts |
| `TELEGRAM_USER_ID` | — | Optional: Telegram recipient |

### PostToolUse Hook

For the heartbeat and session state to work, add this to your `.claude/settings.local.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash /path/to/Terra/scripts/state-save.sh"
          }
        ]
      }
    ]
  }
}
```

## Creating Custom Roles

1. Copy a template: `cp agents/roles/_templates/coder.md agents/roles/active/my-role.md`
2. Edit the frontmatter (name, model, tools)
3. Write the role body (identity, scope, constraints, quality bar)
4. Reference the role name in your task files

## License

MIT
