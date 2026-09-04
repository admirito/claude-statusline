#!/bin/bash
# Claude Code status line, v4.
#
# What changed from v3, and why:
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
# the line), version, session_name, session_id, prompt_id, workspace.repo.
#
# Pairs with settings.json:
#   "statusLine": { "type": "command", "command": "…/statusline.sh",
#                   "refreshInterval": 30 }
# The interval exists for the cache countdown and the limit countdowns. Claude
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
C_WARM=$'\033[38;5;253m'      # 50-75 band, and pending review
C_LOW=$'\033[38;5;78m'
C_MID=$'\033[38;5;228m'
C_HIGH=$'\033[38;5;214m'
C_CRIT=$'\033[38;5;196m'

BRANCH_MAX=16   # columns, ellipsis included

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
  def i: if . == null then "" else (floor | tostring) end;
  [ ["model_name",  (.model.display_name // "")]
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

fmt_duration() {
    local sec=$(( ${1:-0} / 1000 )) min
    min=$((sec / 60))
    if (( min > 0 )); then printf '%dm%ds' "$min" $((sec % 60))
    else printf '%ds' "$sec"; fi
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
    *)          PLAN_TXT="${C_PLAN}${PLAN^}${R}" ;;
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
        *)           I=${P_style:0:1}; MODES+="${I^}" ;;  # custom: any name
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
if (( $(round "${P_rl5:-0}") >= 50 )); then G=fine; else G=coarse; fi
add_limit ""  "$P_rl5" "$P_rl5_at" "$G"
add_limit "W" "$P_rl7" "$P_rl7_at" coarse
# Read if it ever appears. This window is not part of the status line payload
# today, and the slot is absent-safe, so being ready for it costs nothing.
add_limit "F" "$P_rlf" "$P_rlf_at" coarse
# Emitted only behind a Claude apps gateway, and can exceed 100.
add_limit "S" "$P_rls" "$P_rls_at" coarse

LIMIT_TXT=""
(( ${#LIMIT_PARTS[@]} > 0 )) && LIMIT_TXT=" ${C_GRAY}⧗${R}${LIMIT_PARTS[*]}"

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
    if [ -n "$P_pc_warm" ] && [ -n "$P_pc_expires" ]; then
        LEFT=$(( P_pc_expires - NOW ))
        # 15 minutes: long enough to decide whether to send now or accept the
        # rebuild, short enough that it is silent nearly all the time.
        if (( LEFT > 0 && LEFT <= 900 )); then
            CACHE_TXT+="${C_MID}⏱$(( (LEFT + 59) / 60 ))m${R}"
        fi
    fi
    # Only a cache that exists can be cold. Before the first API response
    # prompt_cache is absent entirely, which is unknown, not cold.
    if [ -n "$P_pc" ] && [ -z "$P_pc_warm" ]; then
        if [ -n "$P_pc_recache" ]; then
            CACHE_TXT+="${C_COLD}❄$(fmt_tokens "$P_pc_recache")${R}"
        else
            CACHE_TXT+="${C_COLD}❄${R}"
        fi
    fi
    (( ${P_pc_misses:-0} > 0 )) && CACHE_TXT+="${C_CRIT}✗${P_pc_misses}${R}"
    CACHE_TXT=" ${CACHE_TXT}"
fi

# ------------------------------------------------------------------ output ---
printf '[%s%s%s%s|%s]%s %s%s | %s | %s | %s | %s%s | %s%s ↗%s\n' \
    "$USER_TXT" "$C_MODEL" "$MODEL_TXT" "${R}${EFFORT_TXT}" "$PLAN_TXT" \
    "$MODES_TXT" "$GIT_TXT" "$PR_TXT" \
    "$DUR_TXT" "$API_TXT" "$LINES_TXT" \
    "$COST_TXT" "$LIMIT_TXT" \
    "$CTX_TXT" "$CACHE_TXT" "$(fmt_tokens "${P_out_tok:-0}")"
