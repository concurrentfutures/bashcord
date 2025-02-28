#!/bin/bash

CONFIG_FILE="config.json"

if [[ -f "$CONFIG_FILE" ]]; then
    echo "Warning: $CONFIG_FILE exists. Overwrite? (y/N)"
    read -r overwrite
    [[ "$overwrite" != "y" && "$overwrite" != "Y" ]] && { echo "Aborted."; exit 0; }
fi

echo "Enter your Discord Bot Token:"
read -r BOT_TOKEN
echo "Enter a default Guild ID (optional):"
read -r DEFAULT_GUILD_ID
echo "Enter a default Channel ID (optional):"
read -r DEFAULT_CHANNEL_ID
echo "Enter command prefix (e.g., !):"
read -r PREFIX

jq -n \
    --arg token "$BOT_TOKEN" \
    --arg guild "$DEFAULT_GUILD_ID" \
    --arg channel "$DEFAULT_CHANNEL_ID" \
    --arg prefix "$PREFIX" \
    '{
        "bot_token": $token,
        "default_guild_id": $guild,
        "default_channel_id": $channel,
        "prefix": $prefix
    }' > "$CONFIG_FILE"

[[ $? -eq 0 ]] && { echo "Config saved to $CONFIG_FILE"; chmod 600 "$CONFIG_FILE"; } || { echo "Error creating $CONFIG_FILE"; exit 1; }
