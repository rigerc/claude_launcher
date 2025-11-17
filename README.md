# Claude Launcher 🚀

A simple bash script that lets you use Claude CLI with different providers like OpenAI, Z.ai, and others. Powered by [Claude-Connect](https://github.com/drbarq/Claude-Connect) for proxy functionality and [models.dev](https://models.dev) for provider data, it handles all the complicated setup stuff so you can just pick your provider and start chatting.

## What it does

- **Multiple providers**: Use standard Claude, Z.ai, or any OpenAI-compatible provider
- **Easy selection**: Pick your provider and model from a nice menu
- **Auto setup**: Handles proxy servers and API connections for you
- **Smart caching**: Remembers available models so it starts faster
- **No hassle**: Takes care of all the boring configuration details

## Quick Start

### 1. Install the basics

**macOS:**
```bash
brew install gum jq curl
```

**Ubuntu/Debian:**
```bash
echo "deb [trusted=yes] https://repo.charm.sh/apt/ /" | sudo tee /etc/apt/sources.list.d/charm.list
sudo apt update && sudo apt install gum jq curl
```

**Other Linux:**
```bash
# Download gum
sudo wget -qO /usr/local/bin/gum https://github.com/charmbracelet/gum/releases/latest/download/gum_Linux_x86_64.tar.gz
sudo tar -xzf /usr/local/bin/gum gum_Linux_x86_64.tar.gz -C /usr/local/bin/ gum
sudo rm gum_Linux_x86_64.tar.gz
sudo chmod +x /usr/local/bin/gum

# Install jq and curl
sudo apt-get install jq curl  # or yum install jq curl
```

### 2. Get the script

```bash
curl -O https://raw.githubusercontent.com/your-repo/claude_launcher.sh
chmod +x claude_launcher.sh
```

### 3. (Optional) Get Claude-Connect for OpenAI providers

```bash
curl -O https://raw.githubusercontent.com/drbarq/Claude-Connect/main/claude_connect.py
chmod +x claude_connect.py
```

## Using it

### Basic usage
```bash
# Interactive mode - just pick what you want
./claude_launcher.sh

# Or jump straight to a provider
./claude_launcher.sh -p claude      # Standard Claude
./claude_launcher.sh -p zai         # Z.ai
./claude_launcher.sh -p openai      # OpenAI-compatible provider
```

### Test it first
```bash
# Try without actually launching Claude
./claude_launcher.sh --dry-run
```

### Command line arguments
```bash
./claude_launcher.sh [OPTIONS] [-- CLAUDE_ARGS]

Options:
  -p, --provider PROVIDER    Skip menu and go straight to a provider
  -c, --config FILE          Use a specific config file
  -q, --quiet                Less output (just the essentials)
      --dry-run              Test provider selection without actually launching Claude
      --log-level LEVEL      How much info to show (DEBUG, INFO, WARN, ERROR)
  -h, --help                 Show help
  -v, --version              Show version

Examples:
  ./claude_launcher.sh -p claude              # Use standard Claude directly
  ./claude_launcher.sh -p openai --dry-run    # Test OpenAI setup
  ./claude_launcher.sh --quiet                # Minimal output
  ./claude_launcher.sh --log-level DEBUG      # Lots of debugging info
```

### Environment variables
```bash
# Set your API keys
export ZAI_API_KEY="your_zai_key"
export OPENAI_API_KEY="your_openai_key"

# Tell it where to find claude_connect.py
export CLAUDE_CONNECT_SCRIPT="/path/to/claude_connect.py"
```

## Providers

### Standard Claude
Just need the regular Claude CLI installed and configured.

### Z.ai
Set `ZAI_API_KEY` and you're good to go.

### OpenAI-compatible providers
The script uses [Claude-Connect](https://github.com/drbarq/Claude-Connect) as a proxy and gets provider info from [models.dev](https://models.dev/api.json). It'll prompt for API keys as needed. The launcher will use env variables from Models.dev for each provider for the API key. Claude-Connect will transform OpenAI to Anthropic's format. It's a bit hit or miss, but with some models it works.

## Configuration (optional)

Create `~/.claude_launcher.conf` if you want. See [claude_launcher.example.conf](claude_launcher.examlple.conf) for example settings you can set.

## Troubleshooting

**Missing dependencies?** Install gum, jq, and curl.

**Claude-Connect not found?** Set `CLAUDE_CONNECT_SCRIPT` or let the script prompt you.

**API key issues?** Set environment variables or let the script ask for them.

**Weird errors?** Run with debug logging:
```bash
./claude_launcher.sh --log-level DEBUG
```

## That's it!

No complicated setup, no reading through pages of documentation. Just run the script and pick your provider. It handles the rest.

---

*Powered by [Claude-Connect](https://github.com/drbarq/Claude-Connect) and [models.dev](https://models.dev)*