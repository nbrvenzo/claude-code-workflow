# Claude Code starter workflow

A small, opinionated Claude Code setup based on Lydia Hallie's talk
["Rethinking Claude Code Best Practices"](https://www.youtube.com/watch?v=vlfCjWuv4es).
The idea: stop babysitting every permission prompt. Let Claude run on its own,
put hard guardrails around the few things that can really hurt, and let the
checks decide when work is done instead of Claude's own judgment.

```
.claude/
├── settings.json             # permission mode, sandbox, deny rules, hook registration
└── hooks/
    └── require-checks.sh     # Stop hook: no finishing while checks fail
CLAUDE.md                     # template: only what Claude can't infer from the code
```

## The files

### `.claude/settings.json`

- **`permissions.defaultMode: "auto"`** runs Claude in auto mode, so it isn't
  stopped by a prompt on every routine command.
- **`sandbox.enabled: true`** sandboxes Bash commands, restricting filesystem
  and network access. That is the real safety net in auto mode.
- **`permissions.deny`** blocks things you never want done on autopilot:
  - force-pushes (`--force`, `-f`, `--force-with-lease`)
  - pushing directly to `main` / `master`
  - `git reset --hard`, `git clean -fd`
  - `sudo`
  - `terraform apply` / `terraform destroy`
  - `kubectl delete`
  - reading or editing `.env` / `.env.*` files and anything under `secrets/`
- **`hooks.Stop`** registers `require-checks.sh` so it runs every time Claude
  tries to finish.
- **`hooks.TaskCompleted`** runs `require-checks.sh --quick` (lint and
  typecheck, no tests) whenever a task is marked complete. This is what checks
  agent-team teammates. It also fires in a normal session when Claude ticks off
  a task on its task list.

> Bash deny rules match command **prefixes**, so a determined variant (for
> example `git -C . push --force`) can slip past them. Treat them as guardrails,
> not a security boundary. The sandbox and your branch protection on the remote
> are the real enforcement, so turn on branch protection for `main` too.

### `.claude/hooks/require-checks.sh`

A **Stop hook**. When Claude tries to end its turn, the hook runs your project's
checks:

| Result              | Exit code | Effect                                                         |
|---------------------|-----------|----------------------------------------------------------------|
| All checks pass     | `0`       | Claude stops normally.                                         |
| Nothing to check    | `0`       | Claude stops normally.                                         |
| Any check fails     | **`2`**   | Claude is **blocked from stopping** and gets the failure output. |

It must be exit code **2**. For hooks, exit `1` is a non-blocking error: it
shows a warning and Claude stops anyway. Only `2` feeds stderr back to Claude
and makes it keep working.

**What it runs:** if the `CHECKS` array at the top of the script is non-empty,
exactly those commands. Otherwise it auto-detects:

| Project marker                                  | Checks                                                                                                         |
|-------------------------------------------------|----------------------------------------------------------------------------------------------------------------|
| `package.json`                                  | `lint`, `typecheck`/`type-check`, `test` scripts if defined, using npm/pnpm/yarn/bun based on the lockfile. The default `"no test specified"` script is skipped. |
| `pyproject.toml`, `setup.py`, `setup.cfg`, `requirements.txt` | `ruff check .`, `mypy .` (if mypy is configured), `pytest -q` (if test files exist). Only tools that are installed. |
| `go.mod`                                        | `go vet ./...`, `golangci-lint run` (if installed), `go test ./...`                                            |
| `Cargo.toml`                                    | `cargo clippy --all-targets -- -D warnings` (if installed), `cargo test`                                       |

To pin the checks yourself, edit the array:

```bash
CHECKS=(
  "npm run lint"
  "npm run typecheck"
  "npm test -- --run"
)
```

**Loop guard:** after `CLAUDE_CHECKS_MAX_ATTEMPTS` (default 5) failed attempts
in a row in one session, the hook gives up and lets Claude stop, so a task that
is really stuck can't loop forever. The counter resets as soon as checks pass.

Checks can take a while, so the hook has a 600-second timeout in
`settings.json`. Keep your checks fast, or set `CHECKS` to a quick subset.

**`--quick` mode** (used on `TaskCompleted`) runs only lint and typecheck:
`go vet`, clippy and ruff run, while tests and pytest are skipped. To pin those
commands, fill in the `QUICK_CHECKS` array. Quick mode never runs `CHECKS`,
because that list may contain tests. Each teammate gets its own attempt
counter.

### `CLAUDE.md`

A deliberately short template. Claude can read your code, so don't spend
context describing the folder layout, stack or style rules your linter
already enforces. Write down only what isn't in the code: non-obvious commands,
landmines, decisions and why they were made, and what "done" means. Delete
sections you don't need.

## Running agents in parallel

The guardrails come with every parallel approach: `.claude/settings.json` is
committed, so subagents, agent view sessions, agent teams, workflows, cloud
project threads and `/batch` all run under the same deny rules and sandbox.

The checks hook is different. It only checks **the folder of the session that
is stopping**:

| Approach | Where the Stop hook runs |
|---|---|
| Subagents, dynamic workflows | Once, when the main session stops, on their combined result |
| Agent view (`claude agents`), cloud project threads | In each session, inside that session's own worktree or clone |
| Agent teams | Full checks on the lead's `Stop`; quick checks on each teammate's `TaskCompleted` |
| `/batch` | Only on the main checkout, **not** in the worktrees the changes went into |

Watch out for two things:

1. **New worktrees may be missing dependencies.** A new worktree may not have
   `node_modules`, a `.venv`, or build output. Every check then fails, and the
   session stays blocked until the attempt limit lets it stop, which looks like
   Claude is stuck. Install dependencies in each worktree before the work
   starts, or have them copied in (see the worktrees docs on controlling what
   gets copied).
2. **`/batch` changes aren't checked by this hook.** Let CI check each branch
   or PR it opens, or run the checks again after you merge the results.

Also: several sessions running test suites on one machine at the same time can
fight over ports, a shared local database, or CPU. If yours do, set `CHECKS` to
a lighter list.

## Using agent teams

Agent teams are experimental and off by default. This repo doesn't turn them
on for everyone, because once they're on Claude may start teammates on its own
and use many more tokens. Opt in for yourself:

1. Add this to `~/.claude/settings.json` on your machine (merge it with any
   existing `env` block):
   ```json
   { "env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" } }
   ```
2. Start `claude` in the project, in an ordinary interactive session. Teams
   don't start with `-p` or in the Agent SDK.
3. Ask for a team, and give each teammate its own files. Teammates share one
   checkout, so two teammates editing the same file overwrite each other:
   ```text
   Create an agent team with 3 teammates: "api" owns src/api/, "ui" owns
   src/ui/, "tests" owns tests/. Each one marks its tasks complete only when
   its own part is done. Wait for all of them before you finish.
   ```
4. Use the agent panel under the prompt: arrow keys to pick a teammate, Enter
   to view and message it, Ctrl+T for the task list.

How the guardrails apply:

- **Permissions:** teammates start in the lead's mode (auto here) and are bound
  by the same deny rules. Their permission prompts show up in the lead's
  session.
- **Task gate:** a teammate can't mark a task complete while lint or typecheck
  fails. If the failure is in another teammate's files, the hook tells it to
  message that teammate instead of fixing it.
- **Final gate:** the full checks, tests included, run when the lead tries to
  finish.

Start with 3 to 5 teammates, and try it first on research or review tasks
that don't write code. Each teammate is a full Claude session, so cost goes up
with team size.

## Copying this into a project

From the root of your project:

```bash
git clone https://github.com/<you>/<this-repo>.git /tmp/cc-starter
```

```bash
mkdir -p .claude/hooks && cp /tmp/cc-starter/.claude/settings.json .claude/ && cp /tmp/cc-starter/.claude/hooks/require-checks.sh .claude/hooks/
```

```bash
chmod +x .claude/hooks/require-checks.sh
```

```bash
[ -f CLAUDE.md ] || cp /tmp/cc-starter/CLAUDE.md .
```

Then:

1. If you already have a `.claude/settings.json`, merge the `permissions`,
   `sandbox` and `hooks` blocks into it instead of overwriting.
2. Run the hook once by hand to see what it detects and that your checks pass:
   ```bash
   echo '{}' | CLAUDE_PROJECT_DIR="$PWD" .claude/hooks/require-checks.sh; echo "exit=$?"
   ```
3. Fill in `CLAUDE.md`, or delete the placeholders you don't need.
4. Commit `.claude/settings.json`, `.claude/hooks/` and `CLAUDE.md` so the
   whole team gets the same setup. Personal tweaks go in
   `.claude/settings.local.json`, which git should ignore.

Requirements: `bash`, plus `node` for npm script detection. `jq` is used if
present but isn't required.
