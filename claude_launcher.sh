#!/bin/bash

set -euo pipefail

# ============================================================================
# Claude Launcher - Multi-provider Claude CLI launcher
# Enhanced version with configuration file support
# ============================================================================

# Configuration file locations (in order of precedence)
readonly CONFIG_FILES=(
    "${CLAUDE_LAUNCHER_CONFIG:-}"
    "$HOME/.claude_launcher.conf"
    "$HOME/.config/claude_launcher/config"
    "/etc/claude_launcher.conf"
)

# Load configuration from file
load_config() {
    for config_file in "${CONFIG_FILES[@]}"; do
        if [[ -n "$config_file" && -f "$config_file" ]]; then
            echo "Loading configuration from: $config_file"
            # shellcheck source=/dev/null
            source "$config_file"
            return 0
        fi
    done
    return 1
}

# Load config if available (optional)
load_config || true

# Configuration constants (can be overridden by config file)
readonly SCRIPT_NAME="$(basename "$0")"
readonly CLAUDE_CONNECT_SCRIPT="${CLAUDE_CONNECT_SCRIPT:-/mnt/d/dev/tools/Claude-Connect/claude_connect.py}"
readonly OPENROUTER_CONFIG_URL="${OPENROUTER_CONFIG_URL:-https://raw.githubusercontent.com/charmbracelet/catwalk/main/internal/providers/configs/openrouter.json}"
readonly PROXY_PORT="${PROXY_PORT:-8080}"

# Default OpenRouter settings
readonly DEFAULT_OPENROUTER_BASE_URL="${OPENROUTER_BASE_URL:-https://openrouter.ai/api}"
readonly DEFAULT_ONLY_FREE="${OPENROUTER_MODELS_ONLY_FREE:-true}"
readonly DEFAULT_ONLY_REASONING="${OPENROUTER_MODELS_ONLY_REASONING:-true}"

# Z.ai configuration
readonly ZAI_BASE_URL="${ZAI_BASE_URL:-https://api.z.ai/api/anthropic}"
readonly ZAI_HAIKU_MODEL="${ZAI_HAIKU_MODEL:-glm-4.5-air}"
readonly ZAI_OPUS_MODEL="${ZAI_OPUS_MODEL:-glm-4.6}"
readonly ZAI_SONNET_MODEL="${ZAI_SONNET_MODEL:-glm-4.6}"

# UI preferences
readonly AUTO_SELECT_PROVIDER="${AUTO_SELECT_PROVIDER:-}"
readonly QUIET_MODE="${QUIET_MODE:-false}"

# ============================================================================
# Helper Functions
# ============================================================================

# Log function that respects quiet mode
log() {
    if [[ "$QUIET_MODE" != "true" ]]; then
        echo "$@"
    fi
}

# Log to stderr (always shown)
log_error() {
    echo "$@" >&2
}

# Print error message and exit
error_exit() {
    log_error "Error: $1"
    exit "${2:-1}"
}

# Print styled message using gum
styled_message() {
    local style="$1"
    local message="$2"
    
    if [[ "$QUIET_MODE" == "true" && "$style" != "error" ]]; then
        return
    fi
    
    case "$style" in
        error)
            gum style --foreground 196 --border-foreground 196 "$message"
            ;;
        info)
            gum style --foreground 33 "$message"
            ;;
        success)
            gum style --foreground 82 "$message"
            ;;
        warning)
            gum style --foreground 214 "$message"
            ;;
        *)
            echo "$message"
            ;;
    esac
}

# Check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Check if a process is running
process_running() {
    pgrep -f "$1" > /dev/null 2>&1
}

# Validate environment variable
require_env() {
    local var_name="$1"
    local var_value="${!var_name:-}"
    
    if [[ -z "$var_value" ]]; then
        error_exit "$var_name environment variable is not set"
    fi
}

# Cleanup function for trap
cleanup() {
    local exit_code=$?
    
    if [[ -n "${proxy_pid:-}" ]] && kill -0 "$proxy_pid" 2>/dev/null; then
        log "Stopping proxy server..."
        kill "$proxy_pid" 2>/dev/null || true
        wait "$proxy_pid" 2>/dev/null || true
    fi
    
    exit $exit_code
}

# ============================================================================
# Dependency Checks
# ============================================================================

check_dependencies() {
    local missing_deps=()
    
    if ! command_exists gum; then
        missing_deps+=("gum")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        cat <<EOF
Error: Missing required dependencies: ${missing_deps[*]}

Installation instructions:
  gum:
    macOS: brew install gum
    Linux: https://github.com/charmbracelet/gum#installation
EOF
        exit 1
    fi
}

check_optional_dependencies() {
    local warnings=()
    
    if ! command_exists jq; then
        warnings+=("jq (required for OpenRouter)")
    fi
    
    if ! command_exists curl; then
        warnings+=("curl (required for OpenRouter)")
    fi
    
    if ! command_exists python && ! command_exists python3; then
        warnings+=("python (required for OpenRouter)")
    fi
    
    if [[ ${#warnings[@]} -gt 0 ]]; then
        styled_message warning "Missing optional dependencies: ${warnings[*]}"
    fi
}

# ============================================================================
# Provider Functions
# ============================================================================

# Launch standard Claude
launch_claude_standard() {
    log "Starting Claude (standard)..."
    claude "$@"
}

# Launch Claude with Z.ai
launch_claude_zai() {
    require_env "ZAI_API_KEY"
    
    log "Starting Claude with Z.ai..."
    
    env ANTHROPIC_AUTH_TOKEN="$ZAI_API_KEY" \
        ANTHROPIC_BASE_URL="$ZAI_BASE_URL" \
        ANTHROPIC_DEFAULT_HAIKU_MODEL="$ZAI_HAIKU_MODEL" \
        ANTHROPIC_DEFAULT_OPUS_MODEL="$ZAI_OPUS_MODEL" \
        ANTHROPIC_DEFAULT_SONNET_MODEL="$ZAI_SONNET_MODEL" \
        claude "$@"
}

# Build jq filter for OpenRouter models
build_openrouter_filter() {
    local only_free="$1"
    local only_reasoning="$2"
    local filter='.models[]'
    
    if [[ "$only_free" == "true" ]]; then
        filter="$filter | select(.cost_per_1m_in == 0 and .cost_per_1m_out == 0 and .cost_per_1m_in_cached == 0 and .cost_per_1m_out_cached == 0)"
    fi
    
    if [[ "$only_reasoning" == "true" ]]; then
        filter="$filter | select(.can_reason == true)"
    fi
    
    echo "$filter | .id"
}

# Fetch OpenRouter models with caching
fetch_openrouter_models() {
    local filter="$1"
    local cache_file="/tmp/claude_launcher_models_cache"
    local cache_duration=3600  # 1 hour in seconds
    
    # Check cache
    if [[ -f "$cache_file" ]]; then
        local cache_age=$(($(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)))
        if [[ $cache_age -lt $cache_duration ]]; then
            log "Using cached model list..."
            cat "$cache_file" | jq -r "$filter"
            return
        fi
    fi
    
    log "Fetching available models..."
    
    if ! curl -sf "$OPENROUTER_CONFIG_URL" -o "$cache_file" 2>/dev/null; then
        # Try to use cache even if expired
        if [[ -f "$cache_file" ]]; then
            log_error "Warning: Failed to fetch fresh models, using cached data"
            cat "$cache_file" | jq -r "$filter"
            return
        fi
        error_exit "Failed to fetch models from OpenRouter config"
    fi
    
    cat "$cache_file" | jq -r "$filter"
}

# Check if Claude Connect proxy is available
check_claude_connect() {
    if [[ ! -f "$CLAUDE_CONNECT_SCRIPT" ]]; then
        error_exit "Claude Connect script not found at: $CLAUDE_CONNECT_SCRIPT"
    fi
    
    if ! command_exists python && ! command_exists python3; then
        error_exit "Python is not installed (required for Claude Connect)"
    fi
}

# Wait for port to be available
wait_for_port() {
    local port="$1"
    local max_attempts=30
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        # Use bash's /dev/tcp/ feature for portability (no nc required)
        if (exec 3<>/dev/tcp/localhost/"$port") 2>/dev/null; then
            exec 3>&-  # Close the connection
            return 0
        fi
        sleep 1
        ((attempt++))
    done
    
    return 1
}

# Start proxy server
start_proxy_server() {
    local base_url="$1"
    local api_key="$2"
    local model="$3"
    
    log "Starting proxy server on port $PROXY_PORT..."
    
    # Find python command
    local python_cmd
    if command_exists python; then
        python_cmd="python"
    elif command_exists python3; then
        python_cmd="python3"
    else
        error_exit "Python not found"
    fi
    
    OPENAI_BASE_URL="$base_url" \
    OPENAI_API_KEY="$api_key" \
    OPENAI_MODEL="$model" \
    "$python_cmd" "$CLAUDE_CONNECT_SCRIPT" &> /dev/null &
    
    local pid=$!
    
    # Wait for proxy to start
    if wait_for_port "$PROXY_PORT"; then
        log "Proxy server started successfully"
        echo "$pid"
    else
        kill "$pid" 2>/dev/null || true
        error_exit "Failed to start proxy server (timeout waiting for port $PROXY_PORT)"
    fi
}

# Launch Claude via OpenRouter
launch_claude_openrouter() {
    local base_url
    local api_key
    local models
    local model
    local jq_filter
    
    # Check dependencies
    check_claude_connect
    
    for cmd in jq curl; do
        if ! command_exists "$cmd"; then
            error_exit "$cmd is not installed (required for OpenRouter)"
        fi
    done
    
    # Check if proxy is already running
    if process_running "claude_connect.py"; then
        styled_message error "claude_connect.py is already running. Please stop it first."
        exit 1
    fi
    
    # Get configuration
    if [[ -n "${OPENROUTER_BASE_URL:-}" ]]; then
        base_url="$OPENROUTER_BASE_URL"
    else
        base_url=$(gum input \
            --placeholder "Enter OpenAI Base URL" \
            --value "$DEFAULT_OPENROUTER_BASE_URL") || exit 1
        
        if [[ -z "$base_url" ]]; then
            base_url="$DEFAULT_OPENROUTER_BASE_URL"
        fi
    fi
    
    # Get API key
    if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
        api_key="$OPENROUTER_API_KEY"
        log "Using OPENROUTER_API_KEY from environment"
    else
        api_key=$(gum input --password --placeholder "Enter API Key") || exit 1
        
        if [[ -z "$api_key" ]]; then
            error_exit "API key is required"
        fi
    fi
    
    # Build filter and fetch models
    jq_filter=$(build_openrouter_filter "$DEFAULT_ONLY_FREE" "$DEFAULT_ONLY_REASONING")
    models=$(fetch_openrouter_models "$jq_filter")
    
    if [[ -z "$models" ]]; then
        error_exit "No models found matching the specified filters"
    fi
    
    # Check for preferred models
    if [[ -n "${PREFERRED_MODELS:-}" ]]; then
        local preferred_found=""
        IFS=',' read -ra PREFERRED_ARRAY <<< "$PREFERRED_MODELS"
        for preferred in "${PREFERRED_ARRAY[@]}"; do
            if echo "$models" | grep -q "^${preferred}$"; then
                model="$preferred"
                log "Auto-selecting preferred model: $model"
                preferred_found="yes"
                break
            fi
        done
        
        if [[ -z "$preferred_found" ]]; then
            model=$(echo "$models" | gum choose) || exit 1
        fi
    else
        # Select model
        model=$(echo "$models" | gum choose) || exit 1
    fi
    
    if [[ -z "$model" ]]; then
        error_exit "No model selected"
    fi
    
    log "Selected model: $model"
    
    # Setup trap for cleanup
    trap cleanup EXIT INT TERM
    
    # Start proxy server
    proxy_pid=$(start_proxy_server "$base_url" "$api_key" "$model")
    
    # Launch Claude with proxy
    log "Starting Claude via OpenRouter (model: $model)..."
    ANTHROPIC_BASE_URL="http://localhost:$PROXY_PORT" claude --model "Openrouter $model" "$@"
}

# ============================================================================
# Main Function
# ============================================================================

show_help() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS] [-- CLAUDE_ARGS]

Multi-provider launcher for Claude CLI

Options:
  -p, --provider PROVIDER    Select provider (claude, zai, openrouter)
  -c, --config FILE          Use specific configuration file
  -q, --quiet                Quiet mode (minimal output)
  -h, --help                 Show this help message
  -v, --version              Show version information

Environment Variables:
  CLAUDE_LAUNCHER_CONFIG     Path to configuration file
  AUTO_SELECT_PROVIDER       Auto-select provider without menu
  QUIET_MODE                 Enable quiet mode
  OPENROUTER_API_KEY         OpenRouter API key
  ZAI_API_KEY               Z.ai API key

Examples:
  $SCRIPT_NAME                          # Interactive mode
  $SCRIPT_NAME -p claude                # Launch standard Claude
  $SCRIPT_NAME -p zai -- --model opus   # Launch Z.ai with model argument
  $SCRIPT_NAME -c ~/myconfig.conf       # Use custom config

Configuration Files (checked in order):
  \$CLAUDE_LAUNCHER_CONFIG
  ~/.claude_launcher.conf
  ~/.config/claude_launcher/config
  /etc/claude_launcher.conf
EOF
}

parse_arguments() {
    local provider=""
    local config_file=""
    local claude_args=()
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--provider)
                provider="$2"
                shift 2
                ;;
            -c|--config)
                config_file="$2"
                shift 2
                ;;
            -q|--quiet)
                QUIET_MODE="true"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                echo "Claude Launcher v2.0.0"
                exit 0
                ;;
            --)
                shift
                claude_args=("$@")
                break
                ;;
            *)
                echo "Unknown option: $1"
                echo "Use -h for help"
                exit 1
                ;;
        esac
    done
    
    # Load specific config if provided
    if [[ -n "$config_file" ]]; then
        if [[ -f "$config_file" ]]; then
            source "$config_file"
        else
            error_exit "Configuration file not found: $config_file"
        fi
    fi
    
    # Override with command line provider if specified
    if [[ -n "$provider" ]]; then
        AUTO_SELECT_PROVIDER="$provider"
    fi
    
    # Pass remaining arguments to Claude
    CLAUDE_ARGS=("${claude_args[@]}")
}

main() {
    local choice
    
    # Parse command line arguments
    parse_arguments "$@"
    
    # Check dependencies
    check_dependencies
    check_optional_dependencies
    
    # Auto-select provider if configured
    if [[ -n "$AUTO_SELECT_PROVIDER" ]]; then
        choice="$AUTO_SELECT_PROVIDER"
    else
        # Show menu and get choice
        choice=$(gum choose \
            "claude" \
            "zai" \
            "claude via openrouter" \
            "quit") || exit 0
    fi
    
    case "$choice" in
        "claude")
            launch_claude_standard "${CLAUDE_ARGS[@]}"
            ;;
        "zai")
            launch_claude_zai "${CLAUDE_ARGS[@]}"
            ;;
        "claude via openrouter"|"openrouter")
            launch_claude_openrouter "${CLAUDE_ARGS[@]}"
            ;;
        "quit")
            echo "Goodbye!"
            exit 0
            ;;
        *)
            error_exit "Invalid choice: $choice"
            ;;
    esac
}

# ============================================================================
# Entry Point
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi