#!/bin/bash

input=$(cat)

# Extract core values
MODEL=$(echo "$input" | jq -r '.model.display_name')

# Effort level from settings (braille dots: ⠁=low ⠃=medium ⠇=high ⣿=max)
EFFORT=$(jq -r '.effortLevel // "high"' ~/.claude/settings.json 2>/dev/null)
case "$EFFORT" in
    "low")    EFFORT_ICON="⠁" ;;
    "medium") EFFORT_ICON="⠃" ;;
    "high")   EFFORT_ICON="⠇" ;;
    "max")    EFFORT_ICON="⣿" ;;
    *)        EFFORT_ICON="∅" ;;
esac

# Check subscription type and username from credentials
# Primary: subscriptionType from credentials file (pro/max/team/enterprise)
# Fallback: billingType from claude.json (stripe_subscription/apple_subscription/etc.)
SUB_TYPE=$(jq -r '.claudeAiOauth.subscriptionType // empty' ~/.claude/.credentials.json 2>/dev/null)
BILLING_METHOD=$(jq -r '.oauthAccount.billingType // empty' ~/.claude.json 2>/dev/null)
ORG_NAME=$(jq -r '.oauthAccount.organizationName // empty' ~/.claude.json 2>/dev/null)
EMAIL=$(jq -r '.oauthAccount.emailAddress // ""' ~/.claude.json 2>/dev/null)
USERNAME=$(echo "$EMAIL" | cut -d'@' -f1)

# Determine display label: prefer subscriptionType, then infer from billingType
if [ -n "$SUB_TYPE" ]; then
    PLAN="$SUB_TYPE"
else
    case "$BILLING_METHOD" in
        stripe_subscription|stripe_subscription_contracted|apple_subscription|google_play_subscription)
            if [ -n "$ORG_NAME" ]; then
                PLAN="team"
            else
                PLAN="pro"
            fi
            ;;
        workspace_billing)
            PLAN="enterprise"
            ;;
        *)
            PLAN="api"
            ;;
    esac
fi

case "$PLAN" in
    "pro")
        BILLING_TYPE="\033[38;5;114mPro\033[0m"         # Pastel Green
        ;;
    "max")
        BILLING_TYPE="\033[38;5;114mMax\033[0m"         # Pastel Green
        ;;
    "team")
        BILLING_TYPE="\033[38;5;114mTeam\033[0m"        # Pastel Green
        ;;
    "enterprise")
        BILLING_TYPE="\033[38;5;141mEnterprise\033[0m"  # Light Purple
        ;;
    "free")
        BILLING_TYPE="\033[90mFree\033[0m"              # Gray
        ;;
    *)
        BILLING_TYPE="\033[38;5;223mAPI\033[0m"         # Peach
        ;;
esac
CONTEXT_SIZE=$(echo "$input" | jq -r '.context_window.context_window_size')
TOTAL_INPUT=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
TOTAL_OUTPUT=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
USAGE=$(echo "$input" | jq '.context_window.current_usage')

# Cost data
OFFICIAL_COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
SESSION_DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
API_DURATION_MS=$(echo "$input" | jq -r '.cost.total_api_duration_ms // 0')
LINES_ADDED=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
LINES_REMOVED=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')

# Git branch - always show
GIT_BRANCH=$(git branch --show-current 2>/dev/null)
if [ -n "$GIT_BRANCH" ]; then
    # Check if there are uncommitted changes
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        GIT_INFO="\033[33m${GIT_BRANCH}*\033[0m"  # Yellow with asterisk for dirty
    else
        GIT_INFO="\033[38;5;65m${GIT_BRANCH}\033[0m"   # Olive green for clean
    fi
else
    GIT_INFO="\033[90mno-git\033[0m"  # Gray for no git
fi

# Format session duration
if [ $SESSION_DURATION_MS -gt 0 ]; then
    SESSION_SEC=$((SESSION_DURATION_MS / 1000))
    SESSION_MIN=$((SESSION_SEC / 60))
    SESSION_SEC_REMAINDER=$((SESSION_SEC % 60))
    if [ $SESSION_MIN -gt 0 ]; then
        DURATION="\033[38;5;194m⌚\033[0m${SESSION_MIN}m${SESSION_SEC_REMAINDER}s"
    else
        DURATION="\033[38;5;194m⌚\033[0m${SESSION_SEC}s"
    fi
else
    DURATION="\033[38;5;194m⌚\033[0m\033[90m0s\033[0m"
fi

# Format API duration
if [ $API_DURATION_MS -gt 0 ]; then
    API_SEC=$((API_DURATION_MS / 1000))
    API_MIN=$((API_SEC / 60))
    API_SEC_REMAINDER=$((API_SEC % 60))
    if [ $API_MIN -gt 0 ]; then
        API_INFO="\033[38;5;194mⒶ\033[0m${API_MIN}m${API_SEC_REMAINDER}s"
    else
        API_INFO="\033[38;5;194mⒶ\033[0m${API_SEC}s"
    fi
else
    API_INFO="\033[38;5;194mⒶ\033[0m\033[90m0s\033[0m"
fi

# Format lines changed
if [ $LINES_ADDED -gt 0 ] || [ $LINES_REMOVED -gt 0 ]; then
    LINES_INFO="\033[38;5;78m+${LINES_ADDED}\033[0m/\033[38;5;203m-${LINES_REMOVED}\033[0m"
else
    LINES_INFO="\033[90m+0/-0\033[0m"
fi

# Format cost
if [ "$OFFICIAL_COST" != "0" ] && [ "$OFFICIAL_COST" != "null" ]; then
    COST_FORMATTED=$(printf "%.2f" "$OFFICIAL_COST")
    COST_INFO="\033[38;5;218m\$${COST_FORMATTED}\033[0m"
else
    COST_INFO="\$\033[90m0.00\033[0m"
fi

# Parse usage data or use defaults
if [ "$USAGE" != "null" ]; then
    CURRENT_INPUT=$(echo "$USAGE" | jq '.input_tokens // 0')
    CACHE_CREATE=$(echo "$USAGE" | jq '.cache_creation_input_tokens // 0')
    CACHE_READ=$(echo "$USAGE" | jq '.cache_read_input_tokens // 0')
    CURRENT_TOKENS=$((CURRENT_INPUT + CACHE_CREATE + CACHE_READ))
else
    CURRENT_TOKENS=0
    CACHE_CREATE=0
    CACHE_READ=0
fi

# Calculate percentages
PERCENT_ACTUAL=$((CURRENT_TOKENS * 100 / CONTEXT_SIZE))

# Adjust percentage to show 100% at auto-compact trigger point
# Claude Code docs say "95% capacity" but that's relative to USABLE space (excluding overhead)
# Overhead includes: system prompts, tool definitions, CLAUDE.md, MCP schemas, reserved output space
# Empirical observation: auto-compact triggers at ~77% actual usage
# Calculation: 200K window - 23% overhead = 154K usable, 95% of 154K = 146K = 73% of 200K
# Using 75% as middle ground estimate between observed (77%) and calculated (73%)
PERCENT_DISPLAYED=$((PERCENT_ACTUAL * 100 / 75))
if [ $PERCENT_DISPLAYED -gt 100 ]; then
    PERCENT_DISPLAYED=100
fi

# Cache efficiency - always show
TOTAL_CACHEABLE=$((CACHE_CREATE + CACHE_READ))
if [ $TOTAL_CACHEABLE -gt 0 ]; then
    CACHE_HIT_RATIO=$((CACHE_READ * 100 / TOTAL_CACHEABLE))
    CACHE_INFO="Cache:${CACHE_HIT_RATIO}%"
else
    CACHE_INFO="Cache:\033[90mN/A\033[0m"  # Gray for N/A
fi

# Create progress bar with embedded percentage (15 chars total)
PERCENT_TEXT="${PERCENT_DISPLAYED}%"
PERCENT_LEN=${#PERCENT_TEXT}
BAR_WIDTH=15

# Color the percentage based on DISPLAYED usage level (soft colors with bright red)
if [ $PERCENT_DISPLAYED -ge 90 ]; then
    PERCENT_COLORED="\033[38;5;196m${PERCENT_TEXT}\033[0m"  # Bright Red (90%+)
elif [ $PERCENT_DISPLAYED -ge 75 ]; then
    PERCENT_COLORED="\033[38;5;214m${PERCENT_TEXT}\033[0m"  # Soft Orange (75-90%)
elif [ $PERCENT_DISPLAYED -ge 50 ]; then
    PERCENT_COLORED="\033[38;5;228m${PERCENT_TEXT}\033[0m"  # Light Yellow (50-75%)
else
    PERCENT_COLORED="\033[38;5;78m${PERCENT_TEXT}\033[0m"   # Soft Green (0-50%)
fi

# Calculate filled and empty portions (based on ACTUAL usage, not displayed)
FILLED=$((PERCENT_ACTUAL * BAR_WIDTH / 100))
REMAINING=$((BAR_WIDTH - FILLED))

# Build progress bar with percentage at the end
if [ $REMAINING -ge $PERCENT_LEN ]; then
    # Percentage fits in empty space
    EMPTY_BEFORE_PCT=$((REMAINING - PERCENT_LEN))
    PROGRESS_BAR=$(printf '%*s' $FILLED | tr ' ' '#')$(printf '%*s' $EMPTY_BEFORE_PCT | tr ' ' '-')${PERCENT_COLORED}
else
    # Percentage overlaps with filled area
    VISIBLE_FILLED=$((BAR_WIDTH - PERCENT_LEN))
    PROGRESS_BAR=$(printf '%*s' $VISIBLE_FILLED | tr ' ' '#')${PERCENT_COLORED}
fi

# Format tokens with K suffix for readability
CURRENT_K=$((CURRENT_TOKENS / 1000))
CONTEXT_K=$((CONTEXT_SIZE / 1000))
OUTPUT_K=$((TOTAL_OUTPUT / 1000))

# Format cache percentage with icon
if [ "$CACHE_INFO" != "Cache:\033[90mN/A\033[0m" ]; then
    CACHE_HIT_NUM=$(echo "$CACHE_INFO" | sed 's/Cache://')
    CACHE_COMPACT="⚡${CACHE_HIT_NUM}"
else
    CACHE_COMPACT="⚡\033[90mN/A\033[0m"
fi

# Always show all fields
if [ -n "$USERNAME" ]; then
    USER_INFO="\033[90m${USERNAME}\033[0m|"
else
    USER_INFO=""
fi
echo -e "[${USER_INFO}\033[38;5;117m${MODEL}\033[0m${EFFORT_ICON}|${BILLING_TYPE}] ${GIT_INFO} | ${DURATION} | ${API_INFO} | ${LINES_INFO} | ${COST_INFO} | ${CURRENT_K}K/${CONTEXT_K}K [${PROGRESS_BAR}] ${CACHE_COMPACT} ↗${OUTPUT_K}K"
