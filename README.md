# Claude Launcher

A comprehensive bash script for launching Claude CLI with multiple provider configurations, including via proxy powered by Claude-Connect for OpenAI-compatible providers.

## Features

- **Multi-Provider Support**: Launch Claude with various providers (Standard Claude, Z.ai, OpenAI-compatible providers)
- **Interactive Provider Selection**: User-friendly interface powered by `gum`
- **Automatic Proxy Management**: Built-in proxy server for OpenAI-compatible providers
- **API Data Caching**: Efficient caching of provider and model data with configurable TTL
- **Comprehensive Logging**: Structured logging with multiple levels (DEBUG, INFO, WARN, ERROR)
- **Security Hardened**: Input sanitization, validation, and secure process management
- **Configuration Management**: Flexible configuration system with multiple locations
- **Dry Run Mode**: Test provider selection without launching Claude
- **Process Cleanup**: Robust cleanup of background processes and temporary files

## Requirements

- [gum](https://github.com/charmbracelet/gum) - Interactive terminal UI
- [jq](https://stedolan.github.io/jq/) - JSON processor
- [curl](https://curl.se/) - HTTP client
- [claude](https://github.com/anthropics/claude-cli) - Official Claude CLI
- [python](https://python.org) or [python3](https://python.org) - For Claude-Connect proxy
- Optional: [Claude-Connect](https://github.com/drbarq/Claude-Connect) - For OpenAI-compatible providers

## Installation

### 1. Download the Script

```bash
# Clone the repository
git clone https://github.com/your-username/claude-launcher.git
cd claude-launcher

# Or download the script directly
curl -O https://raw.githubusercontent.com/your-username/claude-launcher/main/claude_launcher.sh
chmod +x claude_launcher.sh
```

### 2. Install Dependencies

**macOS:**
```bash
brew install gum jq curl
```

**Ubuntu/Debian:**
```bash
sudo apt-get update
sudo apt-get install gum jq curl
```

**Fedora/CentOS:**
```bash
sudo dnf install gum jq curl
```

### 3. Install Claude CLI

```bash
# Using npm
npm install -g @anthropic-ai/claude-cli

# Or following the official installation guide
# https://github.com/anthropics/claude-cli?tab=readme-ov-file#installation
```

### 4. Install Claude-Connect (Optional)

For OpenAI-compatible provider support:

```bash
# Clone Claude-Connect
git clone https://github.com/drbarq/Claude-Connect.git
cd Claude-Connect

# Or download claude_connect.py directly
curl -O https://raw.githubusercontent.com/drbarq/Claude-Connect/main/claude_connect.py
```

## Quick Start

### Interactive Mode

```bash
./claude_launcher.sh
```

This will present an interactive menu to select your provider and configuration.

### Direct Provider Selection

```bash
# Launch standard Claude
./claude_launcher.sh -p claude

# Launch with Z.ai (requires ZAI_API_KEY)
./claude_launcher.sh -p zai

# Launch with OpenAI-compatible provider
./claude_launcher.sh -p openai

# Dry run to test selection without launching
./claude_launcher.sh -p openai --dry-run
```

### Passing Arguments to Claude

```bash
# Pass Claude CLI arguments after --
./claude_launcher.sh -p claude -- --model opus --stream

# With file arguments
./claude_launcher.sh -p zai -- my_prompt.txt
```

## Configuration

### Configuration File Locations

The script searches for configuration in the following order:

1. `$CLAUDE_LAUNCHER_CONFIG` (environment variable)
2. `~/.claude_launcher.conf`
3. `$XDG_CONFIG_HOME/claude_launcher/config`
4. `~/.config/claude_launcher/config`
5. `/etc/claude_launcher.conf`

### Sample Configuration

Create `~/.claude_launcher.conf`:

```bash
# Claude Connect script path
CLAUDE_CONNECT_SCRIPT="/opt/claude-connect/claude_connect.py"

# API settings
MODELS_DEV_API_URL="https://models.dev/api.json"
CACHE_TTL=3600  # 1 hour

# Proxy settings
PROXY_PORT=8080
PROXY_STARTUP_TIMEOUT=30

# Provider filter settings
PROVIDER_MODELS_ONLY_FREE=true
PROVIDER_MODELS_ONLY_REASONING=false
PREFERRED_MODELS="gpt-4,claude-3-opus"

# Z.ai configuration
ZAI_BASE_URL="https://api.z.ai/api/anthropic"
ZAI_HAIKU_MODEL="glm-4.5-air"
ZAI_OPUS_MODEL="glm-4.6"
ZAI_SONNET_MODEL="glm-4.6"

# UI preferences
AUTO_SELECT_PROVIDER=""
QUIET_MODE=false
LOG_LEVEL="INFO"
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `CLAUDE_LAUNCHER_CONFIG` | Path to configuration file | `~/.claude_launcher.conf` |
| `AUTO_SELECT_PROVIDER` | Auto-select provider without menu | `""` |
| `QUIET_MODE` | Reduce output verbosity | `false` |
| `LOG_LEVEL` | Logging level (DEBUG, INFO, WARN, ERROR) | `INFO` |
| `ZAI_API_KEY` | Z.ai API key | Required for Z.ai |
| `OPENAI_API_KEY` | OpenAI API key | Required for OpenAI providers |
| `ANTHROPIC_API_KEY` | Anthropic API key | Required for Anthropic providers |
| `PREFERRED_MODELS` | Comma-separated list of preferred models | `""` |
| `PROVIDER_MODELS_ONLY_FREE` | Show only free models | `true` |
| `PROVIDER_MODELS_ONLY_REASONING` | Show only reasoning models | `true` |
| `CHECK_CLAUDE_CONNECT_UPDATES` | Check for Claude Connect updates | `true` |
| `CACHE_TTL` | API cache TTL in seconds | `3600` |

## Usage

### Command Line Options

```bash
Usage: claude_launcher.sh [OPTIONS] [-- CLAUDE_ARGS]

Options:
  -p, --provider PROVIDER    Select provider (claude, zai, openai)
  -c, --config FILE          Use specific configuration file
  -q, --quiet                Quiet mode (minimal output)
      --dry-run              Test provider selection without launching Claude
      --log-level LEVEL      Set log level (DEBUG, INFO, WARN, ERROR)
  -h, --help                 Show this help message
  -v, --version              Show version information
```

### Provider Types

#### 1. Standard Claude (`claude`)
Launches the official Claude CLI directly.

```bash
./claude_launcher.sh -p claude -- --model opus
```

#### 2. Z.ai (`zai`)
Uses the Z.ai API as a proxy to Claude models.

```bash
export ZAI_API_KEY="your-zai-api-key"
./claude_launcher.sh -p zai
```

#### 3. OpenAI-Compatible Providers (`openai`)
Routes requests through OpenAI-compatible providers via Claude-Connect proxy.

Supports providers like:
- OpenAI
- Together AI
- Groq
- Anthropic (via OpenAI compatibility)
- And many others from [models.dev](https://models.dev)

```bash
# Interactive selection
./claude_launcher.sh -p openai

# With preferred models
export PREFERRED_MODELS="gpt-4-turbo,claude-3-opus"
./claude_launcher.sh -p openai
```

## API Key Management

### Provider API Keys

Each OpenAI-compatible provider requires its own API key:

- **OpenAI**: `OPENAI_API_KEY`
- **Together AI**: `TOGETHER_API_KEY`
- **Groq**: `GROQ_API_KEY`
- **Anthropic**: `ANTHROPIC_API_KEY`

The script will prompt for API keys if they're not set in the environment.

### Z.ai API Key

```bash
export ZAI_API_KEY="your-zai-api-key"

# Or set in your shell profile (~/.bashrc, ~/.zshrc)
echo 'export ZAI_API_KEY="your-zai-api-key"' >> ~/.bashrc
```

## Advanced Usage

### Proxy Management

The script automatically manages the Claude-Connect proxy for OpenAI-compatible providers:

- **Port Detection**: Automatically finds available ports
- **Process Cleanup**: Ensures proper shutdown
- **Health Checks**: Waits for proxy to be ready
- **Log Management**: Captures proxy output to log files

### Caching

API responses from `models.dev` are cached locally for performance:

- **Location**: `$XDG_CACHE_HOME/claude_launcher/models_dev_api.json`
- **TTL**: Configurable via `CACHE_TTL` (default: 1 hour)
- **Stale Fallback**: Uses stale cache if network is unavailable

### Logging

Structured logging with multiple levels:

```bash
# Enable debug logging
./claude_launcher.sh --log-level DEBUG

# View logs
tail -f ~/.local/share/claude_launcher/logs/claude_launcher.log

# Proxy logs
tail -f ~/.local/share/claude_launcher/logs/proxy.log
```

### Automatic Updates

#### Claude Connect Update Checking
The script automatically checks for updates to `claude_connect.py` before launching:

- **Frequency**: Checks once every 24 hours
- **Method**: Compares content hashes of first 1KB of the script
- **Notification**: Shows warning if your version differs from the latest
- **Caching**: Results are cached to avoid repeated network requests

**Disable update checking**:
```bash
export CHECK_CLAUDE_CONNECT_UPDATES=false
# Or add to config file:
echo 'CHECK_CLAUDE_CONNECT_UPDATES=false' >> ~/.claude_launcher.conf
```

### Troubleshooting

#### Common Issues

**1. "Missing required dependencies"**
```bash
# Install missing tools
brew install gum jq curl  # macOS
sudo apt-get install gum jq curl  # Ubuntu
```

**2. "Claude Connect script not found"**
- Set `CLAUDE_CONNECT_SCRIPT` in configuration
- Or the script will prompt you when selecting OpenAI-compatible providers

**3. "Port already in use"**
- The script automatically finds alternative ports
- Check for running processes: `ps aux | grep claude_connect`

**4. "Invalid API key"**
- Verify environment variables are set
- Check API key validity and permissions

**5. "Cache issues"**
```bash
# Clear cache
rm -rf ~/.cache/claude_launcher/
```

#### Debug Mode

```bash
# Enable detailed logging
export LOG_LEVEL=DEBUG
./claude_launcher.sh -p openai --dry-run
```

#### Log Analysis

```bash
# View recent logs
tail -n 50 ~/.local/share/claude_launcher/logs/claude_launcher.log

# Follow logs in real-time
tail -f ~/.local/share/claude_launcher/logs/claude_launcher.log

# Filter errors
grep ERROR ~/.local/share/claude_launcher/logs/claude_launcher.log
```

## Development

### Testing

Run the test suite:

```bash
# Install BATS (if not already installed)
brew install bats-core  # macOS

# Run all tests
bats tests/

# Run specific test types
bats tests/unit/
bats tests/integration/

# Verbose output
bats -t tests/
```

### Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new functionality
5. Ensure all tests pass
6. Submit a pull request

## Security Considerations

- **Input Validation**: All user input is sanitized and validated
- **API Key Protection**: Keys are not logged or exposed in process lists
- **File Permissions**: Config files should have restrictive permissions (600)
- **Process Isolation**: Proxy processes run in separate sessions
- **Cleanup**: Robust cleanup prevents resource leaks

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Support

- **Issues**: [GitHub Issues](https://github.com/your-username/claude-launcher/issues)
- **Discussions**: [GitHub Discussions](https://github.com/your-username/claude-launcher/discussions)
- **Claude-Connect**: [drbarq/Claude-Connect](https://github.com/drbarq/Claude-Connect)

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history and changes.

---

**Note**: This script is not affiliated with Anthropic or the official Claude CLI. It's a community tool for enhancing Claude usage across multiple providers.