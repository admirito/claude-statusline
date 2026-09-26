#!/bin/bash
# Claude Code status line, v6.
#
# What changed from v5, and why:
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
#                   "refreshInterval": 30 }
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

BRANCH_MAX=16   # columns, ellipsis included

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
  ] | .[] | @tsv' 2>/dev/null)

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

NOW=${EPOCHSECONDS:-$(date +%s)}

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
CFG+=(/etc/claude-code/managed-settings.json)
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

# Shape is effort, colour is fast mode. Absent means the model has no effort
# knob at all, which is not the same as unknown.
case $P_effort in
    low)    GLYPH='⡀' ;;
    medium) GLYPH='⡄' ;;
    high)   GLYPH='⡆' ;;
    xhigh)  GLYPH='⡇' ;;
    max)    GLYPH='⣿' ;;
    *)      GLYPH='∅' ;;
esac
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
US=$'\037'
J_AT=(); J_COUNT=(); J_CAUSES=(); SFILE=""; STATE_DIRTY=""
S_prompt=""; S_activity=""; S_out=""; S_band5=0; S_at5=""; S_band7=0; S_at7=""
S_recached=""; S_opened=""; B_EXPIRES=0; B_TEXT=""
case $P_session_id in
    # "." and ".." pass a character test and name a directory, which `read`
    # then fails on, once per render.
    ''|.|..|*[!A-Za-z0-9._-]*) ;;
    *) SDIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/claude-statusline-${UID:-$(id -u)}"
       SFILE="$SDIR/$P_session_id" ;;
esac
# A state file that cannot be kept is worse than no briefs at all: nothing
# would record that a brief had been shown, so the opening one would print on
# every render for the life of the session. Establish now whether the file is
# usable, and if it is not, say so by clearing SFILE, which also suppresses
# every brief below.
if [ -n "$SFILE" ]; then
    [ -d "$SDIR" ] || mkdir -p -m 700 "$SDIR" 2>/dev/null
    if [ ! -d "$SDIR" ] || [ ! -w "$SDIR" ] || [ -d "$SFILE" ]; then SFILE=""; fi
fi
if [ -n "$SFILE" ] && [ -r "$SFILE" ]; then
    while IFS=$US read -r kind a b c d e f g h i; do
        case $kind in
            m) case $a in ''|*[!0-9]*) continue ;; esac
               J_AT+=("$a"); case $b in ''|*[!0-9]*) b=0 ;; esac
               J_COUNT+=("$b"); J_CAUSES+=("$c") ;;
            s) S_prompt=$a; S_activity=$b; S_out=$c; S_band5=${d:-0}; S_at5=$e
               S_band7=${f:-0}; S_at7=$g; S_recached=$h; S_opened=$i ;;
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
brief_pace() {
    local out exhaust
    [ -z "$PACE" ] && return
    out="${C_GRAY}pace ${PC_COL}»${PACE}%${R}"
    # Over 100 the number alone is abstract; the instant it runs dry is not.
    if (( PACE > 100 )); then
        exhaust=$(( (P_rl7_at - WEEK) + (WEEK * 100) / PACE ))
        (( exhaust > NOW )) && out+="${C_GRAY}: runs dry $(fmt_clock "$exhaust")${R}"
    fi
    printf '%s' "$out"
}

# Nothing is composed without a state file to remember it by: an unrecorded
# brief is shown again on the very next render, and again, for the life of the
# session.
BRIEFS=(); SHOWN5=""; SHOWN7=""; XING=""
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
        RB+="${C_GRAY} · ${R}$(brief_limit "session" "$P_rl5" "$P_rl5_at")"
        [ -n "$PACE" ] && RB+="${C_GRAY} · ${R}$(brief_pace)"
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
            [ -n "$PACE" ] && SB+="${C_GRAY}, ${R}$(brief_pace)"
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
        [ -n "$PACE" ] && XB+="${C_GRAY} · ${R}$(brief_pace)"
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
        && [ "$P_out_tok" = "$S_out" ] || STATE_DIRTY=1
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
        printf 's%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
            "$US" "$P_prompt_id" "$US" "$ACTIVITY" "$US" "$P_out_tok" \
            "$US" "$NEW5" "$US" "$P_rl5_at" "$US" "$NEW7" "$US" "$P_rl7_at" \
            "$US" "${P_pc_recached:-0}" "$US" "$S_opened"
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
