```markdown
```
# Bashcord

![Bashcord Logo](https://via.placeholder.com/150) <!-- Replace with actual logo if available -->

**Bashcord** is a powerful and extensive Discord API wrapper written entirely in Bash. It supports 190 Discord API v10 endpoints, allowing you to interact with Discord programmatically from the command line or scripts. With built-in Gateway support, Bashcord can run as an online bot, processing commands in real-time using a configurable prefix. It features command handling, error handling, and colorful logging, making it a unique tool for Discord automation in a shell environment.

## Features

- **190 API Functions**: Comprehensive coverage of Discord API v10 endpoints, including guilds, channels, roles, messages, webhooks, threads, stickers, scheduled events, application commands, and more.
- **Online Bot**: Connects to the Discord Gateway, stays online, and processes commands with a custom prefix (e.g., `!`).
- **Command Handling**: Define custom commands using the `@bashcord.command()` syntax, executed via Discord messages.
- **Logging**: Colorful logs with yellow timestamps (`[ LOGGING ] 〔 TIME 〕`) and white messages, saved to `bashcord.log`.
- **Error Handling**: Red error messages (`[ ERROR ] 〔 TIME 〕`) with detailed output, logged for debugging.
- **Modular Design**: Importable as a Bash module for use in other scripts.
- **Shutdown Control**: Close the bot by sending `bashcord.wrapper_close()` in its DMs or using Ctrl+C.

## Prerequisites

- **Bash**: A POSIX-compliant shell (tested on Bash 5.x).
- **curl**: For HTTP requests to the Discord API.
- **jq**: For JSON parsing and manipulation.
- **websocat**: For WebSocket communication with the Discord Gateway.

Install dependencies on Ubuntu:
```bash
sudo apt install curl jq websocat
```

On macOS:
```bash
brew install curl jq websocat
```

## Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/concurrent.futures/bashcord.git
   cd bashcord
   ```

2. Make scripts executable:
   ```bash
   chmod +x bashcord.sh configure.sh
   ```

3. Configure the bot:
   ```bash
   ./configure.sh
   ```
   - Enter your Discord bot token (from [Discord Developer Portal](https://discord.com/developers/applications)).
   - Optionally set a default guild ID and channel ID.
   - Specify a command prefix (e.g., `!`).

   This creates a `config.json` file with your settings.

## Usage

### Running the Bot

Start Bashcord as an online bot:
```bash
./bashcord.sh
```
- The bot connects to the Discord Gateway and stays online, logging events to `bashcord.log`.
- Shut it down by sending `bashcord.wrapper_close()` in the bot’s DMs or pressing Ctrl+C.

### Defining Commands

Create a script (e.g., `my_bot.sh`) to define custom commands:

```bash
#!/bin/bash

source ./bashcord.sh

@bashcord.command() {
    local message_id="$1" emoji="$2" channel_id="$3"
    bashcord_command_decorator "react" "
        bashcord_add_reaction \"\$channel_id\" \"\$message_id\" \"\$emoji\"
        bashcord_send_message \"\$channel_id\" \"Added reaction \$emoji to message \$message_id\"
    "
}

@bashcord.command() {
    local name="$1" channel_id="$2"
    bashcord_command_decorator "role" "
        bashcord_create_role \"\$(bashcord_guild_id)\" \"\$name\"
        bashcord_send_message \"\$channel_id\" \"Created role: \$name\"
    "
}

@bashcord.command() {
    local channel_id="$1"
    bashcord_command_decorator "ping" "
        bashcord_send_message \"\$channel_id\" \"Pong!\"
    "
}
```

Make it executable:
```bash
chmod +x my_bot.sh
```

Then run `bashcord.sh` to use these commands on Discord.

### Using Commands on Discord

With a prefix of `!` (set in `config.json`):
- `!react MESSAGE_ID 👍`: Adds a 👍 reaction to the specified message.
- `!role Moderator`: Creates a "Moderator" role in the default guild.
- `!ping`: Responds with "Pong!" in the channel.

### Logs

Logs are written to `bashcord.log` and displayed in the terminal:
- `[ LOGGING ] 〔 2025-02-28 12:01:00 〕 | Executing command: react with args: MESSAGE_ID 👍 CHANNEL_ID` (yellow timestamp, white message)
- `[ ERROR ] 〔 2025-02-28 12:02:00 〕 | HTTP Error 403: Missing Permissions` (red timestamp, white message)

## Configuration

The `config.json` file contains:
```json
{
    "bot_token": "YOUR_BOT_TOKEN",
    "default_guild_id": "GUILD_ID",
    "default_channel_id": "CHANNEL_ID",
    "prefix": "!"
}
```

- `bot_token`: Required. Obtain from Discord Developer Portal.
- `default_guild_id` and `default_channel_id`: Optional defaults for commands.
- `prefix`: Required. Prefix for bot commands (e.g., `!`, `.`).

## Limitations

- **WebSocket**: Relies on `websocat`, which is less robust than native WebSocket libraries in languages like Python or Node.js.
- **Performance**: Bash is not optimized for real-time applications; consider Python’s `discord.py` for production bots.
- **Intents**: Currently set to 513 (GUILDS and GUILD_MESSAGES). Modify `bashcord_send_identify` for additional intents (e.g., 32767 for all).

## Contributing

Contributions are welcome! Please:
1. Fork the repository.
2. Create a feature branch (`git checkout -b feature/new-feature`).
3. Commit changes (`git commit -m "Add new feature"`).
4. Push to the branch (`git push origin feature/new-feature`).
5. Open a pull request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Inspired by the need for a Bash-based Discord tool.
- Built with love for shell scripting enthusiasts.
- Thanks to the Discord API team for their comprehensive documentation.
```
