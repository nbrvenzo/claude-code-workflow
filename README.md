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

### `CLAUDE.md`

A deliberately short template. Claude can read your code, so don't spend
context describing the folder layout, stack or style rules your linter
already enforces. Write down only what isn't in the code: non-obvious commands,
landmines, decisions and why they were made, and what "done" means. Delete
sections you don't need.

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
