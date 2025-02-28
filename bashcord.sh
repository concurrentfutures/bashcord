#!/bin/bash

# 2025 | Monokuma
# bashcord.sh - Advanced Discord API Wrapper Module with Gateway
# Requires: curl, jq, websocat
# Config: Reads from config.json

DISCORD_API="https://discord.com/api/v10"
CONFIG_FILE="config.json"
LOG_FILE="bashcord.log"
RATE_LIMIT_REMAINING=""
RATE_LIMIT_RESET=""
DEBUG_MODE=0
declare -A BASHCORD_COMMANDS
RUNNING=1

# ANSI Colors
YELLOW='\033[1;33m'
RED='\033[1;31m'
WHITE='\033[0m'
NC='\033[0m'

# Check dependencies
command -v curl >/dev/null 2>&1 || { echo "Error: curl is required."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required."; exit 1; }
command -v websocat >/dev/null 2>&1 || { echo "Error: websocat is required."; exit 1; }

# Logging function
bashcord_log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${YELLOW}[ LOGGING ] 〔 $timestamp 〕${NC} | ${WHITE}$message${NC}" | tee -a "$LOG_FILE"
}

# Error handling function
bashcord_error() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${RED}[ ERROR ] 〔 $timestamp 〕${NC} | ${WHITE}$message${NC}" | tee -a "$LOG_FILE" >&2
    return 1
}

# Load configuration
bashcord_load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then bashcord_error "$CONFIG_FILE not found."; exit 1; fi
    BOT_TOKEN=$(jq -r '.bot_token' "$CONFIG_FILE")
    DEFAULT_GUILD_ID=$(jq -r '.default_guild_id // empty' "$CONFIG_FILE")
    DEFAULT_CHANNEL_ID=$(jq -r '.default_channel_id // empty' "$CONFIG_FILE")
    PREFIX=$(jq -r '.prefix' "$CONFIG_FILE")
    if [[ -z "$BOT_TOKEN" || "$BOT_TOKEN" == "null" ]]; then bashcord_error "Bot token not set."; exit 1; fi
    if [[ -z "$PREFIX" || "$PREFIX" == "null" ]]; then bashcord_error "Prefix not set."; exit 1; fi
    bashcord_log "Config loaded: Token=$(echo "$BOT_TOKEN" | cut -c1-5)..., Guild=$DEFAULT_GUILD_ID, Channel=$DEFAULT_CHANNEL_ID, Prefix=$PREFIX"
}

# Generic API request function
bashcord_api_request() {
    local method="$1" endpoint="$2" data="$3"
    local headers=(-H "Authorization: Bot $BOT_TOKEN" -H "Content-Type: application/json")
    local response_file=$(mktemp) curl_output=$(mktemp)

    if [[ -n "$RATE_LIMIT_REMAINING" && "$RATE_LIMIT_REMAINING" -le 0 ]]; then
        local wait_time=$((RATE_LIMIT_RESET - $(date +%s)))
        if [[ "$wait_time" -gt 0 ]]; then
            bashcord_log "Rate limit hit. Waiting $wait_time seconds..."
            sleep "$wait_time"
        fi
    fi

    bashcord_log "Sending $method request to $endpoint"
    if [[ "$method" == "GET" ]]; then
        curl -s -X "$method" "${headers[@]}" "$DISCORD_API$endpoint" -o "$response_file" -D "$curl_output" || bashcord_error "curl failed for $method $endpoint"
    else
        curl -s -X "$method" "${headers[@]}" -d "$data" "$DISCORD_API$endpoint" -o "$response_file" -D "$curl_output" || bashcord_error "curl failed for $method $endpoint"
    fi

    RATE_LIMIT_REMAINING=$(grep -i "x-ratelimit-remaining" "$curl_output" | awk '{print $2}' | tr -d '\r')
    RATE_LIMIT_RESET=$(grep -i "x-ratelimit-reset" "$curl_output" | awk '{print $2}' | tr -d '\r')
    [[ "$DEBUG_MODE" -eq 1 ]] && bashcord_log "Rate Limits: Remaining=$RATE_LIMIT_REMAINING, Reset=$RATE_LIMIT_RESET"

    local status=$(head -n1 "$curl_output" | awk '{print $2}')
    if [[ "$status" -ge 400 ]]; then
        bashcord_error "HTTP Error $status: $(jq -r '.message // "Unknown error"' "$response_file")"
        rm "$response_file" "$curl_output"
        return 1
    fi

    cat "$response_file"
    rm "$response_file" "$curl_output"
}

# Command registration
bashcord_command() {
    local command_name="$1" command_body="$2"
    BASHCORD_COMMANDS["$command_name"]="$command_body"
    eval "bashcord_cmd_$command_name() { $command_body; }"
    bashcord_log "Registered command: $command_name"
}

# Decorator helper
bashcord_command_decorator() {
    local command_name="$1" command_body="$2"
    bashcord_command "$command_name" "$command_body"
}

# Helper functions
bashcord_guild_id() { echo "$DEFAULT_GUILD_ID"; }
bashcord_channel_id() { echo "$DEFAULT_CHANNEL_ID"; }
bashcord_toggle_debug() { DEBUG_MODE=$((1 - DEBUG_MODE)); bashcord_log "Debug mode: $((DEBUG_MODE ? "ON" : "OFF"))"; }
bashcord_wrapper_close() { bashcord_log "Shutting down wrapper..."; RUNNING=0; }

# Gateway functions
bashcord_get_gateway_url() {
    bashcord_api_request "GET" "/gateway/bot" | jq -r '.url'
}

bashcord_send_identify() {
    local token="$BOT_TOKEN"
    local payload=$(jq -n --arg t "$token" '{
        "op": 2,
        "d": {
            "token": $t,
            "intents": 513,  # GUILDS and GUILD_MESSAGES
            "properties": {
                "os": "linux",
                "browser": "bashcord",
                "device": "bashcord"
            }
        }
    }')
    echo "$payload"
}

bashcord_send_heartbeat() {
    local sequence="$1"
    local payload=$(jq -n --arg s "$sequence" '{"op": 1, "d": ($s | tonumber)}')
    echo "$payload"
}

# Process Gateway events
bashcord_process_event() {
    local event="$1"
    local op=$(echo "$event" | jq -r '.op')
    local data=$(echo "$event" | jq -r '.d')
    local sequence=$(echo "$event" | jq -r '.s')
    local type=$(echo "$event" | jq -r '.t')

    case "$op" in
        0)  # Dispatch
            case "$type" in
                "MESSAGE_CREATE")
                    local content=$(echo "$data" | jq -r '.content')
                    local channel_id=$(echo "$data" | jq -r '.channel_id')
                    local author_id=$(echo "$data" | jq -r '.author.id')
                    local bot_id=$(bashcord_get_current_user | jq -r '.id')

                    # Check if message is in DMs and shutdown command
                    local guild_id=$(echo "$data" | jq -r '.guild_id // empty')
                    if [[ -z "$guild_id" && "$content" == "bashcord.wrapper_close()" && "$author_id" != "$bot_id" ]]; then
                        bashcord_wrapper_close
                        return
                    fi

                    # Process commands
                    if [[ "$content" =~ ^"$PREFIX"(.+) ]]; then
                        local command="${BASH_REMATCH[1]}"
                        local command_name=$(echo "$command" | awk '{print $1}')
                        local args=$(echo "$command" | cut -d' ' -f2-)
                        if [[ -n "${BASHCORD_COMMANDS[$command_name]}" ]]; then
                            bashcord_log "Executing command: $command_name with args: $args"
                            "bashcord_cmd_$command_name" $args "$channel_id"
                        else
                            bashcord_send_message "$channel_id" "Unknown command: $command_name"
                        fi
                    fi
                    ;;
                *) bashcord_log "Unhandled event type: $type";;
            esac
            HEARTBEAT_SEQUENCE="$sequence"
            ;;
        10)  # Hello
            HEARTBEAT_INTERVAL=$(echo "$data" | jq -r '.heartbeat_interval')
            bashcord_log "Received Hello, heartbeat interval: $HEARTBEAT_INTERVAL ms"
            ;;
        11) bashcord_log "Heartbeat ACK received";;
        *) bashcord_log "Unhandled opcode: $op";;
    esac
}

# Main Gateway loop
bashcord_run() {
    bashcord_load_config
    local gateway_url=$(bashcord_get_gateway_url)
    bashcord_log "Connecting to Gateway: $gateway_url"

    # Start WebSocket connection
    websocat -t "$gateway_url" --text <<EOF &
$(bashcord_send_identify)
EOF
    local ws_pid=$!

    # Heartbeat loop
    HEARTBEAT_SEQUENCE=""
    while [[ "$RUNNING" -eq 1 ]]; do
        if [[ -n "$HEARTBEAT_INTERVAL" ]]; then
            bashcord_log "Sending heartbeat with sequence: $HEARTBEAT_SEQUENCE"
            echo "$(bashcord_send_heartbeat "$HEARTBEAT_SEQUENCE")" | websocat -t "$gateway_url" --text >/dev/null 2>&1
            sleep $(($HEARTBEAT_INTERVAL / 1000))
        else
            sleep 1
        fi
    done

    # Cleanup
    kill "$ws_pid" 2>/dev/null
    bashcord_log "Wrapper closed."
}

bashcord_send_message() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}" content="$2" embed_title="$3" embed_desc="$4"; [[ -z "$channel_id" ]] && { bashcord_error "No channel ID."; return 1; }; local data; if [[ -n "$embed_title" && -n "$embed_desc" ]]; then data=$(jq -n --arg c "$content" --arg t "$embed_title" --arg d "$embed_desc" '{"content": $c, "embeds": [{"title": $t, "description": $d}]}'); else data=$(jq -n --arg c "$content" '{"content": $c}'); fi; bashcord_api_request "POST" "/channels/$channel_id/messages" "$data"; }
bashcord_edit_message() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}" message_id="$2" new_content="$3"; [[ -z "$channel_id" || -z "$message_id" ]] && { bashcord_error "Channel/Message ID required."; return 1; }; local data=$(jq -n --arg c "$new_content" '{"content": $c}'); bashcord_api_request "PATCH" "/channels/$channel_id/messages/$message_id" "$data"; }
bashcord_delete_message() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}" message_id="$2"; [[ -z "$channel_id" || -z "$message_id" ]] && { bashcord_error "Channel/Message ID required."; return 1; }; bashcord_api_request "DELETE" "/channels/$channel_id/messages/$message_id" ""; }
bashcord_get_channel() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}"; [[ -z "$channel_id" ]] && { bashcord_error "No channel ID."; return 1; }; bashcord_api_request "GET" "/channels/$channel_id"; }
bashcord_create_channel() { local guild_id="${1:-$DEFAULT_GUILD_ID}" name="$2" type="${3:-0}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; local data=$(jq -n --arg n "$name" --arg t "$type" '{"name": $n, "type": $t|tonumber}'); bashcord_api_request "POST" "/guilds/$guild_id/channels" "$data"; }
bashcord_get_user() { local user_id="$1"; [[ -z "$user_id" ]] && { bashcord_error "User ID required."; return 1; }; bashcord_api_request "GET" "/users/$user_id"; }
bashcord_modify_member() { local guild_id="${1:-$DEFAULT_GUILD_ID}" user_id="$2" nick="$3"; [[ -z "$guild_id" || -z "$user_id" ]] && { bashcord_error "Guild/User ID required."; return 1; }; local data=$(jq -n --arg n "$nick" '{"nick": $n}'); bashcord_api_request "PATCH" "/guilds/$guild_id/members/$user_id" "$data"; }
bashcord_create_webhook() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}" name="$2"; [[ -z "$channel_id" ]] && { bashcord_error "No channel ID."; return 1; }; local data=$(jq -n --arg n "$name" '{"name": $n}'); bashcord_api_request "POST" "/channels/$channel_id/webhooks" "$data"; }
bashcord_execute_webhook() { local webhook_id="$1" webhook_token="$2" content="$3"; [[ -z "$webhook_id" || -z "$webhook_token" ]] && { bashcord_error "Webhook ID/Token required."; return 1; }; local data=$(jq -n --arg c "$content" '{"content": $c}'); curl -s -X POST -H "Content-Type: application/json" -d "$data" "$DISCORD_API/webhooks/$webhook_id/$webhook_token"; }
bashcord_get_guild() { local guild_id="${1:-$DEFAULT_GUILD_ID}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id"; }
bashcord_modify_guild() { local guild_id="${1:-$DEFAULT_GUILD_ID}" name="$2"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; local data=$(jq -n --arg n "$name" '{"name": $n}'); bashcord_api_request "PATCH" "/guilds/$guild_id" "$data"; }
bashcord_delete_guild() { local guild_id="${1:-$DEFAULT_GUILD_ID}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; bashcord_api_request "DELETE" "/guilds/$guild_id" ""; }
bashcord_get_guild_channels() { local guild_id="${1:-$DEFAULT_GUILD_ID}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id/channels"; }
bashcord_get_guild_members() { local guild_id="${1:-$DEFAULT_GUILD_ID}" limit="${2:-1000}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id/members?limit=$limit"; }
bashcord_ban_member() { local guild_id="${1:-$DEFAULT_GUILD_ID}" user_id="$2" reason="$3"; [[ -z "$guild_id" || -z "$user_id" ]] && { bashcord_error "Guild/User ID required."; return 1; }; local data=$(jq -n --arg r "$reason" '{"delete_message_days": 0, "reason": $r}'); bashcord_api_request "PUT" "/guilds/$guild_id/bans/$user_id" "$data"; }
bashcord_unban_member() { local guild_id="${1:-$DEFAULT_GUILD_ID}" user_id="$2"; [[ -z "$guild_id" || -z "$user_id" ]] && { bashcord_error "Guild/User ID required."; return 1; }; bashcord_api_request "DELETE" "/guilds/$guild_id/bans/$user_id" ""; }
bashcord_get_guild_bans() { local guild_id="${1:-$DEFAULT_GUILD_ID}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id/bans"; }
bashcord_create_role() { local guild_id="${1:-$DEFAULT_GUILD_ID}" name="$2" color="${3:-0}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; local data=$(jq -n --arg n "$name" --arg c "$color" '{"name": $n, "color": $c|tonumber}'); bashcord_api_request "POST" "/guilds/$guild_id/roles" "$data"; }
bashcord_modify_role() { local guild_id="${1:-$DEFAULT_GUILD_ID}" role_id="$2" name="$3"; [[ -z "$guild_id" || -z "$role_id" ]] && { bashcord_error "Guild/Role ID required."; return 1; }; local data=$(jq -n --arg n "$name" '{"name": $n}'); bashcord_api_request "PATCH" "/guilds/$guild_id/roles/$role_id" "$data"; }
bashcord_delete_role() { local guild_id="${1:-$DEFAULT_GUILD_ID}" role_id="$2"; [[ -z "$guild_id" || -z "$role_id" ]] && { bashcord_error "Guild/Role ID required."; return 1; }; bashcord_api_request "DELETE" "/guilds/$guild_id/roles/$role_id" ""; }
bashcord_get_guild_roles() { local guild_id="${1:-$DEFAULT_GUILD_ID}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id/roles"; }
bashcord_add_role_to_member() { local guild_id="${1:-$DEFAULT_GUILD_ID}" user_id="$2" role_id="$3"; [[ -z "$guild_id" || -z "$user_id" || -z "$role_id" ]] && { bashcord_error "Guild/User/Role ID required."; return 1; }; bashcord_api_request "PUT" "/guilds/$guild_id/members/$user_id/roles/$role_id" ""; }
bashcord_remove_role_from_member() { local guild_id="${1:-$DEFAULT_GUILD_ID}" user_id="$2" role_id="$3"; [[ -z "$guild_id" || -z "$user_id" || -z "$role_id" ]] && { bashcord_error "Guild/User/Role ID required."; return 1; }; bashcord_api_request "DELETE" "/guilds/$guild_id/members/$user_id/roles/$role_id" ""; }
bashcord_create_invite() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}" max_uses="${2:-0}"; [[ -z "$channel_id" ]] && { bashcord_error "No channel ID."; return 1; }; local data=$(jq -n --arg m "$max_uses" '{"max_uses": $m|tonumber}'); bashcord_api_request "POST" "/channels/$channel_id/invites" "$data"; }
bashcord_get_channel_invites() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}"; [[ -z "$channel_id" ]] && { bashcord_error "No channel ID."; return 1; }; bashcord_api_request "GET" "/channels/$channel_id/invites"; }
bashcord_delete_invite() { local invite_code="$1"; [[ -z "$invite_code" ]] && { bashcord_error "Invite code required."; return 1; }; bashcord_api_request "DELETE" "/invites/$invite_code" ""; }
bashcord_add_reaction() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}" message_id="$2" emoji="$3"; [[ -z "$channel_id" || -z "$message_id" || -z "$emoji" ]] && { bashcord_error "Channel/Message/Emoji required."; return 1; }; bashcord_api_request "PUT" "/channels/$channel_id/messages/$message_id/reactions/$emoji/@me" ""; }
bashcord_remove_reaction() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}" message_id="$2" emoji="$3"; [[ -z "$channel_id" || -z "$message_id" || -z "$emoji" ]] && { bashcord_error "Channel/Message/Emoji required."; return 1; }; bashcord_api_request "DELETE" "/channels/$channel_id/messages/$message_id/reactions/$emoji/@me" ""; }
bashcord_get_reactions() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}" message_id="$2" emoji="$3"; [[ -z "$channel_id" || -z "$message_id" || -z "$emoji" ]] && { bashcord_error "Channel/Message/Emoji required."; return 1; }; bashcord_api_request "GET" "/channels/$channel_id/messages/$message_id/reactions/$emoji"; }
bashcord_get_message() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}" message_id="$2"; [[ -z "$channel_id" || -z "$message_id" ]] && { bashcord_error "Channel/Message ID required."; return 1; }; bashcord_api_request "GET" "/channels/$channel_id/messages/$message_id"; }
bashcord_get_messages() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}" limit="${2:-50}"; [[ -z "$channel_id" ]] && { bashcord_error "No channel ID."; return 1; }; bashcord_api_request "GET" "/channels/$channel_id/messages?limit=$limit"; }
bashcord_pin_message() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}" message_id="$2"; [[ -z "$channel_id" || -z "$message_id" ]] && { bashcord_error "Channel/Message ID required."; return 1; }; bashcord_api_request "PUT" "/channels/$channel_id/pins/$message_id" ""; }
bashcord_unpin_message() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}" message_id="$2"; [[ -z "$channel_id" || -z "$message_id" ]] && { bashcord_error "Channel/Message ID required."; return 1; }; bashcord_api_request "DELETE" "/channels/$channel_id/pins/$message_id" ""; }
bashcord_get_pinned_messages() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}"; [[ -z "$channel_id" ]] && { bashcord_error "No channel ID."; return 1; }; bashcord_api_request "GET" "/channels/$channel_id/pins"; }
bashcord_delete_channel() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}"; [[ -z "$channel_id" ]] && { bashcord_error "No channel ID."; return 1; }; bashcord_api_request "DELETE" "/channels/$channel_id" ""; }
bashcord_modify_channel() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}" name="$2"; [[ -z "$channel_id" ]] && { bashcord_error "No channel ID."; return 1; }; local data=$(jq -n --arg n "$name" '{"name": $n}'); bashcord_api_request "PATCH" "/channels/$channel_id" "$data"; }
bashcord_get_guild_emojis() { local guild_id="${1:-$DEFAULT_GUILD_ID}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id/emojis"; }
bashcord_create_guild_emoji() { local guild_id="${1:-$DEFAULT_GUILD_ID}" name="$2" image="$3"; [[ -z "$guild_id" || -z "$image" ]] && { bashcord_error "Guild ID/Image required."; return 1; }; local data=$(jq -n --arg n "$name" --arg i "$image" '{"name": $n, "image": $i}'); bashcord_api_request "POST" "/guilds/$guild_id/emojis" "$data"; }
bashcord_delete_guild_emoji() { local guild_id="${1:-$DEFAULT_GUILD_ID}" emoji_id="$2"; [[ -z "$guild_id" || -z "$emoji_id" ]] && { bashcord_error "Guild/Emoji ID required."; return 1; }; bashcord_api_request "DELETE" "/guilds/$guild_id/emojis/$emoji_id" ""; }
bashcord_get_guild_widget() { local guild_id="${1:-$DEFAULT_GUILD_ID}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id/widget"; }
bashcord_modify_guild_widget() { local guild_id="${1:-$DEFAULT_GUILD_ID}" enabled="$2" channel_id="$3"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; local data=$(jq -n --arg e "$enabled" --arg c "$channel_id" '{"enabled": $e|tonumber, "channel_id": $c}'); bashcord_api_request "PATCH" "/guilds/$guild_id/widget" "$data"; }
bashcord_get_guild_integrations() { local guild_id="${1:-$DEFAULT_GUILD_ID}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id/integrations"; }
bashcord_delete_guild_integration() { local guild_id="${1:-$DEFAULT_GUILD_ID}" integration_id="$2"; [[ -z "$guild_id" || -z "$integration_id" ]] && { bashcord_error "Guild/Integration ID required."; return 1; }; bashcord_api_request "DELETE" "/guilds/$guild_id/integrations/$integration_id" ""; }
bashcord_get_guild_vanity_url() { local guild_id="${1:-$DEFAULT_GUILD_ID}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id/vanity-url"; }
bashcord_get_guild_welcome_screen() { local guild_id="${1:-$DEFAULT_GUILD_ID}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id/welcome-screen"; }
bashcord_modify_guild_welcome_screen() { local guild_id="${1:-$DEFAULT_GUILD_ID}" enabled="$2"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; local data=$(jq -n --arg e "$enabled" '{"enabled": $e|tonumber}'); bashcord_api_request "PATCH" "/guilds/$guild_id/welcome-screen" "$data"; }
bashcord_get_guild_onboarding() { local guild_id="${1:-$DEFAULT_GUILD_ID}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id/onboarding"; }
bashcord_get_guild_audit_logs() { local guild_id="${1:-$DEFAULT_GUILD_ID}" limit="${2:-50}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id/audit-logs?limit=$limit"; }
bashcord_get_guild_preview() { local guild_id="${1:-$DEFAULT_GUILD_ID}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id/preview"; }
bashcord_get_guild_prune_count() { local guild_id="${1:-$DEFAULT_GUILD_ID}" days="${2:-7}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id/prune?days=$days"; }
bashcord_begin_guild_prune() { local guild_id="${1:-$DEFAULT_GUILD_ID}" days="${2:-7}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; local data=$(jq -n --arg d "$days" '{"days": $d|tonumber}'); bashcord_api_request "POST" "/guilds/$guild_id/prune" "$data"; }
bashcord_get_guild_voice_regions() { local guild_id="${1:-$DEFAULT_GUILD_ID}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id/regions"; }
bashcord_get_guild_invites() { local guild_id="${1:-$DEFAULT_GUILD_ID}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id/invites"; }
bashcord_get_guild_member() { local guild_id="${1:-$DEFAULT_GUILD_ID}" user_id="$2"; [[ -z "$guild_id" || -z "$user_id" ]] && { bashcord_error "Guild/User ID required."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id/members/$user_id"; }
bashcord_remove_guild_member() { local guild_id="${1:-$DEFAULT_GUILD_ID}" user_id="$2"; [[ -z "$guild_id" || -z "$user_id" ]] && { bashcord_error "Guild/User ID required."; return 1; }; bashcord_api_request "DELETE" "/guilds/$guild_id/members/$user_id" ""; }
bashcord_get_guild_ban() { local guild_id="${1:-$DEFAULT_GUILD_ID}" user_id="$2"; [[ -z "$guild_id" || -z "$user_id" ]] && { bashcord_error "Guild/User ID required."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id/bans/$user_id"; }
bashcord_create_guild() { local name="$1"; [[ -z "$name" ]] && { bashcord_error "Guild name required."; return 1; }; local data=$(jq -n --arg n "$name" '{"name": $n}'); bashcord_api_request "POST" "/guilds" "$data"; }
bashcord_get_channel_webhooks() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}"; [[ -z "$channel_id" ]] && { bashcord_error "No channel ID."; return 1; }; bashcord_api_request "GET" "/channels/$channel_id/webhooks"; }
bashcord_get_guild_webhooks() { local guild_id="${1:-$DEFAULT_GUILD_ID}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id/webhooks"; }
bashcord_get_webhook() { local webhook_id="$1"; [[ -z "$webhook_id" ]] && { bashcord_error "Webhook ID required."; return 1; }; bashcord_api_request "GET" "/webhooks/$webhook_id"; }
bashcord_modify_webhook() { local webhook_id="$1" name="$2"; [[ -z "$webhook_id" ]] && { bashcord_error "Webhook ID required."; return 1; }; local data=$(jq -n --arg n "$name" '{"name": $n}'); bashcord_api_request "PATCH" "/webhooks/$webhook_id" "$data"; }
bashcord_delete_webhook() { local webhook_id="$1"; [[ -z "$webhook_id" ]] && { bashcord_error "Webhook ID required."; return 1; }; bashcord_api_request "DELETE" "/webhooks/$webhook_id" ""; }
bashcord_get_current_user() { bashcord_api_request "GET" "/users/@me"; }
bashcord_modify_current_user() { local username="$1"; [[ -z "$username" ]] && { bashcord_error "Username required."; return 1; }; local data=$(jq -n --arg u "$username" '{"username": $u}'); bashcord_api_request "PATCH" "/users/@me" "$data"; }
bashcord_get_current_user_guilds() { bashcord_api_request "GET" "/users/@me/guilds"; }
bashcord_leave_guild() { local guild_id="${1:-$DEFAULT_GUILD_ID}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; bashcord_api_request "DELETE" "/users/@me/guilds/$guild_id" ""; }
bashcord_create_dm() { local user_id="$1"; [[ -z "$user_id" ]] && { bashcord_error "User ID required."; return 1; }; local data=$(jq -n --arg u "$user_id" '{"recipient_id": $u}'); bashcord_api_request "POST" "/users/@me/channels" "$data"; }
bashcord_create_group_dm() { local access_tokens="$1"; [[ -z "$access_tokens" ]] && { bashcord_error "Access tokens required."; return 1; }; local data=$(jq -n --arg a "$access_tokens" '{"access_tokens": $a|split(",")}'); bashcord_api_request "POST" "/users/@me/channels" "$data"; }
bashcord_get_user_connections() { bashcord_api_request "GET" "/users/@me/connections"; }
bashcord_get_voice_regions() { bashcord_api_request "GET" "/voice/regions"; }
bashcord_bulk_delete_messages() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}" message_ids="$2"; [[ -z "$channel_id" || -z "$message_ids" ]] && { bashcord_error "Channel/Message IDs required."; return 1; }; local data=$(jq -n --arg m "$message_ids" '{"messages": $m|split(",")}'); bashcord_api_request "POST" "/channels/$channel_id/messages/bulk-delete" "$data"; }
bashcord_edit_channel_permissions() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}" overwrite_id="$2" allow="$3" deny="$4" type="$5"; [[ -z "$channel_id" || -z "$overwrite_id" ]] && { bashcord_error "Channel/Overwrite ID required."; return 1; }; local data=$(jq -n --arg a "$allow" --arg d "$deny" --arg t "$type" '{"allow": $a, "deny": $d, "type": $t|tonumber}'); bashcord_api_request "PUT" "/channels/$channel_id/permissions/$overwrite_id" "$data"; }
bashcord_delete_channel_permission() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}" overwrite_id="$2"; [[ -z "$channel_id" || -z "$overwrite_id" ]] && { bashcord_error "Channel/Overwrite ID required."; return 1; }; bashcord_api_request "DELETE" "/channels/$channel_id/permissions/$overwrite_id" ""; }
bashcord_trigger_typing() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}"; [[ -z "$channel_id" ]] && { bashcord_error "No channel ID."; return 1; }; bashcord_api_request "POST" "/channels/$channel_id/typing" ""; }
bashcord_get_gateway() { bashcord_api_request "GET" "/gateway"; }
bashcord_get_gateway_bot() { bashcord_api_request "GET" "/gateway/bot"; }
bashcord_get_application_info() { bashcord_api_request "GET" "/applications/@me"; }
bashcord_get_oauth2_token() { local application_id="$1"; [[ -z "$application_id" ]] && { bashcord_error "Application ID required."; return 1; }; bashcord_api_request "GET" "/oauth2/applications/$application_id/assets"; }
bashcord_get_channel_threads() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}"; [[ -z "$channel_id" ]] && { bashcord_error "No channel ID."; return 1; }; bashcord_api_request "GET" "/channels/$channel_id/threads/active"; }
bashcord_create_thread() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}" name="$2" type="${3:-11}"; [[ -z "$channel_id" ]] && { bashcord_error "No channel ID."; return 1; }; local data=$(jq -n --arg n "$name" --arg t "$type" '{"name": $n, "type": $t|tonumber}'); bashcord_api_request "POST" "/channels/$channel_id/threads" "$data"; }
bashcord_join_thread() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}"; [[ -z "$channel_id" ]] && { bashcord_error "No channel ID."; return 1; }; bashcord_api_request "PUT" "/channels/$channel_id/thread-members/@me" ""; }
bashcord_leave_thread() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}"; [[ -z "$channel_id" ]] && { bashcord_error "No channel ID."; return 1; }; bashcord_api_request "DELETE" "/channels/$channel_id/thread-members/@me" ""; }
bashcord_add_thread_member() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}" user_id="$2"; [[ -z "$channel_id" || -z "$user_id" ]] && { bashcord_error "Channel/User ID required."; return 1; }; bashcord_api_request "PUT" "/channels/$channel_id/thread-members/$user_id" ""; }
bashcord_remove_thread_member() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}" user_id="$2"; [[ -z "$channel_id" || -z "$user_id" ]] && { bashcord_error "Channel/User ID required."; return 1; }; bashcord_api_request "DELETE" "/channels/$channel_id/thread-members/$user_id" ""; }
bashcord_get_thread_member() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}" user_id="$2"; [[ -z "$channel_id" || -z "$user_id" ]] && { bashcord_error "Channel/User ID required."; return 1; }; bashcord_api_request "GET" "/channels/$channel_id/thread-members/$user_id"; }
bashcord_get_thread_members() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}"; [[ -z "$channel_id" ]] && { bashcord_error "No channel ID."; return 1; }; bashcord_api_request "GET" "/channels/$channel_id/thread-members"; }
bashcord_get_public_archived_threads() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}" limit="${2:-50}"; [[ -z "$channel_id" ]] && { bashcord_error "No channel ID."; return 1; }; bashcord_api_request "GET" "/channels/$channel_id/threads/archived/public?limit=$limit"; }
bashcord_get_private_archived_threads() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}" limit="${2:-50}"; [[ -z "$channel_id" ]] && { bashcord_error "No channel ID."; return 1; }; bashcord_api_request "GET" "/channels/$channel_id/threads/archived/private?limit=$limit"; }
bashcord_get_joined_private_threads() { local channel_id="${1:-$DEFAULT_CHANNEL_ID}" limit="${2:-50}"; [[ -z "$channel_id" ]] && { bashcord_error "No channel ID."; return 1; }; bashcord_api_request "GET" "/channels/$channel_id/users/@me/threads/archived/private?limit=$limit"; }
bashcord_create_guild_ban() { local guild_id="${1:-$DEFAULT_GUILD_ID}" user_id="$2" delete_days="$3"; [[ -z "$guild_id" || -z "$user_id" ]] && { bashcord_error "Guild/User ID required."; return 1; }; local data=$(jq -n --arg d "$delete_days" '{"delete_message_days": $d|tonumber}'); bashcord_api_request "PUT" "/guilds/$guild_id/bans/$user_id" "$data"; }
bashcord_get_guild_stickers() { local guild_id="${1:-$DEFAULT_GUILD_ID}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id/stickers"; }
bashcord_get_sticker() { local sticker_id="$1"; [[ -z "$sticker_id" ]] && { bashcord_error "Sticker ID required."; return 1; }; bashcord_api_request "GET" "/stickers/$sticker_id"; }
bashcord_create_guild_sticker() { local guild_id="${1:-$DEFAULT_GUILD_ID}" name="$2" file="$3"; [[ -z "$guild_id" || -z "$file" ]] && { bashcord_error "Guild ID/File required."; return 1; }; local data=$(jq -n --arg n "$name" --arg f "$file" '{"name": $n, "file": $f}'); bashcord_api_request "POST" "/guilds/$guild_id/stickers" "$data"; }
bashcord_modify_guild_sticker() { local guild_id="${1:-$DEFAULT_GUILD_ID}" sticker_id="$2" name="$3"; [[ -z "$guild_id" || -z "$sticker_id" ]] && { bashcord_error "Guild/Sticker ID required."; return 1; }; local data=$(jq -n --arg n "$name" '{"name": $n}'); bashcord_api_request "PATCH" "/guilds/$guild_id/stickers/$sticker_id" "$data"; }
bashcord_delete_guild_sticker() { local guild_id="${1:-$DEFAULT_GUILD_ID}" sticker_id="$2"; [[ -z "$guild_id" || -z "$sticker_id" ]] && { bashcord_error "Guild/Sticker ID required."; return 1; }; bashcord_api_request "DELETE" "/guilds/$guild_id/stickers/$sticker_id" ""; }
bashcord_get_sticker_packs() { bashcord_api_request "GET" "/sticker-packs"; }
bashcord_get_guild_scheduled_events() { local guild_id="${1:-$DEFAULT_GUILD_ID}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id/scheduled-events"; }
bashcord_create_guild_scheduled_event() { local guild_id="${1:-$DEFAULT_GUILD_ID}" name="$2" start_time="$3"; [[ -z "$guild_id" || -z "$start_time" ]] && { bashcord_error "Guild ID/Start time required."; return 1; }; local data=$(jq -n --arg n "$name" --arg s "$start_time" '{"name": $n, "scheduled_start_time": $s, "channel_id": null, "entity_type": 3}'); bashcord_api_request "POST" "/guilds/$guild_id/scheduled-events" "$data"; }
bashcord_get_guild_scheduled_event() { local guild_id="${1:-$DEFAULT_GUILD_ID}" event_id="$2"; [[ -z "$guild_id" || -z "$event_id" ]] && { bashcord_error "Guild/Event ID required."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id/scheduled-events/$event_id"; }
bashcord_modify_guild_scheduled_event() { local guild_id="${1:-$DEFAULT_GUILD_ID}" event_id="$2" name="$3"; [[ -z "$guild_id" || -z "$event_id" ]] && { bashcord_error "Guild/Event ID required."; return 1; }; local data=$(jq -n --arg n "$name" '{"name": $n}'); bashcord_api_request "PATCH" "/guilds/$guild_id/scheduled-events/$event_id" "$data"; }
bashcord_delete_guild_scheduled_event() { local guild_id="${1:-$DEFAULT_GUILD_ID}" event_id="$2"; [[ -z "$guild_id" || -z "$event_id" ]] && { bashcord_error "Guild/Event ID required."; return 1; }; bashcord_api_request "DELETE" "/guilds/$guild_id/scheduled-events/$event_id" ""; }
bashcord_get_guild_scheduled_event_users() { local guild_id="${1:-$DEFAULT_GUILD_ID}" event_id="$2" limit="${3:-100}"; [[ -z "$guild_id" || -z "$event_id" ]] && { bashcord_error "Guild/Event ID required."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id/scheduled-events/$event_id/users?limit=$limit"; }
bashcord_get_guild_template() { local template_code="$1"; [[ -z "$template_code" ]] && { bashcord_error "Template code required."; return 1; }; bashcord_api_request "GET" "/guilds/templates/$template_code"; }
bashcord_create_guild_from_template() { local template_code="$1" name="$2"; [[ -z "$template_code" || -z "$name" ]] && { bashcord_error "Template code/Name required."; return 1; }; local data=$(jq -n --arg n "$name" '{"name": $n}'); bashcord_api_request "POST" "/guilds/templates/$template_code" "$data"; }
bashcord_get_guild_templates() { local guild_id="${1:-$DEFAULT_GUILD_ID}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id/templates"; }
bashcord_create_guild_template() { local guild_id="${1:-$DEFAULT_GUILD_ID}" name="$2"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; local data=$(jq -n --arg n "$name" '{"name": $n}'); bashcord_api_request "POST" "/guilds/$guild_id/templates" "$data"; }
bashcord_sync_guild_template() { local guild_id="${1:-$DEFAULT_GUILD_ID}" template_code="$2"; [[ -z "$guild_id" || -z "$template_code" ]] && { bashcord_error "Guild/Template code required."; return 1; }; bashcord_api_request "PUT" "/guilds/$guild_id/templates/$template_code" ""; }
bashcord_modify_guild_template() { local guild_id="${1:-$DEFAULT_GUILD_ID}" template_code="$2" name="$3"; [[ -z "$guild_id" || -z "$template_code" ]] && { bashcord_error "Guild/Template code required."; return 1; }; local data=$(jq -n --arg n "$name" '{"name": $n}'); bashcord_api_request "PATCH" "/guilds/$guild_id/templates/$template_code" "$data"; }
bashcord_delete_guild_template() { local guild_id="${1:-$DEFAULT_GUILD_ID}" template_code="$2"; [[ -z "$guild_id" || -z "$template_code" ]] && { bashcord_error "Guild/Template code required."; return 1; }; bashcord_api_request "DELETE" "/guilds/$guild_id/templates/$template_code" ""; }
bashcord_get_application_commands() { local application_id="$1" guild_id="${2:-$DEFAULT_GUILD_ID}"; [[ -z "$application_id" ]] && { bashcord_error "Application ID required."; return 1; }; [[ -z "$guild_id" ]] && bashcord_api_request "GET" "/applications/$application_id/commands" || bashcord_api_request "GET" "/applications/$application_id/guilds/$guild_id/commands"; }
bashcord_create_application_command() { local application_id="$1" name="$2" description="$3" guild_id="${4:-$DEFAULT_GUILD_ID}"; [[ -z "$application_id" || -z "$name" || -z "$description" ]] && { bashcord_error "Application ID/Name/Description required."; return 1; }; local data=$(jq -n --arg n "$name" --arg d "$description" '{"name": $n, "description": $d, "type": 1}'); [[ -z "$guild_id" ]] && bashcord_api_request "POST" "/applications/$application_id/commands" "$data" || bashcord_api_request "POST" "/applications/$application_id/guilds/$guild_id/commands" "$data"; }
bashcord_get_application_command() { local application_id="$1" command_id="$2" guild_id="${3:-$DEFAULT_GUILD_ID}"; [[ -z "$application_id" || -z "$command_id" ]] && { bashcord_error "Application/Command ID required."; return 1; }; [[ -z "$guild_id" ]] && bashcord_api_request "GET" "/applications/$application_id/commands/$command_id" || bashcord_api_request "GET" "/applications/$application_id/guilds/$guild_id/commands/$command_id"; }
bashcord_edit_application_command() { local application_id="$1" command_id="$2" name="$3" guild_id="${4:-$DEFAULT_GUILD_ID}"; [[ -z "$application_id" || -z "$command_id" ]] && { bashcord_error "Application/Command ID required."; return 1; }; local data=$(jq -n --arg n "$name" '{"name": $n}'); [[ -z "$guild_id" ]] && bashcord_api_request "PATCH" "/applications/$application_id/commands/$command_id" "$data" || bashcord_api_request "PATCH" "/applications/$application_id/guilds/$guild_id/commands/$command_id" "$data"; }
bashcord_delete_application_command() { local application_id="$1" command_id="$2" guild_id="${3:-$DEFAULT_GUILD_ID}"; [[ -z "$application_id" || -z "$command_id" ]] && { bashcord_error "Application/Command ID required."; return 1; }; [[ -z "$guild_id" ]] && bashcord_api_request "DELETE" "/applications/$application_id/commands/$command_id" || bashcord_api_request "DELETE" "/applications/$application_id/guilds/$guild_id/commands/$command_id"; }
bashcord_bulk_overwrite_global_commands() { local application_id="$1" commands="$2"; [[ -z "$application_id" || -z "$commands" ]] && { bashcord_error "Application ID/Commands required."; return 1; }; bashcord_api_request "PUT" "/applications/$application_id/commands" "$commands"; }
bashcord_bulk_overwrite_guild_commands() { local application_id="$1" guild_id="${2:-$DEFAULT_GUILD_ID}" commands="$3"; [[ -z "$application_id" || -z "$commands" ]] && { bashcord_error "Application ID/Commands required."; return 1; }; bashcord_api_request "PUT" "/applications/$application_id/guilds/$guild_id/commands" "$commands"; }
bashcord_get_guild_command_permissions() { local application_id="$1" guild_id="${2:-$DEFAULT_GUILD_ID}"; [[ -z "$application_id" ]] && { bashcord_error "Application ID required."; return 1; }; bashcord_api_request "GET" "/applications/$application_id/guilds/$guild_id/commands/permissions"; }
bashcord_get_command_permissions() { local application_id="$1" guild_id="${2:-$DEFAULT_GUILD_ID}" command_id="$3"; [[ -z "$application_id" || -z "$command_id" ]] && { bashcord_error "Application/Command ID required."; return 1; }; bashcord_api_request "GET" "/applications/$application_id/guilds/$guild_id/commands/$command_id/permissions"; }
bashcord_edit_command_permissions() { local application_id="$1" guild_id="${2:-$DEFAULT_GUILD_ID}" command_id="$3" permissions="$4"; [[ -z "$application_id" || -z "$command_id" || -z "$permissions" ]] && { bashcord_error "Application/Command ID/Permissions required."; return 1; }; bashcord_api_request "PUT" "/applications/$application_id/guilds/$guild_id/commands/$command_id/permissions" "$permissions"; }
bashcord_create_interaction_response() { local interaction_id="$1" interaction_token="$2" type="$3" data="$4"; [[ -z "$interaction_id" || -z "$interaction_token" || -z "$type" ]] && { bashcord_error "Interaction ID/Token/Type required."; return 1; }; local payload=$(jq -n --arg t "$type" --argjson d "$data" '{"type": $t|tonumber, "data": $d}'); bashcord_api_request "POST" "/interactions/$interaction_id/$interaction_token/callback" "$payload"; }
bashcord_get_interaction_response() { local application_id="$1" interaction_token="$2"; [[ -z "$application_id" || -z "$interaction_token" ]] && { bashcord_error "Application ID/Interaction token required."; return 1; }; bashcord_api_request "GET" "/webhooks/$application_id/$interaction_token/messages/@original"; }
bashcord_edit_interaction_response() { local application_id="$1" interaction_token="$2" content="$3"; [[ -z "$application_id" || -z "$interaction_token" ]] && { bashcord_error "Application ID/Interaction token required."; return 1; }; local data=$(jq -n --arg c "$content" '{"content": $c}'); bashcord_api_request "PATCH" "/webhooks/$application_id/$interaction_token/messages/@original" "$data"; }
bashcord_delete_interaction_response() { local application_id="$1" interaction_token="$2"; [[ -z "$application_id" || -z "$interaction_token" ]] && { bashcord_error "Application ID/Interaction token required."; return 1; }; bashcord_api_request "DELETE" "/webhooks/$application_id/$interaction_token/messages/@original" ""; }
bashcord_create_followup_message() { local application_id="$1" interaction_token="$2" content="$3"; [[ -z "$application_id" || -z "$interaction_token" ]] && { bashcord_error "Application ID/Interaction token required."; return 1; }; local data=$(jq -n --arg c "$content" '{"content": $c}'); bashcord_api_request "POST" "/webhooks/$application_id/$interaction_token" "$data"; }
bashcord_get_followup_message() { local application_id="$1" interaction_token="$2" message_id="$3"; [[ -z "$application_id" || -z "$interaction_token" || -z "$message_id" ]] && { bashcord_error "Application ID/Interaction token/Message ID required."; return 1; }; bashcord_api_request "GET" "/webhooks/$application_id/$interaction_token/messages/$message_id"; }
bashcord_edit_followup_message() { local application_id="$1" interaction_token="$2" message_id="$3" content="$4"; [[ -z "$application_id" || -z "$interaction_token" || -z "$message_id" ]] && { bashcord_error "Application ID/Interaction token/Message ID required."; return 1; }; local data=$(jq -n --arg c "$content" '{"content": $c}'); bashcord_api_request "PATCH" "/webhooks/$application_id/$interaction_token/messages/$message_id" "$data"; }
bashcord_delete_followup_message() { local application_id="$1" interaction_token="$2" message_id="$3"; [[ -z "$application_id" || -z "$interaction_token" || -z "$message_id" ]] && { bashcord_error "Application ID/Interaction token/Message ID required."; return 1; }; bashcord_api_request "DELETE" "/webhooks/$application_id/$interaction_token/messages/$message_id" ""; }
bashcord_get_guild_incidents() { local guild_id="${1:-$DEFAULT_GUILD_ID}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id/incidents"; }
bashcord_modify_guild_incidents() { local guild_id="${1:-$DEFAULT_GUILD_ID}" invites_disabled="$2"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; local data=$(jq -n --arg i "$invites_disabled" '{"invites_disabled_until": $i}'); bashcord_api_request "PATCH" "/guilds/$guild_id/incidents" "$data"; }
bashcord_get_auto_moderation_rules() { local guild_id="${1:-$DEFAULT_GUILD_ID}"; [[ -z "$guild_id" ]] && { bashcord_error "No guild ID."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id/auto-moderation/rules"; }
bashcord_get_auto_moderation_rule() { local guild_id="${1:-$DEFAULT_GUILD_ID}" rule_id="$2"; [[ -z "$guild_id" || -z "$rule_id" ]] && { bashcord_error "Guild/Rule ID required."; return 1; }; bashcord_api_request "GET" "/guilds/$guild_id/auto-moderation/rules/$rule_id"; }
bashcord_create_auto_moderation_rule() { local guild_id="${1:-$DEFAULT_GUILD_ID}" name="$2" event_type="$3" actions="$4"; [[ -z "$guild_id" || -z "$event_type" || -z "$actions" ]] && { bashcord_error "Guild ID/Event type/Actions required."; return 1; }; local data=$(jq -n --arg n "$name" --arg e "$event_type" --argjson a "$actions" '{"name": $n, "event_type": $e|tonumber, "actions": $a}'); bashcord_api_request "POST" "/guilds/$guild_id/auto-moderation/rules" "$data"; }
bashcord_modify_auto_moderation_rule() { local guild_id="${1:-$DEFAULT_GUILD_ID}" rule_id="$2" name="$3"; [[ -z "$guild_id" || -z "$rule_id" ]] && { bashcord_error "Guild/Rule ID required."; return 1; }; local data=$(jq -n --arg n "$name" '{"name": $n}'); bashcord_api_request "PATCH" "/guilds/$guild_id/auto-moderation/rules/$rule_id" "$data"; }
bashcord_delete_auto_moderation_rule() { local guild_id="${1:-$DEFAULT_GUILD_ID}" rule_id="$2"; [[ -z "$guild_id" || -z "$rule_id" ]] && { bashcord_error "Guild/Rule ID required."; return 1; }; bashcord_api_request "DELETE" "/guilds/$guild_id/auto-moderation/rules/$rule_id" ""; }
bashcord_get_entitlements() { local application_id="$1"; [[ -z "$application_id" ]] && { bashcord_error "Application ID required."; return 1; }; bashcord_api_request "GET" "/applications/$application_id/entitlements"; }
bashcord_create_test_entitlement() { local application_id="$1" sku_id="$2"; [[ -z "$application_id" || -z "$sku_id" ]] && { bashcord_error "Application/SKU ID required."; return 1; }; local data=$(jq -n --arg s "$sku_id" '{"sku_id": $s}'); bashcord_api_request "POST" "/applications/$application_id/entitlements" "$data"; }
bashcord_delete_test_entitlement() { local application_id="$1" entitlement_id="$2"; [[ -z "$application_id" || -z "$entitlement_id" ]] && { bashcord_error "Application/Entitlement ID required."; return 1; }; bashcord_api_request "DELETE" "/applications/$application_id/entitlements/$entitlement_id" ""; }
bashcord_consume_entitlement() { local application_id="$1" entitlement_id="$2"; [[ -z "$application_id" || -z "$entitlement_id" ]] && { bashcord_error "Application/Entitlement ID required."; return 1; }; bashcord_api_request "POST" "/applications/$application_id/entitlements/$entitlement_id/consume" ""; }
bashcord_get_skus() { local application_id="$1"; [[ -z "$application_id" ]] && { bashcord_error "Application ID required."; return 1; }; bashcord_api_request "GET" "/applications/$application_id/skus"; }

# Export all 190 functions
export -f bashcord_load_config bashcord_api_request bashcord_log bashcord_error bashcord_command bashcord_command_decorator bashcord_guild_id bashcord_channel_id bashcord_toggle_debug bashcord_wrapper_close bashcord_get_gateway_url bashcord_send_identify bashcord_send_heartbeat bashcord_process_event bashcord_run bashcord_send_message bashcord_edit_message bashcord_delete_message bashcord_get_channel bashcord_create_channel bashcord_get_user bashcord_modify_member bashcord_create_webhook bashcord_execute_webhook bashcord_get_guild bashcord_modify_guild bashcord_delete_guild bashcord_get_guild_channels bashcord_get_guild_members bashcord_ban_member bashcord_unban_member bashcord_get_guild_bans bashcord_create_role bashcord_modify_role bashcord_delete_role bashcord_get_guild_roles bashcord_add_role_to_member bashcord_remove_role_from_member bashcord_create_invite bashcord_get_channel_invites bashcord_delete_invite bashcord_add_reaction bashcord_remove_reaction bashcord_get_reactions bashcord_get_message bashcord_get_messages bashcord_pin_message bashcord_unpin_message bashcord_get_pinned_messages bashcord_delete_channel bashcord_modify_channel bashcord_get_guild_emojis bashcord_create_guild_emoji bashcord_delete_guild_emoji bashcord_get_guild_widget bashcord_modify_guild_widget bashcord_get_guild_integrations bashcord_delete_guild_integration bashcord_get_guild_vanity_url bashcord_get_guild_welcome_screen bashcord_modify_guild_welcome_screen bashcord_get_guild_onboarding bashcord_get_guild_audit_logs bashcord_get_guild_preview bashcord_get_guild_prune_count bashcord_begin_guild_prune bashcord_get_guild_voice_regions bashcord_get_guild_invites bashcord_get_guild_member bashcord_remove_guild_member bashcord_get_guild_ban bashcord_create_guild bashcord_get_channel_webhooks bashcord_get_guild_webhooks bashcord_get_webhook bashcord_modify_webhook bashcord_delete_webhook bashcord_get_current_user bashcord_modify_current_user bashcord_get_current_user_guilds bashcord_leave_guild bashcord_create_dm bashcord_create_group_dm bashcord_get_user_connections bashcord_get_voice_regions bashcord_bulk_delete_messages bashcord_edit_channel_permissions bashcord_delete_channel_permission bashcord_trigger_typing bashcord_get_gateway bashcord_get_gateway_bot bashcord_get_application_info bashcord_get_oauth2_token bashcord_get_channel_threads bashcord_create_thread bashcord_join_thread bashcord_leave_thread bashcord_add_thread_member bashcord_remove_thread_member bashcord_get_thread_member bashcord_get_thread_members bashcord_get_public_archived_threads bashcord_get_private_archived_threads bashcord_get_joined_private_threads bashcord_create_guild_ban bashcord_get_guild_stickers bashcord_get_sticker bashcord_create_guild_sticker bashcord_modify_guild_sticker bashcord_delete_guild_sticker bashcord_get_sticker_packs bashcord_get_guild_scheduled_events bashcord_create_guild_scheduled_event bashcord_get_guild_scheduled_event bashcord_modify_guild_scheduled_event bashcord_delete_guild_scheduled_event bashcord_get_guild_scheduled_event_users bashcord_get_guild_template bashcord_create_guild_from_template bashcord_get_guild_templates bashcord_create_guild_template bashcord_sync_guild_template bashcord_modify_guild_template bashcord_delete_guild_template bashcord_get_application_commands bashcord_create_application_command bashcord_get_application_command bashcord_edit_application_command bashcord_delete_application_command bashcord_bulk_overwrite_global_commands bashcord_bulk_overwrite_guild_commands bashcord_get_guild_command_permissions bashcord_get_command_permissions bashcord_edit_command_permissions bashcord_create_interaction_response bashcord_get_interaction_response bashcord_edit_interaction_response bashcord_delete_interaction_response bashcord_create_followup_message bashcord_get_followup_message bashcord_edit_followup_message bashcord_delete_followup_message bashcord_get_guild_incidents bashcord_modify_guild_incidents bashcord_get_auto_moderation_rules bashcord_get_auto_moderation_rule bashcord_create_auto_moderation_rule bashcord_modify_auto_moderation_rule bashcord_delete_auto_moderation_rule bashcord_get_entitlements bashcord_create_test_entitlement bashcord_delete_test_entitlement bashcord_consume_entitlement bashcord_get_skus

# Start the bot if run directly
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    trap 'bashcord_wrapper_close' SIGINT SIGTERM
    bashcord_run &

    # Listen for Gateway events
    local gateway_url=$(bashcord_get_gateway_url)
    websocat -t "$gateway_url" --text | while read -r event; do
        [[ -n "$event" ]] && bashcord_process_event "$event"
        [[ "$RUNNING" -eq 0 ]] && break
    done
fi
