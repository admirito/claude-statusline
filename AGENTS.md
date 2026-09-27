# Agent guide

One bash script with two jobs, chosen by the JSON payload on stdin. As the
`statusLine` it prints the status line. As the `subagentStatusLine`, given a
payload with a `tasks` array, it prints one JSON line per background agent,
`{"id": …, "content": …}`, and the main line's code never runs. `DESIGN.org`
has the reasoning behind each field.

## Constraints

**bash 3.2.** macOS ships it as `/bin/bash`. No `${x^}`, `${x^^}`, `${x,,}`,
`mapfile`, `readarray`, `declare -A`, `local -n`, or bare `$EPOCHSECONDS`. These
fail at runtime rather than at parse time, so a branch carrying one passes every
test until the day it executes. The same goes for GNU-only tools and flags:
macOS has the BSD ones, so no `tac`, `stat -c`, `date +%N`, `xargs -r` or
`timeout`.

**Never crash, never print garbage.** This is a status bar; every render must
produce a sensible line, including on empty stdin, `{}`, `null`, or unparsable
input. Hence no `set -euo pipefail`: `-e` would exit on the expected non-zero
from `git diff --quiet`, and `-u` would abort whenever jq fails, which is the
fail-closed behaviour a status line must not have. Prefer `(( ))` for
arithmetic, which treats empty as 0 silently, over `[ "$x" -gt 0 ]`, which
errors to stderr on every render.

**Absence is not zero.** Many payload fields are omitted rather than sent as
zero. A confident `0%` for "not known yet" is worse than showing nothing.

**Stay cheap.** The main line runs on every session event and every 30
seconds. Two `jq` calls and two `git` calls is its budget; extend the existing
jq programs rather than adding a pass. The agent rows run every five seconds
while agents are listed: one `jq` pass per agent only when its transcript has
grown, and anything that never changes (a worktree's starting point, a type's
colour) looked up once and kept in the agent state. Nothing slow runs in the
foreground; the one network call, `gh`, is detached.

## Style

Comments carry the why. Most non-obvious lines here exist because of a specific
bug, so name it. No em dashes.

## Testing

No test suite; drive it with JSON on stdin. To read the output, strip colour
with `perl -pe 's/\e\[[0-9;]*m//g'`, since the equivalent `sed` needs `\x1b`,
which BSD sed on macOS does not understand.

Cover at least: a fresh session (no `rate_limits`,
no `prompt_cache`), a fully populated payload, every conditional alarm firing at
once, a 200K window, a model with no `effort` field, and the degenerate inputs
above.

For the agent rows, build a `tasks` payload whose `transcript_path` points at a
directory laid out as Claude Code lays it out (`<session>/subagents/agent-<id>.jsonl`
and `.meta.json` beside it), and point `XDG_RUNTIME_DIR` at a scratch directory
so the state is fresh. Run twice: the second run reads the state the first
wrote. Cover a transcript that grows between runs, including a last line
written in two halves; a fork; nested agents; each status; an agent in a real
linked worktree; and `{"tasks": []}`, `{"tasks": null}` and junk entries.

bash 3.2 is easy to get wrong from a newer shell: run the tests under the
`bash:3.2` Docker image, with `jq` and `git` added, and treat any stderr output
as a failure.

## Commits

Record the reasoning, not just the change. Never put a session URL, an email
address, a hostname, or a machine name in a commit message, a comment, or any
tracked file: this repository is public.
