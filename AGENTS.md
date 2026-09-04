# Agent guide

One bash script that reads a JSON payload on stdin and prints one line.
`DESIGN.org` has the reasoning behind each field.

## Constraints

**bash 3.2.** macOS ships it as `/bin/bash`. No `${x^}`, `${x^^}`, `${x,,}`,
`mapfile`, `readarray`, `declare -A`, `local -n`, or bare `$EPOCHSECONDS`. These
fail at runtime rather than at parse time, so a branch carrying one passes every
test until the day it executes.

**Never crash, never print garbage.** This is a status bar; every render must
produce a sensible line, including on empty stdin, `{}`, `null`, or unparsable
input. Hence no `set -euo pipefail`: `-e` would exit on the expected non-zero
from `git diff --quiet`, and `-u` would abort whenever jq fails, which is the
fail-closed behaviour a status line must not have. Prefer `(( ))` for
arithmetic, which treats empty as 0 silently, over `[ "$x" -gt 0 ]`, which
errors to stderr on every render.

**Absence is not zero.** Many payload fields are omitted rather than sent as
zero. A confident `0%` for "not known yet" is worse than showing nothing.

**Stay cheap.** It runs on every session event and every 30 seconds. Two `jq`
calls and two `git` calls is the budget; extend the existing jq programs rather
than adding a pass.

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

## Commits

Record the reasoning, not just the change. Never put a session URL, an email
address, a hostname, or a machine name in a commit message, a comment, or any
tracked file: this repository is public.
