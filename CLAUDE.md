# CLAUDE.md

<!--
Keep this file SHORT. Only write down what Claude cannot work out by reading
the code: tribal knowledge, non-obvious commands, landmines, and decisions.
Don't describe the folder structure, the tech stack, or style rules a linter
already enforces. Claude reads the code. Delete any section you don't need.
-->

## Commands that aren't obvious
- <e.g. Run `make dev-db` before tests; integration tests need the local Postgres container.>

## Gotchas
- <e.g. `src/legacy/` is generated. Never edit it by hand; run `npm run codegen`.>
- <e.g. The `orders` table is shared with the billing service. Schema changes need a migration PR reviewed by the billing team.>

## Decisions and their reasons
- <e.g. We use X instead of Y because Z. Don't "fix" this.>

## How to know you're done
- Lint, typecheck and tests must pass. The Stop hook in `.claude/hooks/require-checks.sh` enforces this.
- <e.g. UI changes: also check the page in the browser at http://localhost:3000.>
