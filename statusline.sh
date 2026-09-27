#!/bin/bash
# Claude Code status line, v7.
#
# What changed from v6, and why:
#
#   * agent rows. Claude Code runs a second command, subagentStatusLine, for
#     the panel of background agents under the prompt, and this script is
#     that command too: a payload with a tasks array is answered with one row
#     per agent, in the main line's language. A row shows what the panel
#     leaves out: model and effort against the main session's, what the agent
#     is doing and how long it has been quiet or waiting, its cost, tool
#     calls, context and prompt cache, the agents nested below it and their
#     health, whether it is a fork, and what it changed in a worktree of its
#     own. The agent rows section says where each part comes from.
#   * the main session's model and effort go into the state file. That is how
#     an agent row knows what "same as main" means.
#   * managed settings are read where Claude Code reads them on macOS as well,
#     and from the managed-settings.d drop-ins beside the file.
#
# What changed from v5 to v6, and why:
#
#   * a pace cell, »68%, between the cost and the limits. It is the weekly
#     percentage you would reach BY THE RESET if you carried on at the average
#     rate you have kept since the week began. Nothing in Claude Code shows
#     this, and the raw weekly percentage cannot answer the only question
#     worth asking of a weekly budget: am I going to run out?
#   * the miss journal grows into a session state file, which also carries
#     what the previous render saw and any brief still inside its minute.
#   * a second line, but only ever for a minute at a time. It carries the
#     facts that are otherwise invisible until they bite (the weekly window
#     below 75%, reset instants as clock times, why a cache miss happened) and
#     it shows them at the four moments you are demonstrably at the keyboard.
#     The row is absent the rest of the time: vertical space is not free.
#
# What changed from v4 to v5, and why:
#
#   * the cache countdown is on the whole time the cache is warm, not only in
#     its last 15 minutes. The question it answers is "can I leave my desk",
#     and that gets asked at 45 minutes too. Two or three characters, coloured
#     by the fraction of the TTL already spent rather than by minutes left, so
#     a 5-minute TTL (API keys, most Bedrock and Vertex sessions) reads
#     sensibly instead of alarming for its whole life.
#   * cache misses name their cause, for five minutes. Claude Code 2.1.260
#     diagnoses each miss (tools changed, system prompt changed, /model, idle
#     past the TTL...) but reports only the latest one, so a small per-session
#     journal in the runtime directory keeps the last five minutes of them.
#     That journal is the only thing this script writes.
#   * a miss is a receipt, not an alarm: by the time it shows, the rebuild has
#     already been paid for. Yellow while a cause is still on the line, gray
#     once the last one has aged out. The count stays for the session,
#     matching the figure /cost shows.
#
# What changed from v3 to v4, and why:
#
#   * effort comes from .effort.level instead of grepping the transcript. v3
#     scanned a growing multi-megabyte JSONL on every render to learn something
#     the payload now hands over, and its settings.json fallback could not see
#     per-model or per-session overrides.
#   * cache stats come from .prompt_cache (session-wide, honest denominator)
#     instead of the last request's ratio, which read N/A early and was
#     optimistic because it excluded uncached input from the denominator.
#   * rate limits are displayed, each with the time until its window resets. A
#     percentage alone is not interpretable: 24% burned with four hours left and
#     24% with twenty minutes left are opposite situations.
#   * the context rescale subtracts a CONSTANT token reserve rather than a
#     fraction. Compaction fires a fixed distance below the end of the window,
#     so a divisor tuned on a 200K window overstates a 1M one by about a third:
#     the same reserve is a fifth of the small window and a twentieth of the
#     large one.
#   * two jq passes total, down from about a dozen calls, which matters once
#     refreshInterval re-runs this every 30 seconds.
#
# Fields deliberately not shown, so a later reader does not think they were
# missed: thinking.enabled (constant true on Opus 5, where effort and thinking
# are coupled), exceeds_200k_tokens (derivable from the token count already on
# the line), version, session_name, prompt_id, workspace.repo, and the
# prompt_cache counters requests, expected_rebuilds, cache_write_tokens and
# miss_recache_tokens, which describe the session's history rather than
# anything to act on. prompt_cache.ttl is used but not shown: it scales the
# countdown colour. session_id names the state file and prompt_id detects a
# new user turn; neither is ever displayed.
#
# Pairs with settings.json:
#   "statusLine": { "type": "command", "command": "…/statusline.sh",
#                   "refreshInterval": 30 },
#   "subagentStatusLine": { "type": "command", "command": "…/statusline.sh" }
# The interval exists for the cache countdown, the limit countdowns and the
# expiry of a brief on the second line. Claude
# Code already re-renders on token usage, model, effort, fast mode, vim mode,
# permission mode and PR state, and schedules a wake-up at the earliest rate
# limit reset or cache expiry, so ❄ and the ⧗ rollover are live without a timer.
# The ⏱ countdown is not: it matters while idle, which is when no event fires.

# Numeric parsing follows the locale: under a comma-decimal locale such as
# de_DE, printf '%.2f' 4.82 stops at the dot and yields 4.00. LC_ALL is unset
# first, or it would mask LC_NUMERIC. String handling stays in the user's UTF-8
# locale so ${#name} counts characters, not bytes.
unset LC_ALL
export LC_NUMERIC=C

# ---------------------------------------------------------------- palette ---
R=$'\033[0m'
C_GRAY=$'\033[90m'            # constants, icons, unknowns
C_MODEL=$'\033[38;5;117m'
C_PLAN=$'\033[38;5;114m'
C_PLAN_ENT=$'\033[38;5;141m'
C_PLAN_API=$'\033[38;5;223m'
C_BRANCH=$'\033[38;5;65m'     # clean
C_DIRTY=$'\033[33m'           # tracked files modified
C_ELSEWHERE=$'\033[38;5;208m' # cwd has left the project dir
C_TIME=$'\033[38;5;194m'
C_ADD=$'\033[38;5;78m'
C_DEL=$'\033[38;5;203m'
C_COST=$'\033[38;5;218m'
C_MODES=$'\033[38;5;103m'     # the whole modes cluster, one colour
C_FAST=$'\033[38;5;220m'      # effort glyph while fast mode is on
C_COLD=$'\033[38;5;159m'      # ❄ pale ice
C_ALERT=$'\033[38;5;226m'     # sharp yellow: a fresh cache miss, a pace that overruns
C_WARM=$'\033[38;5;253m'      # 50-75 band, and pending review
C_LOW=$'\033[38;5;78m'
C_MID=$'\033[38;5;228m'
C_HIGH=$'\033[38;5;214m'
C_CRIT=$'\033[38;5;196m'
C_BOLD=$'\033[1m'             # an agent's @name
C_SUBTREE=$'\033[1;38;5;141m' # an agent's +N: bold, because the panel dims rows
C_FORK=$'\033[1;38;5;213m'    # ⋔fork, in a pink nothing else uses

BRANCH_MAX=16   # columns, ellipsis included

# Field separator in the state files, US (0x1f); the session state section says
# why it is not a tab.
US=$'\037'

# Pace: the weekly percentage reached by the reset at the average rate kept so
# far. BUFFER is the headroom it must leave to stay quiet, so 1 means "warn
# once the projection no longer lands under 100". RED is where it stops being
# a near miss. MIN_ELAPSED keeps the cell absent early in the week, where the
# arithmetic is meaningless: 5% used two hours in projects to 400%.
PACE_BUFFER=1
PACE_RED=150
PACE_MIN_ELAPSED=86400
WEEK=604800

BRIEF_TTL=60    # seconds a second-line brief stays up
IDLE_RETURN=600 # seconds away that earn a "back after" brief

# ---------------------------------------------------------------- helpers ---
# Arithmetic uses (( )) throughout: it treats an empty or unset value as 0
# silently, where [ "$x" -gt 0 ] errors to stderr on every render.

num() { printf '%s' "${1:-0}"; }

fmt_tokens() {
    local n=${1:-0} t
    if (( n >= 1000000 )); then
        if (( n % 1000000 == 0 )); then printf '%dM' $((n / 1000000))
        else t=$(( (n + 50000) / 100000 )); printf '%d.%dM' $((t / 10)) $((t % 10))
        fi
    else printf '%dK' $((n / 1000))
    fi
}

# printf already prints 0 for an unparsable value, so a `|| printf 0` fallback
# would emit "00" and corrupt the very field it was meant to protect.
round() { printf '%.0f' "${1:-0}" 2>/dev/null; }

# Time until an epoch instant. Coarse is nearest-hour; fine adds the minutes,
# and the two only differ above 1h, since below that it is already minutes.
fmt_until() {
    local left=$(( ${1:-0} - NOW ))
    (( left <= 0 )) && return 1
    if   (( left >= 86400 )); then printf '%dd' $(( (left + 43200) / 86400 ))
    elif (( left <  3600  )); then
        local m=$(( (left + 30) / 60 )); (( m < 1 )) && m=1
        printf '%dm' "$m"
    elif [ "$2" = fine ]; then
        printf '%dh%dm' $((left / 3600)) $(( (left % 3600) / 60 ))
    else printf '%dh' $(( (left + 1800) / 3600 ))
    fi
}

# Promote the unit rather than let the number grow: seconds only below a minute
# (a whole minute reading "0m" is worse), then minutes to 99, hours to 99, then
# days. Seconds are noise in a figure that is glanced at, and "883m41s" spends
# seven columns saying what "15h" says in three.
fmt_duration() {
    local sec=$(( ${1:-0} / 1000 )) m h
    (( sec < 60 )) && { printf '%ds' "$sec"; return; }
    m=$(( (sec + 30) / 60 ))
    (( m <= 99 )) && { printf '%dm' "$m"; return; }
    h=$(( (sec + 1800) / 3600 ))
    (( h <= 99 )) && { printf '%dh' "$h"; return; }
    printf '%dd' $(( (sec + 43200) / 86400 ))
}

# The cache countdown: two or three characters, always. Minutes are rounded up
# so the last minute reads 1m rather than 0m while the cache is still warm,
# then hours from 100 minutes, since "100m" would be the first four-character
# value. No current TTL reaches an hour, so this is future-proofing.
fmt_cache_left() {
    local s=${1:-0}
    # 5940, not 6000: a second past 99 minutes already rounds up to "100m",
    # which is the four characters this is here to avoid.
    if (( s > 5940 )); then printf '%dh' $(( (s + 1800) / 3600 ))
    else local m=$(( (s + 59) / 60 )); (( m < 1 )) && m=1; printf '%dm' "$m"; fi
}

# Claude Code's miss causes, as one word each. A single miss can carry several
# (/model usually reports model and effort together), joined with +. The rare
# ones share "other" rather than each earning a word nobody would recognise,
# and duplicates within one miss collapse. Absent or empty is undiagnosed.
cause_words() {
    local out="" c w IFS=,
    for c in $1; do
        case $c in
            tools_changed)                  w=tools ;;
            system_prompt_changed)          w=prompt ;;
            model_changed)                  w=model ;;
            effort_changed)                 w=effort ;;
            fast_mode_changed)              w=fast ;;
            messages_rewritten)             w=rewind ;;
            likely_server_side)             w=server ;;
            ttl_expired_5m|ttl_expired_1h)  w=idle ;;
            unknown|'')                     w='?' ;;
            *)                              w=other ;;
        esac
        case "+$out+" in *"+$w+"*) ;; *) out+="${out:+"+"}$w" ;; esac
    done
    printf '%s' "${out:-?}"
}

# An absolute instant, for the second line: "17:05" today, "Thu 09:00" later in
# the week. GNU date spells it -d @N and BSD date -r N, so try both; a failure
# yields the empty string and the caller drops the clause rather than printing
# a bare arrow. Only ever called while a brief is being composed.
fmt_clock() {
    local t=${1:-0} f='%H:%M'
    [ "$(fmt_date "$t" '%j')" = "$(fmt_date "$NOW" '%j')" ] || f='%a %H:%M'
    fmt_date "$t" "$f"
}
fmt_date() { date -d "@$1" +"$2" 2>/dev/null || date -r "$1" +"$2" 2>/dev/null; }

# The band a percentage has crossed: every 10 up to 50, then every 5. Used to
# fire a brief once per crossing rather than on every render above a line.
band() {
    local p=${1:-0}
    if   (( p >= 100 )); then printf 100
    elif (( p <  10  )); then printf 0
    elif (( p <  50  )); then printf '%d' $(( p / 10 * 10 ))
    else                      printf '%d' $(( p / 5 * 5 ))
    fi
}

# Not ${x^}: that expansion is bash 4 only, and macOS ships bash 3.2 as
# /bin/bash. It fails at runtime, not at parse time, so an untested branch
# carrying it looks fine until the day it runs.
ucfirst() {
    printf '%s%s' "$(printf '%s' "${1:0:1}" | tr '[:lower:]' '[:upper:]')" "${1:1}"
}

# Degrade a long ref in the order of how little the dropped part is worth: keep
# it whole if it fits; else abbreviate each prefix segment to one character, but
# only when there is a prefix to abbreviate; else cut the tail.
shorten() {
    local n=$1 head tail out seg
    (( ${#n} <= BRANCH_MAX )) && { printf '%s' "$n"; return; }
    if [[ $n == */* ]]; then
        head=${n%/*}; tail=${n##*/}; out=""
        local IFS=/
        for seg in $head; do out+="${seg:0:1}/"; done
        n="${out}${tail}"
        (( ${#n} <= BRANCH_MAX )) && { printf '%s' "$n"; return; }
    fi
    printf '%s…' "${n:0:$((BRANCH_MAX - 1))}"
}

limit_colour() {
    local p=${1:-0}
    if   (( p >= 95 )); then printf '%s' "$C_CRIT"
    elif (( p >= 85 )); then printf '%s' "$C_HIGH"
    elif (( p >= 75 )); then printf '%s' "$C_MID"
    elif (( p >= 50 )); then printf '%s' "$C_WARM"
    else                     printf '%s' "$C_GRAY"
    fi
}

context_colour() {
    local p=${1:-0}
    if   (( p >= 90 )); then printf '%s' "$C_CRIT"
    elif (( p >= 75 )); then printf '%s' "$C_HIGH"
    elif (( p >= 50 )); then printf '%s' "$C_MID"
    else                     printf '%s' "$C_LOW"
    fi
}

# Lowercasing via tr, not ${1,,}, and a date fallback for EPOCHSECONDS: macOS
# ships bash 3.2 as /bin/bash, where both are unavailable. An empty NOW is the
# worse of the two, since every reset countdown then measures from the epoch.
truthy() { case $(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]') in 1|true|yes|on) return 0 ;; *) return 1 ;; esac }

# Shape is effort: ⡀ low ⡄ medium ⡆ high ⡇ xhigh ⣿ max. Anything else is ∅:
# absent means the model has no effort knob, which is not the same as unknown.
effort_glyph() {
    case $1 in
        low)    printf '⡀' ;;
        medium) printf '⡄' ;;
        high)   printf '⡆' ;;
        xhigh)  printf '⡇' ;;
        max)    printf '⣿' ;;
        *)      printf '∅' ;;
    esac
}

# Where Claude Code looks for managed settings: the file, then the drop-ins
# beside it in alphabetical order, merged so that a later file wins. One system
# directory per platform; the other one does not exist.
MANAGED_LINUX=/etc/claude-code
MANAGED_MACOS="/Library/Application Support/ClaudeCode"
managed_settings_files() {
    local d f
    for d in "$MANAGED_LINUX" "$MANAGED_MACOS"; do
        [ -r "$d/managed-settings.json" ] && printf '%s\n' "$d/managed-settings.json"
        for f in "$d"/managed-settings.d/*.json; do
            [ -r "$f" ] && printf '%s\n' "$f"
        done
    done
}

# The session's state file, which the agent rows share by adding .agents to
# its name. One directory per user in the runtime directory, so it dies with
# the login on Linux and is swept by the OS on macOS. Sets SDIR and SFILE, and
# leaves SFILE empty when there is no usable file.
state_file() {  # $1 session id
    SFILE=""
    case $1 in
        # "." and ".." pass a character test and name a directory, which
        # `read` then fails on, once per render.
        ''|.|..|*[!A-Za-z0-9._-]*) return ;;
    esac
    SDIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/claude-statusline-${UID:-$(id -u)}"
    [ -d "$SDIR" ] || mkdir -p -m 700 "$SDIR" 2>/dev/null
    # Owned by us, not merely writable: in a shared /tmp, mkdir -p accepts a
    # directory someone else made first, and what they put in it would be read.
    if [ -d "$SDIR" ] && [ -O "$SDIR" ] && [ -w "$SDIR" ] && [ ! -d "$SDIR/$1" ]; then
        SFILE="$SDIR/$1"
    fi
}

NOW=${EPOCHSECONDS:-$(date +%s)}

# Read once: the payload decides which of the two jobs this run does, and the
# main line's jq pass reads it from here.
INPUT=$(cat)

# ------------------------------------------------------------ agent rows ---
# Claude Code can run a second command, subagentStatusLine, for the panel of
# background agents under the prompt: every few seconds it sends all of them
# at once and takes back one JSON line per agent, each replacing that agent's
# row. This script is that command too. A payload with a tasks array asks for
# agent rows, and the main line below this section never runs.
#
# A row speaks the main line's language, and every cell has a fixed width, so
# the rows read as a table:
#
#   [Haiku 4.5⡇|Explore] ⌚3m  ▃▅▃▁█▇▇▄▄▄ $0.08  ⚒23    61K·39% ⚡5m      │ …
#
# The payload knows an agent's model, status, token count and start time and
# little else, so most of a row comes from two files Claude Code keeps beside
# the session transcript: a small metadata file per agent (its type, parent
# and nesting depth) and the agent's own transcript (tool calls, cache use,
# cost, background commands). A transcript is read incrementally, only what
# was added since the last run, and what it has said so far is kept in a
# state file beside the main line's.

AG_SLOT=10        # activity slot: the sparkline, or a state and how long
AG_BAR=30         # seconds of token growth per sparkline bar
AG_QUIET=30       # seconds without a new token before a running agent is quiet
AG_STUCK=300      # quiet this long marks every ancestor's +N with ▁
AG_OUT_MIN=10000  # output below this does not earn a ↗
AG_PR_EVERY=60    # seconds between pull request lookups per branch; 0 is never
AG_TYPE_MAX=14    # columns for a custom agent type, ellipsis included
AG_CTX_MIN=9      # the context cell at its usual widest: ❄712K·74%
AG_CACHE_W=9      # ⚡74%⏱59m, where ⚡ takes two columns
AG_UNTRACKED=4194304  # bytes of a worktree's untracked files read per run
AG_SPARK=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)

# The model's name from its id, since the agent payload carries no display
# name: claude-haiku-4-5-20251001 is Haiku 4.5, claude-opus-5-5[1m] Opus 5.5.
# An id of any other shape is shown as it is, less the claude- prefix, rather
# than guessed at.
model_label() {
    local id=${1%%\[*}
    id=${id#claude-}
    if [[ $id =~ ^([a-z]+)-([0-9]+)(-([0-9]{1,2}))?(-[0-9]{8})?$ ]]; then
        printf '%s %s%s' "$(ucfirst "${BASH_REMATCH[1]}")" "${BASH_REMATCH[2]}" \
            "${BASH_REMATCH[4]:+.${BASH_REMATCH[4]}}"
    else
        printf '%s' "$id"
    fi
}

# Cut to a width, spending the last column on an ellipsis. Widths here are
# characters, which is columns for the agent types this is used on; the task
# and tool text are fitted by display width, in AG_LABEL_JQ.
clip() {  # $1 text  $2 columns
    local w=$2
    (( w < 1 )) && return
    if (( ${#1} > w )); then printf '%s…' "${1:0:w-1}"; else printf '%s' "$1"; fi
}

# An agent's own colour, from the color field of its definition. Claude Code
# accepts eight names; these are nearby 256-colour shades, purple kept clear
# of the +N count's.
agent_colour() {
    case $1 in
        red)    printf '\033[38;5;203m' ;;
        blue)   printf '\033[38;5;75m'  ;;
        green)  printf '\033[38;5;78m'  ;;
        yellow) printf '\033[38;5;221m' ;;
        purple) printf '\033[38;5;177m' ;;
        orange) printf '\033[38;5;208m' ;;
        pink)   printf '\033[38;5;211m' ;;
        cyan)   printf '\033[38;5;80m'  ;;
        *)      printf '%s' "$C_MODES" ;;
    esac
}

# The colour an agent type's definition gives it, or nothing. Claude Code keys
# colours by type, and the metadata file does not record them, so the answer
# is the first definition, project before user, whose frontmatter names the
# type. File names need not match the name field, so every file is looked at.
definition_colour() {  # $1 agent type  $2 project directory
    awk -v want="$1" '
        FNR == 1 { fm = 0; name = ""; col = "" }
        /^---[[:space:]]*$/ {
            if (++fm == 2 && name == want && col != "") { print col; exit }
            next
        }
        fm == 1 && /^name:/  { sub(/^name:[[:space:]]*/, "");  gsub(/["\047[:space:]]/, ""); name = $0 }
        fm == 1 && /^color:/ { sub(/^color:[[:space:]]*/, ""); gsub(/["\047[:space:]]/, ""); col = $0 }
    ' "$2/.claude/agents"/*.md "$HOME/.claude/agents"/*.md 2>/dev/null
}

# List prices per million tokens: input, 5-minute cache write, 1-hour cache
# write, cache read, output. These are what Claude Code's own session cost is
# computed from, unless an administrator's modelPricing replaces them.
list_rates() {  # $1 model id
    case ${1%%\[*} in
        claude-fable-5-1*|claude-mythos-5-1*) echo "10 12.5 20 0.25 50" ;;
        claude-fable-5*|claude-mythos-5*)     echo "10 12.5 20 1 50" ;;
        claude-opus-5-5*)                     echo "4 5 8 0.2 20" ;;
        claude-opus-5*|claude-opus-4-[5-8]*)  echo "5 6.25 10 0.5 25" ;;
        claude-opus-4*)                       echo "15 18.75 30 1.5 75" ;;
        claude-sonnet-5*)                     echo "2 2.5 4 0.2 10" ;;
        claude-sonnet-4*)                     echo "3 3.75 6 0.3 15" ;;
        claude-haiku-4-5*)                    echo "1 1.25 2 0.1 5" ;;
        claude-3-5-haiku*)                    echo "0.8 1 1.6 0.08 4" ;;
    esac
}

# The rates Claude Code itself would charge this model at. A modelPricing row
# keyed by the exact id wins, then one keyed by the id without its dated or
# [1m] suffix, which is how a row for a built-in model covers its snapshots;
# its one cacheWrite rate covers both cache lifetimes. The multiplier applies
# on top of whichever rates are used, in agent_cost.
agent_rates() {  # $1 model id -> "input write5m write1h read output"
    local base=${1%%\[*} key i
    base=${base%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]}
    for key in "$1" "$base"; do
        for (( i = 0; i < ${#AG_OVR_ID[@]}; i++ )); do
            if [ "${AG_OVR_ID[i]}" = "$key" ]; then
                set -- ${AG_OVR_RATES[i]}   # input output cacheRead cacheWrite
                echo "$1 $4 $4 $3 $2"
                return
            fi
        done
    done
    list_rates "$1"
}

# Dollars, from the token totals the agent's transcript has given so far.
agent_cost() {  # $1 model id
    local rates
    rates=$(agent_rates "$1")
    [ -z "$rates" ] && return
    set -- $rates
    awk -v i="$g_in" -v w5="$g_w5" -v w1="$g_w1" -v r="$g_reads" -v o="$g_out" \
        -v pi="$1" -v p5="$2" -v p1="$3" -v pr="$4" -v po="$5" -v m="${AG_MULT:-1}" \
        'BEGIN { printf "%.4f", (i*pi + w5*p5 + w1*p1 + r*pr + o*po) * m / 1e6 }'
}

# Token growth over the last AG_SLOT bars of AG_BAR seconds each, scaled to the
# largest step. Always AG_SLOT wide: bars not yet seen are drawn flat, so the
# cell never grows, and a bar without growth is gray, which is what an agent
# waiting on something looks like. A bar is a span rather than a run, so the
# line moves once per AG_BAR however often Claude Code asks.
sparkline() {  # $1 token counts, oldest first, comma-separated
    local IFS=, s n i d from max=0 out pad steps
    s=($1); n=${#s[@]}; steps=()
    from=$(( n > AG_SLOT + 1 ? n - AG_SLOT : 1 ))
    for (( i = from; i < n; i++ )); do
        d=$(( s[i] - s[i-1] )); (( d < 0 )) && d=0
        steps+=("$d"); (( d > max )) && max=$d
    done
    printf -v pad '%*s' $(( AG_SLOT - ${#steps[@]} )) ''
    out="${C_GRAY}${pad// /▁}"
    for d in "${steps[@]}"; do
        if (( d == 0 )); then out+="${C_GRAY}▁"
        else                  out+="${C_LOW}${AG_SPARK[d * 7 / max]}"; fi
    done
    printf '%s%s' "$out" "$R"
}

# The agent's token count once every AG_BAR seconds, AG_SLOT + 1 of them. Kept
# here rather than taken from the payload's tokenSamples, which start again
# from a single sample whenever Claude Code redraws the panel.
history_add() {  # $1 "seconds:tokens,..."  $2 tokens now
    local IFS=, a n last=0
    a=($1); n=${#a[@]}
    (( n > 0 )) && last=${a[n-1]%%:*}
    if (( NOW - last >= AG_BAR )); then a+=("$NOW:$2"); n=${#a[@]}; fi
    (( n > AG_SLOT + 1 )) && a=("${a[@]:n-AG_SLOT-1}")
    printf '%s' "${a[*]}"
}
history_tokens() {  # "seconds:tokens,..." -> "tokens,..."
    local IFS=, p out=""
    for p in $1; do out+="${p#*:},"; done
    printf '%s' "${out%,}"
}

# One agent's record in the agent state, the g_* fields in this order. It holds
# what no single run can know: when the current status began, when the tokens
# last grew and their recent history, how far the transcript has been read and
# the totals read so far, the worktree's starting point, and the metadata and
# definition colour, looked up once.
AG_FIELDS="status since growth hist off calls errs tool arg reads all req ts ttl first in w5 w1 out lastout comps bgrun base mine type parent depth colour meta last"

agent_load() {  # $1 record, possibly empty
    IFS=$US read -r g_status g_since g_growth g_hist g_off g_calls g_errs g_tool g_arg \
        g_reads g_all g_req g_ts g_ttl g_first g_in g_w5 g_w1 g_out g_lastout g_comps \
        g_bgrun g_base g_mine g_type g_parent g_depth g_colour g_meta g_last <<<"$1"
    # Every field is checked here, so a torn, hand-edited or planted file can
    # put nothing into the arithmetic below, whose operands bash evaluates as
    # expressions, and no escape sequence onto the row. A time that is not a
    # number becomes now, not the epoch, which would read as 20724 days.
    local f v
    # A leading zero is refused as well: bash reads 08 as a bad octal number.
    for f in since growth; do
        eval "v=\$g_$f"
        case $v in ''|*[!0-9]*|0[0-9]*) eval "g_$f=\$NOW" ;; esac
    done
    for f in off calls errs reads all ts ttl first in w5 w1 out lastout comps depth last; do
        eval "v=\$g_$f"
        case $v in ''|*[!0-9]*|0[0-9]*) eval "g_$f=0" ;; esac
    done
    case $g_hist in *[!0-9:,]*|0[0-9]*|*[,:]0[0-9]*) g_hist="" ;; esac
    case $g_bgrun in *[!A-Za-z0-9,]*) g_bgrun="" ;; esac
    for f in status tool arg req base mine type parent colour meta; do
        eval "v=\$g_$f"
        case $v in *[[:cntrl:]]*) eval "g_$f=''" ;; esac
    done
}
agent_record() {
    local f out="" v
    for f in $AG_FIELDS; do eval "v=\$g_$f"; out+="$v$US"; done
    printf '%s' "${out%"$US"}"
}

# Reads what the agent's transcript has added since the last run into the g_*
# totals. Only whole lines: Claude Code may be mid-write, so a trailing partial
# line is left for the next run, which starts where this one stopped. The new
# bytes are copied out first, so their size, their partial tail and what jq
# parses are one snapshot of a file that is still growing.
#
# Each entry is folded in on its own, and one that does not have the expected
# shape is skipped rather than failing the pass: a failed pass leaves the
# offset where it was, so one odd entry would otherwise stop the agent's
# counters for good. A response split across several entries repeats its
# usage, so a request is counted once by its id, and a repeat adds only the
# output it grew by. A
# background command starts with a tool result naming its id and ends with a
# notification naming the same id and a final status; the ids still running
# are carried from run to run.
AG_TRANSCRIPT_JQ='
  def flat: tostring | explode | map(if . < 32 then 32 else . end) | implode;
  def text: if type == "string" then .
            elif type == "array" then map(if type == "object" then (.text // "") else "" end) | join(" ")
            else "" end;
  def summary:
    if type != "object" then ""
    elif .command     then .command
    elif .file_path   then (.file_path | tostring | split("/") | last)
    elif .pattern     then .pattern
    elif .url         then (.url | tostring | sub("^[a-z]+://"; "") | split("/")[0])
    elif .description then .description
    elif .query       then .query
    elif .prompt      then .prompt
    else "" end | flat | .[0:160];
  reduce (inputs | fromjson? | select(type == "object")) as $o (
    {calls: 0, errs: 0, tool: "", arg: "", reads: 0, all: 0, req: $req, ts: 0, ttl: 0,
     first: 0, in: 0, w5: 0, w1: 0, out: 0, lastout: $lastout, comps: 0,
     started: [], ended: []};
    . as $before | try (
    if $o.type == "assistant" then
      ($o.message.usage) as $u
      | ($o.requestId // "") as $id
      | (if ($u | type) != "object" then .
         elif $id != "" and $id == .req then
           (($u.output_tokens // 0) - .lastout) as $more
           | if $more > 0 then .out += $more | .lastout += $more else . end
         else
           (($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0)
            + ($u.cache_read_input_tokens // 0)) as $all
           | .req = $id
           | .reads += ($u.cache_read_input_tokens // 0)
           | .all += $all
           | .in += ($u.input_tokens // 0)
           | .w5 += ($u.cache_creation.ephemeral_5m_input_tokens // 0)
           | .w1 += ($u.cache_creation.ephemeral_1h_input_tokens // 0)
           | .out += ($u.output_tokens // 0)
           | .lastout = ($u.output_tokens // 0)
           | .ts = ((($o.timestamp // "") | sub("\\.[0-9]+"; "") | fromdateiso8601? | floor) // .ts)
           | (if   ($u.cache_creation.ephemeral_1h_input_tokens // 0) > 0 then .ttl = 3600
              elif ($u.cache_creation.ephemeral_5m_input_tokens // 0) > 0 then .ttl = 300
              else . end)
           | (if .first == 0 then .first = $all else . end)
         end)
      | reduce ($o.message.content | if type == "array" then .[] else empty end
                | select(type == "object" and .type == "tool_use")) as $t (.;
          .calls += 1
          | .tool = ($t.name | tostring | split("__") | last | flat)
          | .arg = ($t.input | summary))
    elif $o.type == "user" then
      ($o.message.content) as $c
      | [$c | if type == "array" then .[] else empty end
            | select(type == "object" and .type == "tool_result")] as $results
      | .errs += ([$results[] | select(.is_error == true)] | length)
      | (($c | text) + " " + ([$results[] | .content | text] | join(" "))) as $txt
      | .started += [$txt | scan("running in background with ID: ([A-Za-z0-9]+)") | .[0]]
      | if ($txt | test("<status>(completed|failed|killed)</status>"))
        then .ended += [$txt | scan("<task-id>([A-Za-z0-9]+)</task-id>") | .[0]]
        else . end
    elif $o.type == "system" and $o.subtype == "compact_boundary" then .comps += 1
    else . end) catch $before)
  | [.calls, .errs, .tool, .arg, .reads, .all, .req, .ts, .ttl, .first, .in, .w5, .w1,
     .out, .lastout, .comps, (.started | join(",")), (.ended | join(","))]
  | map(tostring) | join("\u001f")'

agent_transcript() {  # $1 transcript path
    local size chunk partial whole run b f result=""
    local d_calls d_errs d_tool d_arg d_reads d_all d_req d_ts d_ttl d_first d_in d_w5 d_w1 \
          d_out d_lastout d_comps d_started d_ended
    size=$(wc -c < "$1" 2>/dev/null | tr -d ' ')
    case $size in ''|*[!0-9]*) return ;; esac
    # Smaller than what was already read: rewritten, so start over.
    if (( size < g_off )); then
        g_off=0 g_calls=0 g_errs=0 g_tool="" g_arg="" g_reads=0 g_all=0 g_req="" g_ts=0
        g_ttl=0 g_first=0 g_in=0 g_w5=0 g_w1=0 g_out=0 g_lastout=0 g_comps=0 g_bgrun=""
    fi
    (( size > g_off )) || return
    chunk="$SFILE.chunk.$$"
    tail -c +$(( g_off + 1 )) "$1" > "$chunk" 2>/dev/null || { rm -f "$chunk"; return; }
    size=$(wc -c < "$chunk" | tr -d ' ')
    partial=0
    if [ "$(tail -c 1 "$chunk" | od -An -tx1 | tr -d ' \n')" != 0a ]; then
        partial=$(tail -n 1 "$chunk" | wc -c | tr -d ' ')
    fi
    whole=$(( size - partial ))
    (( whole > 0 )) && result=$(head -c "$whole" "$chunk" |
        jq -nrR --arg req "$g_req" --argjson lastout "$g_lastout" "$AG_TRANSCRIPT_JQ" 2>/dev/null)
    rm -f "$chunk"
    IFS=$US read -r d_calls d_errs d_tool d_arg d_reads d_all d_req d_ts d_ttl d_first \
        d_in d_w5 d_w1 d_out d_lastout d_comps d_started d_ended <<<"$result"
    # A jq that failed, or answered in an unexpected shape, has told us
    # nothing, and the offset must not move past what it did not read.
    for f in "$d_calls" "$d_errs" "$d_reads" "$d_all" "$d_ts" "$d_ttl" "$d_first" "$d_in" \
             "$d_w5" "$d_w1" "$d_out" "$d_lastout" "$d_comps"; do
        case $f in ''|*[!0-9]*) return ;; esac
    done
    g_off=$(( g_off + whole ))
    g_calls=$(( g_calls + d_calls )); g_errs=$(( g_errs + d_errs ))
    [ -n "$d_tool" ] && { g_tool=$d_tool; g_arg=$d_arg; }
    g_reads=$(( g_reads + d_reads )); g_all=$(( g_all + d_all ))
    g_req=$d_req
    (( d_ts > 0 ))  && g_ts=$d_ts
    (( d_ttl > 0 )) && g_ttl=$d_ttl
    (( g_first == 0 )) && g_first=$d_first
    g_in=$(( g_in + d_in )); g_w5=$(( g_w5 + d_w5 )); g_w1=$(( g_w1 + d_w1 ))
    g_out=$(( g_out + d_out )); g_lastout=$d_lastout
    g_comps=$(( g_comps + d_comps ))
    run=",$g_bgrun,$d_started,"
    for b in ${d_ended//,/ }; do run=${run//,$b,/,}; done
    while [[ $run == *,,* ]]; do run=${run//,,/,}; done
    run=${run#,}; g_bgrun=${run%,}
}

# An agent in a worktree of its own: what it changed there (untracked files
# count as added lines, as a new file does in a diff), its own commits, which
# a diff alone would miss, and a name only when the name says something.
# Claude Code creates the worktree under .claude/worktrees/ on a generated
# branch, worktree-<name>, started by default from the remote's default branch
# rather than from yours, so the name shown is the agent's own branch if it
# moved to one, else where it started if that is not your code, else none.
agent_worktree() {  # $1 directory -> w_on w_add w_del w_ahead w_label w_kind w_branch
    local out gdir cdir first sha from myhead
    w_on="" w_add=0 w_del=0 w_ahead=0 w_label="" w_kind="" w_branch=""
    out=$(git -C "$1" rev-parse --abbrev-ref HEAD --git-dir --git-common-dir 2>/dev/null) || return
    { IFS= read -r w_branch; IFS= read -r gdir; IFS= read -r cdir; } <<<"$out"
    # A linked worktree's git directory lives in the repository's, under
    # worktrees/. Anything else is the main checkout or a separate clone.
    [ "$gdir" != "$cdir" ] || return
    case $gdir in */worktrees/*) ;; *) return ;; esac
    w_on=1
    [ "$w_branch" = HEAD ] && w_branch=""
    # Where it started, once per agent: the first reflog entry of the branch
    # Claude Code created for it, "branch: Created from origin/main". That
    # branch is worktree-<directory name>; the current branch stands in when
    # there is no such branch. The start never changes, so it is kept.
    if [ -z "$g_base" ]; then
        from="worktree-${1##*/}"
        git -C "$1" rev-parse -q --verify "refs/heads/$from" >/dev/null 2>&1 || from=$w_branch
        first=""
        [ -n "$from" ] && first=$(git -C "$1" reflog show --format='%H %gs' "refs/heads/$from" -- 2>/dev/null |
            tail -n 1)
        sha=${first%% *}; from=""
        [[ $first == *"Created from "* ]] && from=${first##*Created from }
        [ "$from" = origin/HEAD ] && from=$(git -C "$1" rev-parse --abbrev-ref origin/HEAD 2>/dev/null)
        # Started from wherever HEAD was: that says nothing, so name the
        # commit by a branch holding it, yours first (main~2 is your branch
        # two commits back), else any but the generated worktree branches,
        # which all hold it, else by its hash.
        case $from in HEAD|'')
            from=""
            if [ -n "$sha" ]; then
                [ -n "$AG_MY_BRANCH" ] || AG_MY_BRANCH=$(git -C "$S_CWD" branch --show-current 2>/dev/null)
                [ -n "$AG_MY_BRANCH" ] && from=$(git -C "$1" name-rev --name-only --no-undefined \
                    --refs="refs/heads/$AG_MY_BRANCH" "$sha" 2>/dev/null)
                [ -n "$from" ] || from=$(git -C "$1" name-rev --name-only --no-undefined \
                    --refs='refs/heads/*' --exclude='refs/heads/worktree-*' "$sha" 2>/dev/null)
                [ -n "$from" ] || from=${sha:0:7}
            fi ;;
        esac
        [ -n "$sha" ] && g_base="$sha:${from#origin/}"
    fi
    read -r w_add w_del < <(git -C "$1" diff --numstat HEAD -- 2>/dev/null |
        awk '{ a += $1; d += $2 } END { print a + 0, d + 0 }')
    # From inside the worktree: ls-files prints paths relative to it. Read up
    # to AG_UNTRACKED bytes and no further, since this runs every few seconds
    # and a build can leave anything lying around.
    w_add=$(( ${w_add:-0} + $(cd "$1" 2>/dev/null && git ls-files -o --exclude-standard -z 2>/dev/null |
        xargs -0 cat 2>/dev/null | head -c "$AG_UNTRACKED" | wc -l | tr -d ' ') ))
    sha=${g_base%%:*}
    [ -n "$sha" ] && w_ahead=$(git -C "$1" rev-list --count "$sha..HEAD" 2>/dev/null)
    case $w_ahead in ''|*[!0-9]*) w_ahead=0 ;; esac
    if [ -n "$w_branch" ] && [[ $w_branch != worktree-* ]]; then
        w_label=$w_branch; w_kind=own
    elif [ -n "$sha" ]; then
        # Your HEAD inside what it started from means it has your code. The
        # answer is kept with the HEAD it was asked about.
        [ -z "$AG_MY_HEAD" ] && AG_MY_HEAD=$(git -C "$S_CWD" rev-parse HEAD 2>/dev/null)
        myhead=${AG_MY_HEAD:-none}
        if [ "${g_mine%:*}" != "$myhead" ]; then
            if [ "$myhead" != none ] && git -C "$1" merge-base --is-ancestor "$myhead" "$sha" 2>/dev/null
            then g_mine="$myhead:yes"; else g_mine="$myhead:no"; fi
        fi
        if [ "${g_mine##*:}" = no ]; then w_label=${g_base#*:}; w_kind=base; fi
    fi
}

# The pull request of a worktree agent's branch, once it is pushed to origin.
# gh is a network call, so it never runs in the foreground: the row shows what
# the last lookup found, and a detached gh refreshes it at most once a minute
# per branch. The attempt is recorded before gh starts, so a slow one is not
# joined by another every tick, and a lookup that fails keeps what the last
# one found rather than blanking it.
agent_pr() {  # $1 directory  $2 branch -> p_num p_state
    local f at=""
    p_num="" p_state=""
    (( AG_PR_EVERY > 0 )) || return
    command -v gh >/dev/null 2>&1 || return
    git -C "$1" rev-parse -q --verify "refs/remotes/origin/$2" >/dev/null 2>&1 || return
    f="$SFILE.pr.${2//[!A-Za-z0-9._-]/_}"
    [ -r "$f" ] && IFS=$US read -r at p_num p_state < "$f"
    case $at in ''|*[!0-9]*) at=0 ;; esac
    (( NOW - at < AG_PR_EVERY )) && return
    printf '%s%s%s%s%s\n' "$NOW" "$US" "$p_num" "$US" "$p_state" > "$f.$$" 2>/dev/null &&
        mv -f "$f.$$" "$f" 2>/dev/null
    (
        found=$(cd "$1" && gh pr view --json number,state,isDraft,reviewDecision -q '
            [.number, (if   .state == "MERGED" then "merged"
                       elif .state == "CLOSED" then "closed"
                       elif .isDraft then "draft"
                       elif .reviewDecision == "APPROVED" then "approved"
                       elif .reviewDecision == "CHANGES_REQUESTED" then "changes_requested"
                       else "pending" end)] | join(",")' 2>/dev/null)
        [ -n "$found" ] || found="$p_num,$p_state"
        printf '%s%s%s%s%s\n' "$NOW" "$US" "${found%%,*}" "$US" "${found#*,}" > "$f.gh" &&
            mv -f "$f.gh" "$f"
    ) </dev/null >/dev/null 2>&1 &
}

# Everything that is not the payload, in one jq pass: whether auto-compact is
# on (for the context reserve) and the modelPricing table, which Claude Code
# honours only from managed settings.
agent_settings() {  # $1 project directory
    local files f kind a b c d e
    files=(/dev/null)
    for f in "$HOME/.claude.json" "$HOME/.claude/settings.json" \
             "$1/.claude/settings.json" "$1/.claude/settings.local.json"; do
        [ -r "$f" ] && files+=("$f")
    done
    while IFS= read -r f; do files+=("$f"); done < <(managed_settings_files)
    AG_AC=true AG_MULT=1 AG_OVR_ID=() AG_OVR_RATES=()
    while IFS=$US read -r kind a b c d e; do
        case $kind in
            ac)   AG_AC=$a ;;
            mult) AG_MULT=$a ;;
            ovr)  AG_OVR_ID+=("$a"); AG_OVR_RATES+=("$b $c $d $e") ;;
        esac
    done < <(jq -rn --arg ma "$MANAGED_LINUX/" --arg mb "$MANAGED_MACOS/" '
        def num: if type == "number" and . >= 0 then tostring else null end;
        # Files in precedence order, so the last one to set a key wins. Not
        # `false // x`: that is x, and would override an explicit false.
        reduce inputs as $d ({ac: null, mp: {}};
            (input_filename // "") as $f
            | if ($d | type) != "object" then .
              else (if $d.autoCompactEnabled != null then .ac = $d.autoCompactEnabled else . end)
                 | (if (($f | startswith($ma)) or ($f | startswith($mb)))
                       and ($d.modelPricing | type) == "object"
                    then .mp = (.mp * $d.modelPricing) else . end)
              end)
        | .ac as $ac | .mp as $mp
        | (["ac", (if $ac == false then "false" else "true" end)] | join("\u001f")),
          (if ($mp.multiplier | num) and $mp.multiplier > 0 and $mp.multiplier <= 10
           then ["mult", ($mp.multiplier | tostring)] | join("\u001f") else empty end),
          (($mp.overrides // {}) | if type == "object" then to_entries[] else empty end
           | select(.value | type == "object")
           | ["ovr", .key, (.value.input | num), (.value.output | num),
              (.value.cacheRead | num), (.value.cacheWrite | num)]
           | select(all(.[]; . != null)) | join("\u001f"))
    ' "${files[@]}" 2>/dev/null)
    if truthy "${DISABLE_AUTO_COMPACT:-}" || truthy "${DISABLE_COMPACT:-}"; then AG_AC=false; fi
}

# The last step of a row: the task, then the newest tool call, fitted to the
# room left. Here rather than in bash because the fitting is by display
# columns, and bash can only count characters: CJK and emoji take two columns
# each, combining marks and variation selectors none. When both texts do not
# fit, the tool keeps at least 45% of the room and the task gives way.
AG_LABEL_JQ='
  def cw: if (. >= 4352 and . <= 4447) or (. >= 11904 and . <= 42191 and . != 12351)
             or (. >= 44032 and . <= 55203) or (. >= 63744 and . <= 64255)
             or (. >= 65040 and . <= 65049) or (. >= 65072 and . <= 65135)
             or (. >= 65280 and . <= 65376) or (. >= 65504 and . <= 65510)
             or (. >= 127744 and . <= 129791) or (. >= 131072 and . <= 262141) then 2
          elif (. >= 768 and . <= 879) or (. >= 8203 and . <= 8207) or (. >= 65024 and . <= 65039)
          then 0 else 1 end;
  def width: [explode[] | cw] | add // 0;
  def clip($n):
    if $n < 1 then ""
    elif width <= $n then .
    else (reduce (explode[]) as $c ({s: [], w: 0, full: false};
            if .full then .
            elif .w + ($c | cw) > $n - 1 then .full = true
            else .s += [$c] | .w += ($c | cw) end)
          | .s | implode) + "…"
    end;
  split("\u001f") as [$id, $head, $room, $desc, $tool, $arg]
  | ($room | tonumber) as $room
  | ($tool | width) as $tn
  | (if $tool == "" or $room < $tn + 4 then $desc | clip($room)
     else ($tn + 1 + ($arg | width)) as $full
     | (if ($desc | width) + 3 + $full > $room
        then [$room - ($desc | width) - 3, ($room * 45 / 100 | floor)] | max
        else $full end) as $tw
     | ($desc | clip($room - 3 - $tw)) + " " + $g + "·" + $r + " " + $m + $tool + $r + " "
       + $g + ($arg | clip($tw - $tn - 1)) + $r
     end) as $fitted
  | {id: $id, content: ($head + $fitted)}'

agent_rows() {
    local header lines=() line i j k n p id seen

    # ---- the payload, one line per agent
    while IFS= read -r line; do
        if [ -z "$header" ]; then header=$line; else lines+=("$line"); fi
    done < <(jq -r '
        def s: if . == null then "" else tostring end;
        def i: if type == "number" then (floor | tostring) else "" end;
        def flat: explode | map(if . < 32 then 32 else . end) | implode;
        (([.session_id, .transcript_path, .cwd] | map(s | flat)) + [(.columns | i)]
         | join("\u001f")),
        ((.tasks // []) | if type == "array" then .[] else empty end
         | select(type == "object")
         | [(.id | s), (.status | s), (.model | s), (.effort | s),
            (.contextWindowSize | i), (.tokenCount | i), (.startTime | i),
            (.cwd | s), ((.label // .description) | s), (.name | s)]
         | map(flat) | join("\u001f"))
    ' <<<"$INPUT" 2>/dev/null)
    (( ${#lines[@]} > 0 )) || return
    IFS=$US read -r S_SID S_TP S_CWD S_COLS <<<"$header"
    (( S_COLS > 0 )) || S_COLS=${COLUMNS:-80}
    AG_SUB="${S_TP%.jsonl}/subagents"
    AG_PROJ=${CLAUDE_PROJECT_DIR:-$S_CWD}

    agent_settings "$AG_PROJ"
    if [ "$AG_AC" = false ]; then AG_RESERVE=35000; else AG_RESERVE=45000; fi

    # ---- state: the main line's model and effort, and each agent's record
    state_file "$S_SID"
    local main_model="" main_effort="" kind skip model effort
    if [ -n "$SFILE" ] && [ -r "$SFILE" ]; then
        # The main line's "s" record; the model and effort are its last two
        # of eleven fields.
        while IFS=$US read -r kind skip skip skip skip skip skip skip skip skip model effort; do
            [ "$kind" = s ] && { main_model=$model; main_effort=$effort; }
        done < "$SFILE"
    fi
    local main_name=""
    [ -n "$main_model" ] && main_name=$(model_label "$main_model")
    if [ -n "$SFILE" ] && [ -r "$SFILE.agents" ]; then
        while IFS= read -r line; do
            id=${line%%"$US"*}
            [[ $id =~ ^a_[A-Za-z0-9]+$ ]] && printf -v "AG_REC_${id#a_}" '%s' "${line#*"$US"}"
        done < "$SFILE.agents"
    fi

    # ---- one pass over the agents, building every cell
    local r_id=() r_parent=() r_health=() r_br=() r_brw=() r_el=() r_slot=() r_cost=()
    local r_tools=() r_cx=() r_cxw=() r_cache=() r_cachew=() r_pre=() r_prew=()
    local r_mid=() r_midw=() r_desc=() r_tool=() r_arg=() records=""
    local a_id a_status a_model a_effort a_window a_tokens a_start a_cwd a_label a_name counted
    local valid rec eff glyph mname mcol at tc br brw el q slot sw
    local cold cache cachew ratio ttl left spent lc cl cost cost_txt tools ctx ctxw pct den
    local inh num tokc pre prew mid midw nbg commas health pad read_tx
    local w_on w_add w_del w_ahead w_label w_kind w_branch p_num p_state wc wl
    for line in "${lines[@]}"; do
        IFS=$US read -r a_id a_status a_model a_effort a_window a_tokens a_start a_cwd \
            a_label a_name <<<"$line"
        [ -n "$a_id" ] || continue
        # Absent is not zero: an agent with no count yet shows none. Zero only
        # stands in for it where a number has to be compared.
        counted=$a_tokens
        a_tokens=${a_tokens:-0}

        # Only an id that is safe as a variable and file name gets a record; any
        # other still gets a row, drawn from the payload alone.
        valid=""; rec=""
        if [[ $a_id =~ ^[A-Za-z0-9]+$ ]]; then valid=1; eval "rec=\${AG_REC_$a_id:-}"; fi
        agent_load "$rec"
        if [ -z "$rec" ]; then g_since=$NOW; g_growth=$NOW; fi

        # When the current status began, and when the tokens last grew. Both
        # count from the first run that saw them: a lower bound, never more.
        # Growth is measured against the previous run's count, not against
        # the sparkline's history, whose newest point can be AG_BAR old and
        # would hold quiet off for that long.
        [ "$g_status" = "$a_status" ] || { g_status=$a_status; g_since=$NOW; }
        if [ -n "$rec" ] && (( a_tokens > g_last )); then g_growth=$NOW; fi
        g_last=$a_tokens
        g_hist=$(history_add "$g_hist" "$a_tokens")

        # Type, parent and depth, from the metadata file, once.
        if [ -n "$valid" ] && [ "$g_meta" != 1 ] && [ -r "$AG_SUB/agent-$a_id.meta.json" ]; then
            IFS=$US read -r g_type g_parent g_depth < <(jq -r '
                def flat: tostring | explode | map(if . < 32 then 32 else . end) | implode;
                [(.agentType // ""), (.parentAgentId // ""), (.spawnDepth // 1)]
                | map(flat) | join("\u001f")
            ' "$AG_SUB/agent-$a_id.meta.json" 2>/dev/null)
            case $g_depth in ''|*[!0-9]*) g_depth=1 ;; esac
            [[ $g_parent =~ ^[A-Za-z0-9]*$ ]] || g_parent=""
            # A file caught half-written reads as nothing; try it again next run.
            [ -n "$g_type" ] && g_meta=1
        fi
        case $g_type in ''|general-purpose|fork|*:*) ;; *)
            [ -z "$g_colour" ] && g_colour=$(definition_colour "$g_type" "$AG_PROJ")
            [ -z "$g_colour" ] && g_colour=-
        esac
        # Read only with somewhere to keep what was read: without it every
        # run would parse the whole transcript again.
        read_tx=""
        if [ -n "$valid" ] && [ -n "$SFILE" ] && [ -r "$AG_SUB/agent-$a_id.jsonl" ]; then
            read_tx=1
            agent_transcript "$AG_SUB/agent-$a_id.jsonl"
        fi

        # ---- identity bracket: the main line's badge, each part gray where
        # it matches main's. Effort is the agent's own or, absent, main's,
        # which it inherits; an unresolved model has neither.
        mname=$(model_label "$a_model"); glyph=""; eff=""
        if [ -z "$a_model" ]; then
            mname='…'; mcol=$C_GRAY
        else
            if [ -n "$main_name" ] && [ "$mname" = "$main_name" ]; then mcol=$C_GRAY; else mcol=$C_MODEL; fi
            eff=${a_effort:-$main_effort}
            if [ -n "$a_effort" ] || [ -n "$main_model" ]; then
                # Only an agent's effort can be a number, a thinking budget
                # rather than a level.
                case $eff in
                    ''|*[!0-9]*) glyph=$(effort_glyph "$eff") ;;
                    *)           glyph='⠿' ;;
                esac
            fi
        fi
        case $g_type in
            ''|general-purpose) at=""; tc="" ;;
            fork) at="⋔fork"; tc=$C_FORK ;;
            *)    at=$(clip "${g_type#*:}" "$AG_TYPE_MAX"); tc=$(agent_colour "$g_colour") ;;
        esac
        br="[${mcol}${mname}${R}"
        if [ -n "$glyph" ]; then
            if [ -n "$main_model" ] && [ "$eff" = "$main_effort" ]; then br+="${C_GRAY}${glyph}${R}"
            else br+=$glyph; fi
        fi
        [ -n "$at" ] && br+="|${tc}${at}${R}"
        br+="]"
        brw=$(( ${#mname} + ${#glyph} + 2 + ( ${#at} > 0 ? ${#at} + 1 : 0 ) ))

        # A start a hundred days back or more is not an agent's; it would also
        # be wider than the cell.
        el=""
        if (( a_start > 0 )); then
            q=$(( NOW * 1000 - a_start )); (( q < 0 )) && q=0
            (( q < 8640000000 )) && el=$(fmt_duration "$q")
        fi
        printf -v el '%s⌚%s%-3s' "$C_TIME" "$R" "$el"

        # ---- the prompt cache, needed by the activity slot and the context
        cold=""; cache=""; cachew=0
        if (( g_all > 0 )); then
            ratio=$(( g_reads * 100 / g_all ))
            ttl=$g_ttl; (( ttl > 0 )) || ttl=300
            left=$(( g_ts + ttl - NOW ))
            if (( g_ts > 0 && left > 0 )); then
                spent=$(( (ttl - left) * 100 / ttl )); (( spent < 0 )) && spent=0
                lc=$(limit_colour "$spent"); cl=$(fmt_cache_left "$left")
                # A healthy ratio is the least interesting number: shown only low.
                if (( ratio >= 75 )); then cache="⚡${lc}${cl}${R}"; cachew=$(( 2 + ${#cl} ))
                else cache="⚡${ratio}%${lc}⏱${cl}${R}"; cachew=$(( 4 + ${#ratio} + ${#cl} )); fi
            elif (( g_ts > 0 )); then
                cold=1
                cache="⚡${C_COLD}❄${ratio}%${R}"; cachew=$(( 4 + ${#ratio} ))
            else
                cache="⚡${ratio}%"; cachew=$(( 3 + ${#ratio} ))
            fi
        fi

        # ---- activity slot, AG_SLOT wide whatever it holds
        case $a_status in
            failed)  slot="${C_CRIT}✗ failed${R}";  sw=8 ;;
            killed)  slot="${C_HIGH}⚠ stopped${R}"; sw=9 ;;
            pending) slot="${C_GRAY}◌ queued${R}";  sw=8 ;;
            paused)  slot="${C_GRAY}⏸ paused${R}";  sw=8 ;;
            # A completed agent still in the panel is waiting: its turn is
            # over and background work of its own keeps it alive. The panel
            # hides agents that are truly done.
            completed)
                q=$(fmt_duration $(( (NOW - g_since) * 1000 )))
                printf -v slot '%s⧖ wait%s%*s%s%s%s' "$C_MODES" "$R" $(( AG_SLOT - 6 - ${#q} )) '' \
                    "$C_TIME" "$q" "$R"
                sw=$AG_SLOT ;;
            *)
                q=$(( NOW - g_growth ))
                if (( q >= AG_QUIET )); then
                    cl=$(fmt_duration $(( q * 1000 )))
                    if   (( q < 60 ));  then lc=$C_GRAY
                    elif (( q < 300 )); then lc=$C_MID
                    else                     lc=$C_HIGH; fi
                    printf -v pad '%*s' $(( AG_SLOT - 1 - ${#cl} )) ''
                    slot="${C_GRAY}${pad// /▁}${R} ${lc}${cl}${R}"
                else
                    slot=$(sparkline "$(history_tokens "$g_hist")")
                fi
                sw=$AG_SLOT ;;
        esac
        printf -v pad '%*s' $(( AG_SLOT - sw )) ''
        slot+=$pad

        # ---- cost and tool calls, as the main line's $ and ⌚ cells
        cost_txt="      "
        if (( g_all + g_out > 0 )); then
            cost=$(agent_cost "$a_model")
            if [ -n "$cost" ]; then
                if awk -v c="$cost" 'BEGIN { exit !(c >= 100) }'; then cost=$(printf '%.0f' "$cost")
                else cost=$(printf '%.2f' "$cost"); fi
                if [ "$cost" = 0.00 ]; then printf -v cost_txt '$%s%-5s%s' "$C_GRAY" "$cost" "$R"
                else printf -v cost_txt '%s$%-5s%s' "$C_COST" "$cost" "$R"; fi
            fi
        fi
        tools="    "
        if [ -n "$read_tx" ]; then
            if (( g_calls < 1000 )); then n=$g_calls; else n="$(( g_calls / 1000 ))k"; fi
            printf -v tools '%s⚒%s%-3s' "$C_TIME" "$R" "$n"
        fi

        # ---- context, the main line's formula: a share of the room before
        # auto-compaction. A fork shows what it inherited and what it added,
        # ⋔366+5K, from its first request; one that has since shrunk below its
        # inheritance (tool results cleared on waking) shows only the total.
        # Cold, the cell takes the ❄: waking the agent rebuilds this context.
        tokc=$C_GRAY; [ -n "$cold" ] && tokc=$C_COLD
        ctx=""; ctxw=0
        if [ -n "$counted" ]; then
            num=$(fmt_tokens "$a_tokens")
            if [ "$g_type" = fork ] && (( g_first > 0 )); then
                if (( a_tokens >= g_first )); then
                    inh=$(fmt_tokens "$g_first")
                    num="${inh%K}+$(fmt_tokens $(( a_tokens - g_first )))"
                fi
                num="⋔$num"
            fi
            [ -n "$cold" ] && num="❄$num"
            ctx="${tokc}${num}${R}"; ctxw=${#num}
            if (( a_window > 0 )); then
                den=$(( a_window - AG_RESERVE )); (( den < 1 )) && den=$a_window
                pct=$(( a_tokens * 100 / den )); (( pct > 100 )) && pct=100
                ctx+="·$(context_colour "$pct")${pct}%${R}"; ctxw=$(( ctxw + 2 + ${#pct} ))
            fi
        fi

        # ---- label marks, each only when it applies. Before the +N count:
        # output past AG_OUT_MIN and compactions. After it: running background
        # commands, the worktree and its pull request, the name, failed calls.
        pre=""; prew=0
        if (( g_out > AG_OUT_MIN )); then
            num="↗$(fmt_tokens "$g_out")"; pre+="${C_GRAY}${num}${R} "; prew=$(( prew + ${#num} + 1 ))
        fi
        (( g_comps > 0 )) && { pre+="${C_HIGH}⟲${g_comps}${R} "; prew=$(( prew + 2 + ${#g_comps} )); }
        mid=""; midw=0
        nbg=0
        if [ -n "$g_bgrun" ]; then commas=${g_bgrun//[!,]/}; nbg=$(( ${#commas} + 1 )); fi
        (( nbg > 0 )) && { mid+="${C_MODES}&${nbg}${R} "; midw=$(( midw + 2 + ${#nbg} )); }
        if [ -n "$a_cwd" ] && [ "$a_cwd" != "$S_CWD" ]; then
            agent_worktree "$a_cwd"
            if [ -n "$w_on" ]; then
                if (( w_add > 0 || w_del > 0 || w_ahead > 0 )); then wc=$C_DIRTY; else wc=$C_BRANCH; fi
                wl=$(shorten "$w_label")
                mid+="${wc}⎇${R}"; midw=$(( midw + 1 + ${#wl} ))
                if   [ "$w_kind" = base ]; then mid+="${C_ELSEWHERE}${wl}${R}"
                elif [ -n "$wl" ];         then mid+="${wc}${wl}${R}"; fi
                num="+${w_add}/-${w_del}"; midw=$(( midw + ${#num} ))
                if (( w_add > 0 || w_del > 0 )); then mid+="${C_ADD}+${w_add}${R}/${C_DEL}-${w_del}${R}"
                else mid+="${C_GRAY}${num}${R}"; fi
                (( w_ahead > 0 )) && { mid+="${C_DIRTY}↑${w_ahead}${R}"; midw=$(( midw + 1 + ${#w_ahead} )); }
                mid+=" "; midw=$(( midw + 1 ))
                if [ -n "$w_branch" ] && [ -n "$SFILE" ]; then
                    agent_pr "$a_cwd" "$w_branch"
                    if [ -n "$p_num" ]; then
                        mid+="${C_GRAY}#${p_num}${R}"; midw=$(( midw + 1 + ${#p_num} ))
                        case $p_state in
                            approved)          mid+="${C_LOW}✓${R}" ;;
                            pending)           mid+="${C_WARM}⋯${R}" ;;
                            changes_requested) mid+="${C_CRIT}✗${R}" ;;
                            draft)             mid+="${C_GRAY}◌${R}" ;;
                            merged)            mid+="${C_PLAN_ENT}✓${R}" ;;
                        esac
                        case $p_state in approved|pending|changes_requested|draft|merged) midw=$(( midw + 1 )) ;; esac
                        mid+=" "; midw=$(( midw + 1 ))
                    fi
                fi
            fi
        fi
        [ -n "$a_name" ] && { mid+="${C_BOLD}@${a_name}${R} "; midw=$(( midw + 2 + ${#a_name} )); }
        (( g_errs > 0 )) && { mid+="${C_CRIT}✗${g_errs}${R} "; midw=$(( midw + 2 + ${#g_errs} )); }

        # Health, for the +N of every ancestor: failed or stopped outranks
        # stuck (quiet AG_STUCK or longer), which outranks waiting gone cold.
        health=0
        case $a_status in
            failed|killed) health=3 ;;
            running)       (( NOW - g_growth >= AG_STUCK )) && health=2 ;;
            completed)     [ -n "$cold" ] && health=1 ;;
        esac

        r_id+=("$a_id"); r_parent+=("$g_parent"); r_health+=("$health")
        r_br+=("$br"); r_brw+=("$brw"); r_el+=("$el"); r_slot+=("$slot")
        r_cost+=("$cost_txt"); r_tools+=("$tools"); r_cx+=("$ctx"); r_cxw+=("$ctxw")
        r_cache+=("$cache"); r_cachew+=("$cachew"); r_pre+=("$pre"); r_prew+=("$prew")
        r_mid+=("$mid"); r_midw+=("$midw"); r_desc+=("$a_label")
        r_tool+=("$g_tool"); r_arg+=("$g_arg")
        [ -n "$valid" ] && records+="a_$a_id$US$(agent_record)"$'\n'
    done
    n=${#r_id[@]}

    # ---- the tree. The payload has no parent field; the metadata does. For
    # each agent, walk up through the ancestors in the panel: its depth, and
    # one more descendant (with its health) for each of them. The panel draws
    # its own tree connector in front of a row, two columns per ancestor, but
    # drops its own +N count once a row is replaced, so that is rebuilt here.
    local depth=() desc=() worst=()
    for (( j = 0; j < n; j++ )); do depth[j]=0; desc[j]=0; worst[j]=0; done
    for (( j = 0; j < n; j++ )); do
        p=${r_parent[j]}; seen=" ${r_id[j]} "
        while [ -n "$p" ] && [[ $seen != *" $p "* ]]; do
            seen+="$p "
            k=-1
            for (( i = 0; i < n; i++ )); do [ "${r_id[i]}" = "$p" ] && { k=$i; break; }; done
            (( k < 0 )) && break
            depth[j]=$(( depth[j] + 1 ))
            desc[k]=$(( desc[k] + 1 ))
            (( r_health[j] > worst[k] )) && worst[k]=${r_health[j]}
            p=${r_parent[k]}
        done
    done

    # ---- columns. The bracket column ends where the widest bracket does,
    # counted from the panel's edge, so a nested row's connector eats into its
    # own padding and every column after it lines up with the rows above.
    local brmax=0 cxmax=$AG_CTX_MIN
    for (( j = 0; j < n; j++ )); do
        (( 2 * depth[j] + r_brw[j] > brmax )) && brmax=$(( 2 * depth[j] + r_brw[j] ))
        (( r_cxw[j] > cxmax )) && cxmax=${r_cxw[j]}
    done

    local out="" first bpad cpad kpad head lab labw room sub subw
    for (( j = 0; j < n; j++ )); do
        first=$(( brmax - 2 * depth[j] ))
        printf -v bpad '%*s' $(( first - r_brw[j] )) ''
        printf -v cpad '%*s' $(( cxmax - r_cxw[j] )) ''
        printf -v kpad '%*s' $(( AG_CACHE_W - r_cachew[j] )) ''
        head="${r_br[j]}${bpad} ${r_el[j]} ${r_slot[j]} ${r_cost[j]} ${r_tools[j]} ${cpad}${r_cx[j]} ${r_cache[j]}${kpad} │ "
        sub=""; subw=0
        if (( desc[j] > 0 )); then
            sub="${C_SUBTREE}+${desc[j]}${R}"; subw=$(( 1 + ${#desc[j]} ))
            case ${worst[j]} in
                3) sub+="${C_CRIT}✗${R}" ;;
                2) sub+="${C_HIGH}▁${R}" ;;
                1) sub+="${C_COLD}❄${R}" ;;
            esac
            (( worst[j] > 0 )) && subw=$(( subw + 1 ))
            sub+=" "; subw=$(( subw + 1 ))
        fi
        lab="${r_pre[j]}${sub}${r_mid[j]}"
        labw=$(( r_prew[j] + subw + r_midw[j] ))
        # ⌚ and ⚡ take two columns each; the panel's connector is outside
        # the row but inside its width.
        room=$(( S_COLS - 2 * depth[j] - first - 6 - (AG_SLOT + 1) - 7 - 5 - (cxmax + 1) \
                 - (AG_CACHE_W + 1) - 3 - labw ))
        out+="${r_id[j]}$US${head}${lab}$US$room$US${r_desc[j]}$US${r_tool[j]}$US${r_arg[j]}"$'\n'
    done

    # ---- state first, output last: the state is only what this run saw, so
    # an agent that has left the panel leaves the file too.
    if [ -n "$SFILE" ]; then
        printf '%s' "$records" > "$SFILE.agents.$$" 2>/dev/null &&
            mv -f "$SFILE.agents.$$" "$SFILE.agents" 2>/dev/null
        rm -f "$SFILE.agents.$$" 2>/dev/null
    fi
    printf '%s' "$out" | jq -Rc --arg g "$C_GRAY" --arg m "$C_MODES" --arg r "$R" "$AG_LABEL_JQ" 2>/dev/null
}

# The agent payload is the only one with a tasks array. Matching the text,
# rather than asking jq, keeps the main line to its two jq passes; a "tasks"
# quoted inside some string value arrives escaped, and cannot match.
if [[ $INPUT =~ \"tasks\"[[:space:]]*: ]]; then
    agent_rows
    exit 0
fi

# ------------------------------------------------------------ payload, 1x ---
# One jq pass over stdin, emitting key/value pairs rather than a fixed sequence
# so nothing can silently shift if a field is added later. @tsv escapes any
# embedded tab or newline, so no value can break the line structure. Integer
# fields are floored: a float reaching $(( )) is a syntax error that would
# abandon the rest of the enclosing compound command, blanking part of the line.
while IFS=$'\t' read -r k v; do
    [ -n "$k" ] && printf -v "P_$k" '%s' "$v"
done < <(jq -r '
  def s: if . == null then "" else tostring end;
  # Not `floor` on whatever arrives: jq builds this array in one go, so one
  # string where a number was expected fails the whole program and the line
  # renders as if stdin had been empty. A wrong type is an absent field.
  def i: if type == "number" then (floor | tostring) else "" end;
  [ ["session_id",  (.session_id // "")]
  , ["prompt_id",   (.prompt_id // "")]
  , ["model_name",  (.model.display_name // "")]
  , ["model_id",    (.model.id // "")]
  , ["effort",      (.effort.level // "")]
  , ["fast",        (if .fast_mode then "1" else "" end)]
  , ["style",       (.output_style.name // "")]
  , ["vim",         (.vim.mode // "")]
  , ["agent",       (.agent.name // "")]
  , ["remote",      (if .remote then "1" else "" end)]
  , ["added",       ((.workspace.added_dirs // []) | length | tostring)]
  , ["wt_name",     (.worktree.name // "")]
  , ["git_wt",      (.workspace.git_worktree // "")]
  , ["cur_dir",     (.workspace.current_dir // "")]
  , ["proj_dir",    (.workspace.project_dir // "")]
  , ["pr_num",      (.pr.number | i)]
  , ["pr_kind",     (.pr.kind // "")]
  , ["pr_state",    (.pr.review_state // "")]
  , ["dur_ms",      (.cost.total_duration_ms | i)]
  , ["api_ms",      (.cost.total_api_duration_ms | i)]
  , ["l_add",       (.cost.total_lines_added | i)]
  , ["l_del",       (.cost.total_lines_removed | i)]
  , ["cost",        (.cost.total_cost_usd | s)]
  , ["rl5",         (.rate_limits.five_hour.used_percentage | s)]
  , ["rl5_at",      (.rate_limits.five_hour.resets_at | i)]
  , ["rl7",         (.rate_limits.seven_day.used_percentage | s)]
  , ["rl7_at",      (.rate_limits.seven_day.resets_at | i)]
  , ["rlf",         (.rate_limits.seven_day_overage_included.used_percentage | s)]
  , ["rlf_at",      (.rate_limits.seven_day_overage_included.resets_at | i)]
  , ["rls",         (.rate_limits.spend_limit.used_percentage | s)]
  , ["rls_at",      (.rate_limits.spend_limit.resets_at | i)]
  , ["ctx_size",    (.context_window.context_window_size | i)]
  , ["ctx_used",    ((.context_window.current_usage) as $u
                     | (if $u == null then 0
                        else (($u.input_tokens // 0)
                              + ($u.cache_creation_input_tokens // 0)
                              + ($u.cache_read_input_tokens // 0)) end)
                     | tostring)]
  , ["out_tok",     (.context_window.total_output_tokens | i)]
  , ["pc",          (if .prompt_cache then "1" else "" end)]
  , ["pc_ratio",    (.prompt_cache.hit_ratio | s)]
  , ["pc_warm",     (if .prompt_cache.warm then "1" else "" end)]
  , ["pc_expires",  (.prompt_cache.expires_at | i)]
  , ["pc_recache",  (.prompt_cache.recache_tokens_if_cold | i)]
  , ["pc_misses",   (.prompt_cache.misses | i)]
  , ["pc_observed", (if (.prompt_cache == null) or (.prompt_cache.caching_observed)
                     then "1" else "" end)]
  , ["pc_ttl",      (.prompt_cache.ttl // "")]
  , ["pc_miss_at",  (.prompt_cache.last_miss_at | i)]
  , ["pc_causes",   ((.prompt_cache.last_miss_cause.causes // []) | join(","))]
  , ["pc_t_add",    (.prompt_cache.last_miss_cause.tools_added | i)]
  , ["pc_t_del",    (.prompt_cache.last_miss_cause.tools_removed | i)]
  , ["pc_sys_d",    (.prompt_cache.last_miss_cause.system_char_delta | i)]
  , ["pc_recached", (.prompt_cache.miss_recache_tokens | i)]
  ] | .[] | @tsv' <<<"$INPUT" 2>/dev/null)

# ------------------------------------------ account facts and settings, 1x ---
# Not in the payload, so read from disk, all files in one pass. Identity is
# selected by shape rather than by position: with positional indexing a missing
# credentials file shifts every other file up and silently disables the
# billingType fallback that exists for exactly that case.
#
# autoCompactEnabled resolves as "any settings file that defines it wins, in
# precedence order, else the legacy global config in ~/.claude.json, else true",
# so ~/.claude.json leads the list and managed policy ends it. /dev/null leads
# the argument list so jq never falls back to reading stdin.
CFG=("$HOME/.claude/.credentials.json" "$HOME/.claude.json"
     "$HOME/.claude/settings.json")
[ -n "$P_proj_dir" ] && CFG+=("$P_proj_dir/.claude/settings.json"
                              "$P_proj_dir/.claude/settings.local.json")
while IFS= read -r f; do CFG+=("$f"); done < <(managed_settings_files)
READABLE=(/dev/null)
for f in "${CFG[@]}"; do [ -r "$f" ] && READABLE+=("$f"); done

while IFS=$'\t' read -r k v; do
    [ -n "$k" ] && printf -v "A_$k" '%s' "$v"
done < <(jq -s -r '
  def firstnn(f): [.[] | f] | map(select(. != null)) | (.[0] // "");
  [ ["sub",     firstnn(.claudeAiOauth.subscriptionType)]
  , ["billing", firstnn(.oauthAccount.billingType)]
  , ["org",     firstnn(.oauthAccount.organizationName)]
  , ["email",   firstnn(.oauthAccount.emailAddress)]
  , ["ac",      ([.[] | .autoCompactEnabled] | map(select(. != null))
                 | if length == 0 then "true" else (.[-1] | tostring) end)]
  ] | .[] | @tsv' "${READABLE[@]}" 2>/dev/null)

# ------------------------------------------------------- identity bracket ---
if [ -n "$A_sub" ]; then
    PLAN=$A_sub
else
    case $A_billing in
        stripe_subscription|stripe_subscription_contracted|apple_subscription|google_play_subscription)
            if [ -n "$A_org" ]; then PLAN=team; else PLAN=pro; fi ;;
        workspace_billing) PLAN=enterprise ;;
        *)                 PLAN="" ;;
    esac
fi
case $PLAN in
    pro)        PLAN_TXT="${C_PLAN}Pro${R}" ;;
    max)        PLAN_TXT="${C_PLAN}Max${R}" ;;
    team)       PLAN_TXT="${C_PLAN}Team${R}" ;;
    enterprise) PLAN_TXT="${C_PLAN_ENT}Enterprise${R}" ;;
    free)       PLAN_TXT="${C_GRAY}Free${R}" ;;
    "")         PLAN_TXT="${C_PLAN_API}API${R}" ;;
    # A tier this script has not heard of is still a subscription; labelling it
    # API would demote a paying user on the day Anthropic adds one.
    *)          PLAN_TXT="${C_PLAN}$(ucfirst "$PLAN")${R}" ;;
esac

USER_TXT=""
[ -n "$A_email" ] && USER_TXT="${C_GRAY}${A_email%%@*}${R}|"

# The badge is identity only. The window size lives beside the token count it
# scales, so it is not repeated here, and nothing semantic is read out of
# display_name, which is prose with no stability contract.
MODEL_TXT=${P_model_name% (*}
[ -z "$MODEL_TXT" ] && MODEL_TXT="?"

# Shape is effort, colour is fast mode.
GLYPH=$(effort_glyph "$P_effort")
if [ -n "$P_fast" ]; then EFFORT_TXT="${C_FAST}${GLYPH}${R}"; else EFFORT_TXT=$GLYPH; fi

# ---------------------------------------------------------- modes cluster ---
# Absent by default. Every flag is a non-default session state, and one colour
# for the group keeps five columns from turning into five hues.
MODES=""
if [ -n "$P_style" ] && [ "$P_style" != "default" ]; then
    case $P_style in
        Concise)     MODES+='≡' ;;
        Explanatory) MODES+='※' ;;
        Learning)    MODES+='✎' ;;
        Proactive)   MODES+='»' ;;
        *)           MODES+="$(ucfirst "${P_style:0:1}")" ;;  # custom: any name
    esac
fi
[ -n "$P_vim" ]    && MODES+="${P_vim:0:1}"
[ -n "$P_agent" ]  && MODES+='@'
[ -n "$P_remote" ] && MODES+='⧉'
if (( ${P_added:-0} > 0 )); then
    CIRCLED=(⓪ ① ② ③ ④ ⑤ ⑥ ⑦ ⑧ ⑨)
    if (( P_added <= 9 )); then MODES+="${CIRCLED[$P_added]}"; else MODES+='⊕'; fi
fi
MODES_TXT=""
[ -n "$MODES" ] && MODES_TXT=" ${C_MODES}${MODES}${R}"

# ---------------------------------------------------- branch, worktree, PR ---
# Not GIT_DIR: that is git's own variable, and if one ever arrives exported the
# assignment keeps the attribute and every git call below reads it as a .git
# path and fails, so the bar would permanently read no-git.
REPO_DIR=${P_cur_dir:-$PWD}

# --show-current prints nothing on a detached HEAD, which is the state during a
# conflicted rebase or a bisect: exactly when the branch cell matters most.
if [ -n "$P_wt_name" ]; then
    REF=$P_wt_name; MARK='⎇'
else
    REF=$(git -C "$REPO_DIR" branch --show-current 2>/dev/null)
    [ -z "$REF" ] && REF=$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null)
    if [ -n "$P_git_wt" ]; then MARK='⑂'; else MARK=''; fi
fi

if [ -z "$REF" ]; then
    GIT_TXT="${C_GRAY}no-git${R}"
else
    LABEL="${MARK}$(shorten "$REF")"
    # `git diff` refreshes the index as it goes, where `diff-index` compares
    # stale stat data and can call a file dirty that only had its mtime touched.
    # Exit 1 is dirty; 128 and 129 mean not a repository, reachable when the
    # label came from worktree.name rather than from git. Untracked files are
    # not counted by either, which is why the comment says "modified".
    git -C "$REPO_DIR" diff --quiet HEAD -- 2>/dev/null
    (( $? == 1 )) && LABEL="${LABEL}*"
    if [ -n "$P_proj_dir" ] && [ -n "$P_cur_dir" ] && [ "$P_cur_dir" != "$P_proj_dir" ]; then
        GIT_TXT="${C_ELSEWHERE}${LABEL}${R}"
    elif [[ $LABEL == *\* ]]; then
        GIT_TXT="${C_DIRTY}${LABEL}${R}"
    else
        GIT_TXT="${C_BRANCH}${LABEL}${R}"
    fi
fi

# The number identifies, the glyph is the state you act on, so only the glyph
# takes colour. GitLab writes merge requests as !123, GitHub as #123.
PR_TXT=""
if [ -n "$P_pr_num" ]; then
    if [ "$P_pr_kind" = "mr" ]; then SIGIL='!'; else SIGIL='#'; fi
    PR_TXT=" ${C_GRAY}${SIGIL}${P_pr_num}${R}"
    case $P_pr_state in
        approved)          PR_TXT+="${C_LOW}✓${R}" ;;
        pending)           PR_TXT+="${C_WARM}⋯${R}" ;;
        changes_requested) PR_TXT+="${C_CRIT}✗${R}" ;;
        draft)             PR_TXT+="${C_GRAY}◌${R}" ;;
    esac
fi

# ------------------------------------------------------- time, lines, cost ---
if (( ${P_dur_ms:-0} > 0 )); then DUR_TXT="${C_TIME}⌚${R}$(fmt_duration "$P_dur_ms")"
else                              DUR_TXT="${C_TIME}⌚${R}${C_GRAY}0s${R}"; fi
if (( ${P_api_ms:-0} > 0 )); then API_TXT="${C_TIME}Ⓐ${R}$(fmt_duration "$P_api_ms")"
else                              API_TXT="${C_TIME}Ⓐ${R}${C_GRAY}0s${R}"; fi

if (( ${P_l_add:-0} > 0 || ${P_l_del:-0} > 0 )); then
    LINES_TXT="${C_ADD}+$(num "$P_l_add")${R}/${C_DEL}-$(num "$P_l_del")${R}"
else
    LINES_TXT="${C_GRAY}+0/-0${R}"
fi

COST_FMT=$(printf '%.2f' "${P_cost:-0}" 2>/dev/null)
[ -z "$COST_FMT" ] && COST_FMT=0.00
if [ "$COST_FMT" = "0.00" ]; then COST_TXT="\$${C_GRAY}0.00${R}"
else                              COST_TXT="${C_COST}\$${COST_FMT}${R}"; fi

# ------------------------------------------------------------- rate limits ---
# Absent until the session's first API response, and always absent on API-key,
# Bedrock and Vertex auth, so absence is not zero and must render nothing.
# Only 5h is unconditional: the others are noise until they constrain.
# Rounded once here and reused by the pace cell and the band arithmetic, which
# both used to round them again.
R5=$(round "${P_rl5:-0}"); R7=$(round "${P_rl7:-0}")

LIMIT_PARTS=()
add_limit() {  # $1 letter (empty for 5h)  $2 pct  $3 resets_at  $4 grain
    local p u
    [ -z "$2" ] && return
    p=$(round "$2")
    [ -n "$1" ] && (( p <= 75 )) && return
    u=$(fmt_until "$3" "$4") || u=""
    LIMIT_PARTS+=("$(limit_colour "$p")${1}${p}%${R}${u:+${C_GRAY}→${u}${R}}")
}
# Minutes as well as hours past 50%, where "coffee or lunch" becomes a real
# question. The others stay coarse: they only appear above 75%, and three days
# versus three days and four hours changes nothing you would do.
if (( R5 >= 50 )); then G=fine; else G=coarse; fi
add_limit ""  "$P_rl5" "$P_rl5_at" "$G"
add_limit "W" "$P_rl7" "$P_rl7_at" coarse
# Read if it ever appears. This window is not part of the status line payload
# today, and the slot is absent-safe, so being ready for it costs nothing.
add_limit "F" "$P_rlf" "$P_rlf_at" coarse
# Emitted only behind a Claude apps gateway, and can exceed 100.
add_limit "S" "$P_rls" "$P_rls_at" coarse

LIMIT_TXT=""
(( ${#LIMIT_PARTS[@]} > 0 )) && LIMIT_TXT=" ${C_GRAY}⧗${R}${LIMIT_PARTS[*]}"

# ------------------------------------------------------------------- pace ---
# Where the weekly window lands at the reset if the average rate since the week
# began is kept up. The week began one WEEK before it resets, which the payload
# gives, so this needs no history: it is used% divided by the fraction of the
# week already gone. Absent with the weekly window itself (API key, Bedrock,
# Vertex, before the first response), and absent through the first day, where
# the divisor is small enough to make the answer meaningless rather than
# alarming.
PACE=""; PACE_TXT=""
if [ -n "$P_rl7" ] && (( ${P_rl7_at:-0} > 0 )); then
    ELAPSED=$(( NOW - (P_rl7_at - WEEK) ))
    if (( ELAPSED >= PACE_MIN_ELAPSED && ELAPSED <= WEEK )); then
        PACE=$(( (R7 * WEEK + ELAPSED / 2) / ELAPSED ))
        # Capped for width only. Past this the cell says "far too fast", and
        # the exact figure changes nothing you would do about it.
        (( PACE > 999 )) && PACE=999
        if   (( PACE >= PACE_RED )); then PC_COL=$C_CRIT
        # Buffer is headroom, so 1 means "warn once under one point of it is
        # left", i.e. from 99 up. Raising it warns earlier.
        elif (( PACE >= 100 - PACE_BUFFER )); then PC_COL=$C_ALERT
        else PC_COL=$C_GRAY; fi
        PACE_TXT=" ${PC_COL}»${PACE}%${R}"
    fi
fi

# ---------------------------------------------------------- context window ---
# The reserve is a constant number of tokens, not a fraction of the window:
# compaction fires a fixed distance below the end of it. With auto-compact off
# nothing compacts, but a hard block still sits nearer the end than the
# compaction trigger does, so the reserve shrinks rather than disappearing.
if truthy "${DISABLE_AUTO_COMPACT:-}" || truthy "${DISABLE_COMPACT:-}"; then
    A_ac=false
fi
if [ "$A_ac" = "false" ]; then RESERVE=35000; else RESERVE=45000; fi

CTX_SIZE=${P_ctx_size:-0}
CTX_USED=${P_ctx_used:-0}
DENOM=$(( CTX_SIZE - RESERVE ))
(( DENOM < 1 )) && DENOM=$CTX_SIZE
(( DENOM < 1 )) && DENOM=1
PCT=$(( CTX_USED * 100 / DENOM ))
(( PCT > 100 )) && PCT=100

BAR_WIDTH=15
PCT_TEXT="${PCT}%"
FILLED=$(( PCT * BAR_WIDTH / 100 ))
REMAINING=$(( BAR_WIDTH - FILLED ))
if (( REMAINING >= ${#PCT_TEXT} )); then
    printf -v FILL '%*s' "$FILLED" ''
    printf -v GAP  '%*s' $(( REMAINING - ${#PCT_TEXT} )) ''
    BAR="${FILL// /#}${GAP// /-}"
else
    printf -v FILL '%*s' $(( BAR_WIDTH - ${#PCT_TEXT} )) ''
    BAR="${FILL// /#}"
fi
CTX_TXT="$(fmt_tokens "$CTX_USED")/$(fmt_tokens "$CTX_SIZE") [${BAR}$(context_colour "$PCT")${PCT_TEXT}${R}]"

# ----------------------------------------------------------- session state ---
# One file per session in the runtime directory, so it dies with the login
# (Linux) or is per-user and swept by the OS (macOS). It holds what this render
# cannot know on its own: the causes of recent cache misses (the payload
# reports only the latest), what the previous render saw, and any brief still
# inside its minute. Read once here, written once at the very end, and only
# when something in it changed, so an idle session touches it not at all.
#
# Lines are typed by their first field, so a format that grows later cannot
# shift the meaning of an old line, and a file from an earlier version is
# ignored rather than misread.
#   m <at> <count> <causes>     one cache miss
#   s <prompt_id> <activity> <out_tok> <band5> <at5> <band7> <at7> <recached> <opened>
#     <model_id> <effort>       the last two for the agent rows, which read them
#   b <expires> <text>          a brief, already rendered
#
# Fields are separated by US (0x1f), not by a tab. Tab is IFS *whitespace*, so
# `IFS=$'\t' read` folds a run of tabs into one delimiter and every field after
# an empty one shifts left. Three of these are routinely empty: prompt_id
# before the first turn, and both resets_at before the first API response. That
# put an activity timestamp in prompt_id and a zero in activity, and the line
# greeted the first prompt of every session with "back after 20723d". US is not
# whitespace, so empty fields survive. A file from an earlier version has no US
# in it at all, so its whole line lands in `kind`, matches nothing, and is
# ignored, which is what the typed-line format is for.
J_AT=(); J_COUNT=(); J_CAUSES=(); SFILE=""; STATE_DIRTY=""
S_prompt=""; S_activity=""; S_out=""; S_band5=0; S_at5=""; S_band7=0; S_at7=""
S_recached=""; S_opened=""; S_model=""; S_effort=""; B_EXPIRES=0; B_TEXT=""
# A state file that cannot be kept is worse than no briefs at all: nothing
# would record that a brief had been shown, so the opening one would print on
# every render for the life of the session. An empty SFILE says the file is
# not usable, and it also suppresses every brief below.
state_file "$P_session_id"
if [ -n "$SFILE" ] && [ -r "$SFILE" ]; then
    while IFS=$US read -r kind a b c d e f g h i j k; do
        case $kind in
            m) case $a in ''|*[!0-9]*) continue ;; esac
               J_AT+=("$a"); case $b in ''|*[!0-9]*) b=0 ;; esac
               J_COUNT+=("$b"); J_CAUSES+=("$c") ;;
            s) S_prompt=$a; S_activity=$b; S_out=$c; S_band5=${d:-0}; S_at5=$e
               S_band7=${f:-0}; S_at7=$g; S_recached=$h; S_opened=$i
               S_model=$j; S_effort=$k ;;
            # Validated because a torn or hand-edited file would otherwise put
            # a non-number into arithmetic, which prints to stderr on every
            # render until the file is next rewritten.
            b) case $a in ''|*[!0-9]*) a=0 ;; esac
               B_EXPIRES=$a; B_TEXT=$b ;;
        esac
    done < "$SFILE"
fi
case $S_band5 in ''|*[!0-9]*) S_band5=0 ;; esac
case $S_band7 in ''|*[!0-9]*) S_band7=0 ;; esac
case $S_activity in ''|*[!0-9]*) S_activity="" ;; esac

# The band each window stands in now. A window this render has not seen before,
# because it has just rolled over or because limits have only now appeared, is
# SEEDED at its current band rather than reset to zero: zero would read as a
# crossing of every band below wherever it already stands, and announce "12%"
# the moment a new five-hour window opens.
CUR5=$(band "$R5"); CUR7=$(band "$R7")
[ "$S_at5" = "$P_rl5_at" ] || S_band5=$CUR5
[ "$S_at7" = "$P_rl7_at" ] || S_band7=$CUR7

# Activity is the last moment the session did anything: a new prompt, or more
# output tokens. Not the render clock, which ticks while idle, and not the
# prompt alone, which would call a twenty-minute turn twenty minutes away.
ACTIVITY=${S_activity:-$NOW}
if [ "$P_out_tok" != "$S_out" ] || [ "$P_prompt_id" != "$S_prompt" ]; then
    ACTIVITY=$NOW
fi

# Pulled out of the array before the arithmetic: bash 3.2 evaluates a
# subscript that `||` should have short-circuited, so J_AT[JN-1] with JN of 0
# prints "bad array subscript" to stderr on every render of a healthy session.
JN=${#J_AT[@]}
LAST_AT=0; LAST_COUNT=0
if (( JN > 0 )); then LAST_AT=${J_AT[JN-1]}; LAST_COUNT=${J_COUNT[JN-1]}; fi
NEW_MISS=""
if (( ${P_pc_miss_at:-0} > 0 && (JN == 0 || P_pc_miss_at > LAST_AT) )); then
    # Two misses between renders leave only the later cause visible; record
    # the earlier one as undiagnosed so the sequence stays the right length.
    if (( JN > 0 && P_pc_misses - LAST_COUNT > 1 )); then
        J_AT+=("$P_pc_miss_at"); J_COUNT+=($(( P_pc_misses - 1 ))); J_CAUSES+=("unknown")
    fi
    J_AT+=("$P_pc_miss_at"); J_COUNT+=("${P_pc_misses:-0}"); J_CAUSES+=("$P_pc_causes")
    STATE_DIRTY=1; NEW_MISS=1; JN=${#J_AT[@]}
fi

# ------------------------------------------------------------ prompt cache ---
# hit_ratio counts cache reads against ALL input tokens, uncached included, so
# it reads lower than v3's per-request ratio and is the honest number.
CACHE_TXT=""
if [ -n "$P_pc_observed" ]; then
    if [ -n "$P_pc_ratio" ]; then
        CACHE_TXT="⚡$(round "${P_pc_ratio}e2")%"
    else
        CACHE_TXT="⚡${C_GRAY}N/A${R}"
    fi
    # Countdown while warm, cold marker otherwise. The colour bands are the
    # rate-limit ones applied to the share of the TTL already spent, so the
    # line has one colour language and a 5-minute TTL is not alarmed all its
    # life. Only a cache that exists can be cold: before the first API
    # response prompt_cache is absent entirely, which is unknown, not cold.
    LEFT=0
    [ -n "$P_pc_warm" ] && [ -n "$P_pc_expires" ] && LEFT=$(( P_pc_expires - NOW ))
    if (( LEFT > 0 )); then
        case $P_pc_ttl in 5m) TTL=300 ;; *) TTL=3600 ;; esac
        SPENT=$(( (TTL - LEFT) * 100 / TTL )); (( SPENT < 0 )) && SPENT=0
        CACHE_TXT+="$(limit_colour "$SPENT")⏱$(fmt_cache_left "$LEFT")${R}"
    elif [ -n "$P_pc" ]; then
        if [ -n "$P_pc_recache" ]; then
            CACHE_TXT+="${C_COLD}❄$(fmt_tokens "$P_pc_recache")${R}"
        else
            CACHE_TXT+="${C_COLD}❄${R}"
        fi
    fi
    # A miss is a receipt, not an alarm: the rebuild it reports is already
    # paid for. The count is permanent and matches /cost; the causes of the
    # last five minutes follow it, in order, and the whole thing is yellow for
    # exactly as long as a cause is still on the line. Adjacent repeats
    # collapse to one word with a multiplier.
    if (( ${P_pc_misses:-0} > 0 )); then
        SEQ=""; PREV=""; REP=0
        flush_word() {
            [ -z "$PREV" ] && return
            SEQ+="${SEQ:+,}${PREV}"
            (( REP > 1 )) && SEQ+="×${REP}"
        }
        for ((i = 0; i < JN; i++)); do
            (( NOW - J_AT[i] > 300 )) && continue
            W=$(cause_words "${J_CAUSES[i]}")
            if [ "$W" = "$PREV" ]; then REP=$((REP + 1))
            else flush_word; PREV=$W; REP=1; fi
        done
        flush_word
        if [ -n "$SEQ" ]; then CACHE_TXT+="${C_ALERT}✗${P_pc_misses}·${SEQ}${R}"
        else                   CACHE_TXT+="${C_GRAY}✗${P_pc_misses}${R}"; fi
    fi
    CACHE_TXT=" ${CACHE_TXT}"
fi

# ------------------------------------------------------------------ briefs ---
# A second row, for one minute, at the four moments something invisible is
# worth saying and you are demonstrably at the keyboard. Everything here is
# either absent from the line (the weekly window below 75%, reset instants as
# clock times, why a miss happened) or too long to live there. The row is not
# printed at all when no brief is live, because an always-present row costs a
# line of terminal for the whole session to carry a blank most of the day.
#
# Composed only on the render that earns it, then kept verbatim in the state
# file until it expires: "back after 47m" must not re-count itself every
# thirty seconds.
brief_limit() {   # $1 label  $2 pct  $3 resets_at
    local p c t
    [ -z "$2" ] && return
    p=$(round "$2"); c=$(limit_colour "$p"); t=$(fmt_clock "$3")
    printf '%s%s %s%s%%%s%s' "$C_GRAY" "$1" "$c" "$p" "$R" "${t:+" ${C_GRAY}→ ${t}${R}"}"
}
# Over 100 the number alone is abstract. What is not: the instant the week runs
# dry, how long before the reset that is, and the daily rate kept so far (the
# pace is that rate over seven days) against the one that would last to the
# reset, the share left over the days left. The gap and the rate kept take the
# pace's colour, the rate that lasts is green, and a brief that does not
# already say when the week resets names it here.
brief_pace() {   # $1 "reset" when the brief does not show the reset instant
    local out exhaust gap kept lasts
    [ -z "$PACE" ] && return
    out="${C_GRAY}pace ${PC_COL}»${PACE}%${R}"
    if (( PACE > 100 )); then
        # From the used share itself rather than the rounded pace: at 100%
        # used that is now, so a week already dry is not announced as running
        # dry in a few minutes, and a pace just over 100 does not move the
        # instant by most of an hour. R7 is above 14 whenever PACE is over 100.
        exhaust=$(( (P_rl7_at - WEEK) + ELAPSED * 100 / R7 ))
        if (( exhaust > NOW )); then
            gap=$(fmt_until $(( NOW + P_rl7_at - exhaust )))
            out+="${C_GRAY}: runs dry $(fmt_clock "$exhaust"), ${PC_COL}${gap}${R}"
            if [ "$1" = reset ]; then out+="${C_GRAY} before $(fmt_clock "$P_rl7_at")${R}"
            else                      out+="${C_GRAY} early${R}"; fi
            # Rounded for the rate kept; floored for the one that lasts, which
            # must not promise a tenth of a percent more than is there.
            kept=$(( (R7 * 86400 + ELAPSED / 2) / ELAPSED ))
            lasts=$(( (100 - R7) * 86400 / (P_rl7_at - NOW) ))
            (( lasts < 0 )) && lasts=0
            # Equal at whole percents, which happens just over 100, the pair
            # would read as "no change needed" beside "runs dry": left out.
            if (( kept > lasts )); then
                out+="${C_GRAY} · ${PC_COL}${kept}${R}${C_GRAY}→${C_LOW}${lasts}${R}${C_GRAY}%/day${R}"
            fi
        fi
    fi
    printf '%s' "$out"
}

# Nothing is composed without a state file to remember it by: an unrecorded
# brief is shown again on the very next render, and again, for the life of the
# session.
BRIEFS=(); SHOWN5=""; SHOWN7=""; XING=""; PACE_SAID=""
if [ -n "$SFILE" ] && { [ -z "$B_TEXT" ] || (( NOW >= B_EXPIRES )); }; then
    # Ordered news first, context second, because only the first two are kept.
    # 1. A cache miss: the detail the one-word cause on line 1 cannot carry.
    if [ -n "$NEW_MISS" ]; then
        MB="${C_ALERT}✗${R}${C_GRAY} cache miss: $(cause_words "$P_pc_causes" | tr '+' ',')${R}"
        # The counts follow the word they qualify: "tools +2/-1", not
        # "tools (+2/-1 tools)". A character delta carries its own sign when
        # negative, so only the positive case needs one added.
        if [ -n "$P_pc_t_add" ] || [ -n "$P_pc_t_del" ]; then
            MB+="${C_GRAY} +${P_pc_t_add:-0}/-${P_pc_t_del:-0}${R}"
        elif [ -n "$P_pc_sys_d" ] && (( P_pc_sys_d != 0 )); then
            if (( P_pc_sys_d > 0 )); then MB+="${C_GRAY} +${P_pc_sys_d} chars${R}"
            else                          MB+="${C_GRAY} ${P_pc_sys_d} chars${R}"; fi
        fi
        DELTA=$(( ${P_pc_recached:-0} - ${S_recached:-0} ))
        (( DELTA > 0 )) && MB+="${C_GRAY} · re-cached $(fmt_tokens "$DELTA")${R}"
        BRIEFS+=("$MB")
    fi
    # 2. A new prompt after a real absence: what changed while you were gone.
    #    The gap cannot exceed the session's own age. Anything larger means
    #    the stored instant did not come from this session, and the brief
    #    would announce something like "back after 20722d", which is NOW
    #    measured from the epoch. That is how the tab-delimiter bug showed
    #    itself; the guard stays because the reading is absurd whatever put
    #    it there, and a status line should not print an absurdity.
    GAP=$(( NOW - ${S_activity:-NOW} ))
    if (( ${P_dur_ms:-0} > 0 && GAP > P_dur_ms / 1000 )); then GAP=0; fi
    if [ -n "$P_prompt_id" ] && [ -n "$S_prompt" ] && [ "$P_prompt_id" != "$S_prompt" ] \
       && (( GAP >= IDLE_RETURN )); then
        RB="${C_GRAY}↩ back after $(fmt_duration $(( GAP * 1000 )))${R}"
        if [ -n "$P_pc" ] && [ -z "$P_pc_warm" ]; then
            RB+="${C_GRAY} · ${C_COLD}❄${R}${C_GRAY} cache went cold${R}"
            [ -n "$P_pc_recache" ] && RB+="${C_GRAY}, re-caches $(fmt_tokens "$P_pc_recache")${R}"
        elif (( ${P_pc_expires:-0} > NOW )); then
            RB+="${C_GRAY} · ${R}⚡${C_GRAY} still warm for $(fmt_cache_left $(( P_pc_expires - NOW )))${R}"
        fi
        # The five-hour window is absent after a long enough absence, and its
        # separator has to go with it, or the brief reads " ·  · ".
        SL=$(brief_limit "session" "$P_rl5" "$P_rl5_at")
        [ -n "$SL" ] && RB+="${C_GRAY} · ${R}${SL}"
        if [ -n "$PACE" ]; then RB+="${C_GRAY} · ${R}$(brief_pace reset)"; PACE_SAID=1; fi
        BRIEFS+=("$RB")
    # 3. The first render that has rate limits: the session's opening facts.
    #    Keyed on having shown it, not on the state file existing: Claude Code
    #    renders once at session start, before the first API response, and
    #    that render has no rate_limits but does write state. Testing the file
    #    meant the opening brief was already "seen" by the time the limits it
    #    reports arrived, so it never appeared at all.
    elif [ -z "$S_opened" ] && [ -n "$P_rl5" ]; then
        OPENED=1
        SB="${C_GRAY}⧗${R} $(brief_limit "session" "$P_rl5" "$P_rl5_at")"
        # The weekly window is independently absent: a Pro session, or one
        # whose weekly reset has just passed. Its separator has to go with it,
        # or the brief reads " ·  · ".
        if [ -n "$P_rl7" ]; then
            SB+="${C_GRAY} · ${R}$(brief_limit "weekly" "$P_rl7" "$P_rl7_at")"
            if [ -n "$PACE" ]; then SB+="${C_GRAY}, ${R}$(brief_pace)"; PACE_SAID=1; fi
        fi
        # Absent on a provider that reports no cache tokens, where "TTL ?"
        # would be the only thing the opening brief had to say about caching.
        [ -n "$P_pc_ttl" ] && SB+="${C_GRAY} · cache TTL ${P_pc_ttl}${R}"
        BRIEFS+=("$SB")
    fi
    # 4. A window crossing a band, upward only. A window seen for the first
    #    time was seeded at its current band above, so it cannot read as a
    #    crossing here. The weekly one carries the pace, since a weekly
    #    percentage without it is not yet a question. Each clause drops the
    #    separator with the clause it introduces, or the brief trails " · ".
    XING_AT=${#BRIEFS[@]}
    if (( CUR7 > S_band7 )); then
        XB="${C_GRAY}W${R} $(brief_limit "weekly limit" "$P_rl7" "$P_rl7_at")"
        # Said once per render: a crossing beside a brief that already gave
        # the pace would repeat its whole clause.
        [ -n "$PACE" ] && [ -z "$PACE_SAID" ] && XB+="${C_GRAY} · ${R}$(brief_pace)"
        BRIEFS+=("$XB"); XING=7
    elif (( CUR5 > S_band5 )); then
        XB="${C_GRAY}⧗${R} $(brief_limit "session limit" "$P_rl5" "$P_rl5_at")"
        [ -n "$P_rl7" ] && XB+="${C_GRAY} · ${R}$(brief_limit "weekly" "$P_rl7" "$P_rl7_at")"
        BRIEFS+=("$XB"); XING=5
    fi
    # Two at once is a busy moment, not a report; a third would wrap.
    if (( ${#BRIEFS[@]} > 0 )); then
        B_TEXT="${BRIEFS[0]}"
        (( ${#BRIEFS[@]} > 1 )) && B_TEXT+="${C_GRAY}  ·  ${R}${BRIEFS[1]}"
        B_EXPIRES=$(( NOW + BRIEF_TTL ))
        STATE_DIRTY=1
        # A band counts as announced only if its brief survived that cap. The
        # stored band is what the next render compares against, so advancing
        # it for a crossing that was never printed loses it for good.
        if (( XING_AT < 2 )); then
            [ "$XING" = 5 ] && SHOWN5=1
            [ "$XING" = 7 ] && SHOWN7=1
        fi
    else
        B_TEXT=""
    fi
fi

# What the next render compares against: the band last ANNOUNCED, not the band
# the window is in. Advancing it on a render that printed nothing, which is
# every render while an earlier brief still holds the row, swallows the
# crossing permanently.
NEW5=$S_band5; [ -n "$SHOWN5" ] && NEW5=$CUR5
NEW7=$S_band7; [ -n "$SHOWN7" ] && NEW7=$CUR7
[ -n "$S_opened" ] || S_opened=${OPENED:-}

# ------------------------------------------------------------------ output ---
# Grouped by what the numbers describe rather than by field: working tree
# (branch, PR, lines changed), elapsed time, spend, then context and cache.
printf '[%s%s%s%s|%s]%s %s%s %s | %s %s | %s%s%s | %s%s ↗%s\n' \
    "$USER_TXT" "$C_MODEL" "$MODEL_TXT" "${R}${EFFORT_TXT}" "$PLAN_TXT" \
    "$MODES_TXT" "$GIT_TXT" "$PR_TXT" "$LINES_TXT" \
    "$DUR_TXT" "$API_TXT" \
    "$COST_TXT" "$PACE_TXT" "$LIMIT_TXT" \
    "$CTX_TXT" "$CACHE_TXT" "$(fmt_tokens "${P_out_tok:-0}")"

# %s, never the text itself: a brief is full of percent signs, and printf would
# read them as conversions and eat the line.
if [ -n "$B_TEXT" ] && (( NOW < B_EXPIRES )); then
    printf '%s\n' "$B_TEXT"
fi

# ------------------------------------------------------------- state, once ---
# One write, and only when a miss, a crossing or a brief changed something. The
# newest miss is kept past its display window: it is what the next render
# compares against to notice a new one.
if [ -n "$SFILE" ]; then
    [ "$ACTIVITY" = "$S_activity" ] && [ "$P_prompt_id" = "$S_prompt" ] \
        && [ "$P_out_tok" = "$S_out" ] && [ "$P_model_id" = "$S_model" ] \
        && [ "$P_effort" = "$S_effort" ] || STATE_DIRTY=1
fi
if [ -n "$STATE_DIRTY" ] && [ -n "$SFILE" ]; then
    [ -d "$SDIR" ] || mkdir -p -m 700 "$SDIR" 2>/dev/null
    # Written to a temporary file and renamed, never in place. Claude Code
    # kills a status line still running when the next update arrives, and a
    # truncating redirect killed halfway leaves a half-written state for the
    # next render to read. rename(2) is atomic, so a reader sees the old file
    # or the new one and never a torn one.
    {
        for ((i = 0; i < JN; i++)); do
            if (( NOW - J_AT[i] <= 300 || i == JN - 1 )); then
                printf 'm%s%s%s%s%s%s\n' "$US" "${J_AT[i]}" "$US" "${J_COUNT[i]}" "$US" "${J_CAUSES[i]}"
            fi
        done
        printf 's%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
            "$US" "$P_prompt_id" "$US" "$ACTIVITY" "$US" "$P_out_tok" \
            "$US" "$NEW5" "$US" "$P_rl5_at" "$US" "$NEW7" "$US" "$P_rl7_at" \
            "$US" "${P_pc_recached:-0}" "$US" "$S_opened" \
            "$US" "$P_model_id" "$US" "$P_effort"
        if [ -n "$B_TEXT" ] && (( NOW < B_EXPIRES )); then
            printf 'b%s%s%s%s\n' "$US" "$B_EXPIRES" "$US" "$B_TEXT"
        fi
    } > "$SFILE.$$" 2>/dev/null && mv -f "$SFILE.$$" "$SFILE" 2>/dev/null
    rm -f "$SFILE.$$" 2>/dev/null
fi

# A status line must exit 0. Claude Code discards the output of a command that
# fails, so the whole bar blanks until the next render. Every `[ -n "$x" ] &&
# cmd` above is a false status waiting to become the script's own when it lands
# last, which is exactly what v6 did: the state file's optional brief line was
# the final command, and it is absent on most renders. The lines are `if`
# statements now, and this is the belt to that pair of braces.
exit 0
