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
CLAUDE_CONNECT_SCRIPT="${CLAUDE_CONNECT_SCRIPT:-/mnt/d/dev/tools/Claude-Connect/claude_connect.py}"
readonly MODELS_DEV_API_URL="${MODELS_DEV_API_URL:-https://models.dev/api.json}"
readonly PROXY_PORT="${PROXY_PORT:-8080}"

# Default provider settings
readonly DEFAULT_ONLY_FREE="${PROVIDER_MODELS_ONLY_FREE:-true}"
readonly DEFAULT_ONLY_REASONING="${PROVIDER_MODELS_ONLY_REASONING:-true}"

# Z.ai configuration
readonly ZAI_BASE_URL="${ZAI_BASE_URL:-https://api.z.ai/api/anthropic}"
readonly ZAI_HAIKU_MODEL="${ZAI_HAIKU_MODEL:-glm-4.5-air}"
readonly ZAI_OPUS_MODEL="${ZAI_OPUS_MODEL:-glm-4.6}"
readonly ZAI_SONNET_MODEL="${ZAI_SONNET_MODEL:-glm-4.6}"

# UI preferences
AUTO_SELECT_PROVIDER="${AUTO_SELECT_PROVIDER:-}"
readonly QUIET_MODE="${QUIET_MODE:-false}"
DRY_RUN="${DRY_RUN:-false}"

# ============================================================================
# Helper Functions
# ============================================================================

# Cleanup any leftover proxy processes from previous runs
cleanup_leftover_proxies() {
    local cleaned=false

    # Check if there's a stale proxy.pid file
    if [[ -f /tmp/claude_launcher_proxy.pid ]]; then
        local old_pid=$(cat /tmp/claude_launcher_proxy.pid 2>/dev/null || true)

        # Validate PID is not empty and is a valid number
        if [[ -n "$old_pid" ]] && is_valid_pid "$old_pid"; then
            # Check if process exists and is claude_connect.py
            if kill -0 "$old_pid" 2>/dev/null; then
                local cmd_line=$(ps -p "$old_pid" -o args= 2>/dev/null || true)
                if [[ "$cmd_line" == *"claude_connect.py"* ]]; then
                    log "Found leftover proxy process (PID: $old_pid), cleaning up..."

                    # Use our safe termination helper
                    if terminate_process_safely "$old_pid" 10 "claude_connect.py"; then
                        cleaned=true
                    fi
                else
                    log "PID $old_pid exists but is not claude_connect.py (PID reused)"
                fi
            fi
        fi

        # Clean up tracking files
        rm -f /tmp/claude_launcher_proxy.pid \
              /tmp/claude_launcher_proxy.start \
              /tmp/claude_launcher_proxy_info.txt
    fi

    # Only use pkill if we didn't find a tracked process
    # This prevents killing processes from other instances
    if [[ "$cleaned" == "false" ]] && command_exists pkill; then
        local pids=$(pgrep -f "python.*claude_connect.py" 2>/dev/null || true)
        if [[ -n "$pids" ]]; then
            log "Found orphaned claude_connect.py processes: $pids"
            # Use more specific pattern and proper signal escalation
            pkill -TERM -f "python.*claude_connect.py" 2>/dev/null || true
            sleep 2
            # Check if any still running and force kill
            if pgrep -f "python.*claude_connect.py" > /dev/null 2>&1; then
                log "Forcing termination of orphaned processes..."
                pkill -KILL -f "python.*claude_connect.py" 2>/dev/null || true
            fi
        fi
    fi
}

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

# Validate PID format and range
is_valid_pid() {
    local pid="$1"

    # Check if it's a number
    if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    # Check if it's in valid range (PIDs are typically positive and < 4194304)
    if [[ $pid -lt 1 || $pid -gt 4194304 ]]; then
        return 1
    fi

    return 0
}

# Safely terminate a process with proper escalation
terminate_process_safely() {
    local pid="$1"
    local timeout="${2:-30}"
    local process_name="${3:-process}"

    if ! kill -0 "$pid" 2>/dev/null; then
        log "$process_name (PID: $pid) is not running"
        return 0
    fi

    log "Sending SIGTERM to $process_name (PID: $pid)..."
    kill -TERM "$pid" 2>/dev/null || return 0

    # Wait for graceful shutdown
    local count=0
    local interval=0.5
    local max_count=$((timeout * 2))

    while [[ $count -lt $max_count ]] && kill -0 "$pid" 2>/dev/null; do
        sleep "$interval"
        ((count++))

        # Progress indicator every 5 seconds
        if [[ $((count % 10)) -eq 0 && $count -gt 0 ]]; then
            log "Still waiting for $process_name to terminate... ($((count / 2))/${timeout}s)"
        fi
    done

    # Check if terminated
    if ! kill -0 "$pid" 2>/dev/null; then
        log "$process_name terminated gracefully"
        return 0
    fi

    # Force kill
    log "Timeout expired, sending SIGKILL to $process_name..."
    kill -KILL "$pid" 2>/dev/null || true
    sleep 1

    if kill -0 "$pid" 2>/dev/null; then
        log_error "Failed to terminate $process_name (PID: $pid)"
        return 1
    else
        log "$process_name terminated (forced)"
        return 0
    fi
}

# Validate PID file integrity and process ownership
validate_pid_file() {
    local pid_file="$1"
    local expected_command="$2"

    if [[ ! -f "$pid_file" ]]; then
        return 1
    fi

    local pid=$(cat "$pid_file" 2>/dev/null || true)

    # Validate PID format
    if ! is_valid_pid "$pid"; then
        log_error "Invalid PID in file: $pid"
        return 1
    fi

    # Check if process exists
    if ! kill -0 "$pid" 2>/dev/null; then
        log "Process $pid does not exist (stale PID file)"
        return 1
    fi

    # Verify command line
    local cmd_line=$(ps -p "$pid" -o args= 2>/dev/null || true)
    if [[ "$cmd_line" != *"$expected_command"* ]]; then
        log_error "PID $pid is not $expected_command: $cmd_line"
        return 1
    fi

    return 0
}

# Enhanced check for claude_connect.py processes
check_claude_connect_running() {
    # Check for tracked PID first
    if [[ -f /tmp/claude_launcher_proxy.pid ]]; then
        local pid=$(cat /tmp/claude_launcher_proxy.pid 2>/dev/null || true)
        if [[ -n "$pid" ]] && is_valid_pid "$pid" && kill -0 "$pid" 2>/dev/null; then
            # Verify it's actually claude_connect.py
            local cmd_line=$(ps -p "$pid" -o args= 2>/dev/null || true)
            if [[ "$cmd_line" == *"claude_connect.py"* ]]; then
                return 0
            else
                # Stale PID file - different process has this PID
                log "Removing stale PID file (process $pid is not claude_connect.py)"
                rm -f /tmp/claude_launcher_proxy.pid
            fi
        fi
    fi

    # Fallback to process search
    pgrep -f "python.*claude_connect.py" > /dev/null 2>&1
}

# Validate environment variable
require_env() {
    local var_name="$1"
    local var_value="${!var_name:-}"

    if [[ -z "$var_value" ]]; then
        error_exit "$var_name environment variable is not set"
    fi
}

# Prompt user for Claude Connect script path
prompt_claude_connect_path() {
    echo
    styled_message warning "Claude Connect script not found at: $CLAUDE_CONNECT_SCRIPT"
    echo
    echo "Please enter the path to your claude_connect.py script from https://github.com/drbarq/Claude-Connect"
    echo "You can download it from: https://github.com/drbarq/Claude-Connect/blob/main/claude_connect.py"
    echo

    local new_path
    new_path=$(gum input --placeholder "Enter path to claude_connect.py") || exit 1

    if [[ -z "$new_path" ]]; then
        error_exit "Path to claude_connect.py is required for OpenRouter provider"
    fi

    # Convert to absolute path if relative
    if [[ "$new_path" != /* ]]; then
        new_path="$(pwd)/$new_path"
    fi

    # Check if the new path exists
    if [[ ! -f "$new_path" ]]; then
        styled_message error "File not found at: $new_path"
        echo "Would you like to try again? (y/n)"
        local retry
        retry=$(gum choose "yes" "no") || exit 1

        if [[ "$retry" == "yes" ]]; then
            prompt_claude_connect_path
            return
        else
            error_exit "Claude Connect script path is required for OpenRouter provider"
        fi
    fi

    # Validate that it's a Python script
    if [[ ! "$new_path" == *.py ]] && ! grep -q "python\|#!/usr/bin/env python" "$new_path" 2>/dev/null; then
        styled_message warning "Warning: $new_path does not appear to be a Python script"
        echo "Continue anyway? (y/n)"
        local continue_anyway
        continue_anyway=$(gum choose "yes" "no") || exit 1

        if [[ "$continue_anyway" != "yes" ]]; then
            prompt_claude_connect_path
            return
        fi
    fi

    # Update the global variable and make it readonly
    CLAUDE_CONNECT_SCRIPT="$new_path"
    readonly CLAUDE_CONNECT_SCRIPT
    styled_message success "Using Claude Connect script: $CLAUDE_CONNECT_SCRIPT"
}

# Validate Claude Connect script path and prompt if necessary
validate_claude_connect_script() {
    # Check if script already exists
    if [[ -f "$CLAUDE_CONNECT_SCRIPT" ]]; then
        log "Found Claude Connect script: $CLAUDE_CONNECT_SCRIPT"
        return 0
    fi

    # If auto-selecting OpenRouter, we need the script now
    if [[ "${AUTO_SELECT_PROVIDER:-}" == "openrouter" || "${AUTO_SELECT_PROVIDER:-}" == "claude via openrouter" ]]; then
        prompt_claude_connect_path
        return 0
    fi

    # In interactive mode, we can defer the check until OpenRouter is selected
    # Just make a note that we might need it later
    log "Claude Connect script not found at: $CLAUDE_CONNECT_SCRIPT"
    log "Will prompt for path if OpenRouter provider is selected"
}

# Cleanup function for trap
cleanup() {
    # Prevent cleanup from running multiple times
    if [[ "${_cleanup_running:-}" == "true" ]]; then
        return
    fi
    _cleanup_running="true"

    # Disable further signal traps during cleanup to prevent recursion
    trap - EXIT INT TERM HUP QUIT ABRT

    # Preserve exit code before any operations
    local exit_code=$?

    log "Stopping proxy server..."

    local pid_to_kill=""
    local found_process=false

    # Find the PID to kill - prefer tracked variable, then file
    if [[ -n "${proxy_pid:-}" ]]; then
        pid_to_kill="$proxy_pid"
    elif [[ -f /tmp/claude_launcher_proxy.pid ]]; then
        pid_to_kill=$(cat /tmp/claude_launcher_proxy.pid 2>/dev/null || true)
    fi

    # Try to kill the tracked process first
    if [[ -n "$pid_to_kill" ]] && is_valid_pid "$pid_to_kill"; then
        # Verify process exists and is correct before attempting cleanup
        if kill -0 "$pid_to_kill" 2>/dev/null; then
            local cmd_line=$(ps -p "$pid_to_kill" -o args= 2>/dev/null || true)
            if [[ "$cmd_line" == *"claude_connect.py"* ]]; then
                found_process=true
                # Use our safe termination helper with 30 second timeout
                if terminate_process_safely "$pid_to_kill" 30 "proxy server"; then
                    log "Proxy server stopped successfully"
                else
                    log_error "Warning: Failed to cleanly stop proxy server (PID: $pid_to_kill)"
                fi
            else
                log "PID $pid_to_kill is not claude_connect.py (PID reused), skipping"
            fi
        fi
    fi

    # If no tracked process was found, search for orphaned processes
    if [[ "$found_process" == "false" ]] && command_exists pkill; then
        if pgrep -f "python.*claude_connect.py" > /dev/null 2>&1; then
            log "Cleaning up untracked proxy processes..."
            # Use proper signal escalation
            pkill -TERM -f "python.*claude_connect.py" 2>/dev/null || true
            sleep 2

            # Check if any still running and force kill
            if pgrep -f "python.*claude_connect.py" > /dev/null 2>&1; then
                log "Forcing termination of remaining processes..."
                pkill -KILL -f "python.*claude_connect.py" 2>/dev/null || true
                sleep 1
            fi
            log "Untracked processes cleaned up"
        else
            log "No running proxy server found to stop"
        fi
    elif [[ "$found_process" == "false" ]]; then
        log "No running proxy server found to stop"
    fi

    # Clean up tracking files
    rm -f /tmp/claude_launcher_proxy.pid \
          /tmp/claude_launcher_proxy.start \
          /tmp/claude_launcher_proxy_info.txt

    exit "$exit_code"
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

# Get models for a selected provider
get_provider_models() {
    local provider_name="$1"
    local filter="$2"
    local providers

    providers=$(get_openai_compatible_providers "$filter")

    # Find the selected provider and return its models
    echo "$providers" | jq --arg provider_name "$provider_name" '
    select(.name == $provider_name) |
    .models[] |
    "\(.name) (\(.id))"
    '
}

# Get provider details by name
get_provider_details() {
    local provider_name="$1"
    local filter="$2"
    local providers

    providers=$(get_openai_compatible_providers "$filter")

    echo "$providers" | jq --arg provider_name "$provider_name" 'select(.name == $provider_name)'
}

# Fetch providers with caching
fetch_providers() {
    local cache_file="/tmp/claude_launcher_providers_cache"
    local cache_duration=3600  # 1 hour in seconds

    # Check cache
    if [[ -f "$cache_file" ]]; then
        local cache_age=$(($(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)))
        if [[ $cache_age -lt $cache_duration ]]; then
            [[ "$QUIET_MODE" != "true" ]] && log "Using cached provider list..." >&2
            cat "$cache_file"
            return
        fi
    fi

    [[ "$QUIET_MODE" != "true" ]] && log "Fetching available providers..." >&2

    if ! curl -sf "$MODELS_DEV_API_URL" -o "$cache_file" 2>/dev/null; then
        # Try to use cache even if expired
        if [[ -f "$cache_file" ]]; then
            log_error "Warning: Failed to fetch fresh providers, using cached data" >&2
            cat "$cache_file"
            return
        fi
        error_exit "Failed to fetch providers from models.dev API"
    fi

    cat "$cache_file"
}

# Get OpenAI-compatible providers with tool_call capable models
get_openai_compatible_providers() {
    local providers_data
    local filter="$1"

    providers_data=$(fetch_providers)

    if [[ "$filter" == "free" ]]; then
        # Filter for free models
        echo "$providers_data" | jq 'to_entries | map(
            select(.value.npm == "@ai-sdk/openai-compatible" or .value.npm == "@ai-sdk/openai") |
            {
                provider_key: .key,
                id: .value.id,
                name: .value.name,
                api: (.value.api | if (type == "string" and (endswith("/v1") or endswith("/v1/"))) then
                            if endswith("/v1/") then .[:-4] elif endswith("/v1") then .[:-3] else . end
                        else . end),
                env: .value.env,
                doc: .value.doc,
                models: [
                    .value.models | to_entries[] |
                    select(.value.tool_call == true and .value.cost.input == 0 and .value.cost.output == 0) |
                    {
                        id: .key,
                        name: .value.name,
                        reasoning: .value.reasoning,
                        cost: .value.cost
                    }
                ]
            }
        ) | map(select(.models | length > 0)) | .[]'
    elif [[ "$filter" == "reasoning" ]]; then
        # Filter for reasoning models
        echo "$providers_data" | jq 'to_entries | map(
            select(.value.npm == "@ai-sdk/openai-compatible" or .value.npm == "@ai-sdk/openai") |
            {
                provider_key: .key,
                id: .value.id,
                name: .value.name,
                api: (.value.api | if (type == "string" and (endswith("/v1") or endswith("/v1/"))) then
                            if endswith("/v1/") then .[:-4] elif endswith("/v1") then .[:-3] else . end
                        else . end),
                env: .value.env,
                doc: .value.doc,
                models: [
                    .value.models | to_entries[] |
                    select(.value.tool_call == true and .value.reasoning == true) |
                    {
                        id: .key,
                        name: .value.name,
                        reasoning: .value.reasoning,
                        cost: .value.cost
                    }
                ]
            }
        ) | map(select(.models | length > 0)) | .[]'
    else
        # No filter, get all tool_call models
        echo "$providers_data" | jq 'to_entries | map(
            select(.value.npm == "@ai-sdk/openai-compatible" or .value.npm == "@ai-sdk/openai") |
            {
                provider_key: .key,
                id: .value.id,
                name: .value.name,
                api: (.value.api | if (type == "string" and (endswith("/v1") or endswith("/v1/"))) then
                            if endswith("/v1/") then .[:-4] elif endswith("/v1") then .[:-3] else . end
                        else . end),
                env: .value.env,
                doc: .value.doc,
                models: [
                    .value.models | to_entries[] |
                    select(.value.tool_call == true) |
                    {
                        id: .key,
                        name: .value.name,
                        reasoning: .value.reasoning,
                        cost: .value.cost
                    }
                ]
            }
        ) | map(select(.models | length > 0)) | .[]'
    fi
}

# Get provider list for selection
get_provider_list() {
    local filter="$1"
    local providers

    providers=$(get_openai_compatible_providers "$filter")

    # Create list of provider names for selection
    echo "$providers" | jq -r '"\(.name) (\(.api))"'
}

# Check if Claude Connect proxy is available
check_claude_connect() {
    # If script doesn't exist, prompt for it
    if [[ ! -f "$CLAUDE_CONNECT_SCRIPT" ]]; then
        prompt_claude_connect_path
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

    log "Waiting for port $port to become available..."

    while [[ $attempt -lt $max_attempts ]]; do
        # Use bash's /dev/tcp/ feature for portability (no nc required)
        if (exec 3<>/dev/tcp/localhost/"$port") 2>/dev/null; then
            exec 3>&-  # Close the connection
            log "Port $port is ready after $attempt attempts ($attempt seconds)"
            return 0
        fi

        # Show progress every 5 seconds
        if [[ $((attempt % 5)) -eq 0 && $attempt -gt 0 ]]; then
            log "Still waiting for port $port... ($attempt/$max_attempts)"
        fi

        sleep 1
        ((attempt++))
    done

    log_error "Timeout: Port $port did not become available after $max_attempts seconds"
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

    # Create log file for proxy output
    local log_file="/tmp/claude_launcher_proxy.log"
    : > "$log_file"  # Truncate log file

    # Store proxy info in a temp file for better tracking
    echo "$base_url" > /tmp/claude_launcher_proxy_info.txt

    # Start the proxy in a new process group with output logging
    # Use setsid to create new session and prevent SIGINT propagation
    (
        setsid env \
            OPENAI_BASE_URL="$base_url" \
            OPENAI_API_KEY="$api_key" \
            OPENAI_MODEL="$model" \
            "$python_cmd" "$CLAUDE_CONNECT_SCRIPT" \
            >> "$log_file" 2>&1 &
        echo $! > /tmp/claude_launcher_proxy.pid
    )

    # Small delay to ensure PID file is written
    sleep 0.5

    local pid=$(cat /tmp/claude_launcher_proxy.pid 2>/dev/null || true)

    if [[ -z "$pid" ]] || ! is_valid_pid "$pid"; then
        error_exit "Failed to capture proxy process PID"
    fi

    # Store start timestamp
    echo "$(date +%s)" > /tmp/claude_launcher_proxy.start

    # Wait for proxy to start
    if wait_for_port "$PROXY_PORT"; then
        log "Proxy server started successfully (PID: $pid)"
        log "Proxy logs available at: $log_file"
        echo "$pid"
    else
        # Proper cleanup on failure
        log_error "Failed to start proxy server (timeout waiting for port $PROXY_PORT)"

        # Kill the process if it's still running
        if kill -0 "$pid" 2>/dev/null; then
            log "Terminating failed proxy process..."
            kill -TERM "$pid" 2>/dev/null || true
            sleep 2
            if kill -0 "$pid" 2>/dev/null; then
                kill -KILL "$pid" 2>/dev/null || true
            fi
        fi

        # Clean up tracking files
        rm -f /tmp/claude_launcher_proxy.pid /tmp/claude_launcher_proxy.start

        # Show last few lines of log for debugging
        if [[ -f "$log_file" && -s "$log_file" ]]; then
            log_error "Last 10 lines of proxy log:"
            tail -n 10 "$log_file" >&2
        else
            log_error "Proxy log file is empty or missing"
        fi

        error_exit "Proxy server failed to start"
    fi
}

# Launch Claude via OpenAI-compatible provider
launch_claude_openai_provider() {
    local provider_name
    local provider_details
    local base_url
    local api_key_env
    local api_key
    local models
    local model
    local model_id
    local filter

    # Check dependencies (only if not dry run)
    if [[ "$DRY_RUN" != "true" ]]; then
        check_claude_connect

        for cmd in jq curl; do
            if ! command_exists "$cmd"; then
                error_exit "$cmd is not installed (required for OpenAI-compatible providers)"
            fi
        done

        # Check if proxy is already running
        if check_claude_connect_running; then
            styled_message error "claude_connect.py is already running. Please stop it first."
            exit 1
        fi
    fi

    # Determine filter based on settings
    filter=""
    if [[ "$DEFAULT_ONLY_FREE" == "true" ]]; then
        filter="free"
    elif [[ "$DEFAULT_ONLY_REASONING" == "true" ]]; then
        filter="reasoning"
    fi

    # Get available providers
    local provider_list
    provider_list=$(get_provider_list "$filter")

    if [[ -z "$provider_list" ]]; then
        error_exit "No providers found matching the specified filters"
    fi

    # Select provider
    provider_name=$(echo "$provider_list" | gum choose) || exit 1

    if [[ -z "$provider_name" ]]; then
        error_exit "No provider selected"
    fi

    # Extract provider name (remove API URL from display)
    provider_name=$(echo "$provider_name" | sed 's/ (.*//')

    log "Selected provider: $provider_name"

    # Get provider details
    provider_details=$(get_provider_details "$provider_name" "$filter")

    if [[ -z "$provider_details" ]]; then
        error_exit "Failed to get provider details"
    fi

    # Extract provider information
    base_url=$(echo "$provider_details" | jq -r '.api')
    api_key_env=$(echo "$provider_details" | jq -r '.env[0] // empty')

    # Get API key (skip for dry run)
    if [[ "$DRY_RUN" != "true" ]]; then
        if [[ -n "$api_key_env" && -n "${!api_key_env:-}" ]]; then
            api_key="${!api_key_env}"
            log "Using $api_key_env from environment"
        else
            local prompt="Enter API Key"
            if [[ -n "$api_key_env" ]]; then
                prompt="Enter $api_key_env"
            fi
            api_key=$(gum input --password --placeholder "$prompt") || exit 1

            if [[ -z "$api_key" ]]; then
                error_exit "API key is required"
            fi
        fi
    else
        # For dry run, simulate API key
        api_key="********-****-****-****-************"
        if [[ -n "$api_key_env" ]]; then
            log "Would use $api_key_env environment variable for API key"
        else
            log "Would prompt for API key"
        fi
    fi

    # Get available models for the provider
    models=$(get_provider_models "$provider_name" "$filter")

    if [[ -z "$models" ]]; then
        error_exit "No models found for $provider_name"
    fi

    # Check for preferred models
    if [[ -n "${PREFERRED_MODELS:-}" ]]; then
        local preferred_found=""
        IFS=',' read -ra PREFERRED_ARRAY <<< "$PREFERRED_MODELS"
        for preferred in "${PREFERRED_ARRAY[@]}"; do
            if echo "$models" | grep -q "$preferred"; then
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

    # Extract model ID (remove name from display)
    model_id=$(echo "$model" | sed 's/.*(\(.*\))/\1/')

    log "Selected model: $model (ID: $model_id)"

    # Display summary for dry run
    if [[ "$DRY_RUN" == "true" ]]; then
        echo
        styled_message info "Dry Run Summary:"
        echo "  Provider: $provider_name"
        echo "  API URL: $base_url"
        echo "  Model: $model ($model_id)"
        if [[ -n "$api_key_env" ]]; then
            echo "  API Key: Would use environment variable $api_key_env"
        else
            echo "  API Key: Would prompt for input"
        fi
        echo "  Proxy Port: $PROXY_PORT"
        echo
        echo "Command that would be executed:"
        echo "  ANTHROPIC_BASE_URL=\"http://localhost:$PROXY_PORT\" claude --model \"$provider_name $model\" $*"
        return 0
    fi

    # Start proxy server (trap is already set in entry point)
    proxy_pid=$(start_proxy_server "$base_url" "$api_key" "$model_id")

    # Launch Claude with proxy
    log "Starting Claude via $provider_name (model: $model)..."
    ANTHROPIC_BASE_URL="http://localhost:$PROXY_PORT" claude --model "$provider_name $model" "$@"
}

# ============================================================================
# Main Function
# ============================================================================

show_help() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS] [-- CLAUDE_ARGS]

Multi-provider launcher for Claude CLI

Options:
  -p, --provider PROVIDER    Select provider (claude, zai, openai)
  -c, --config FILE          Use specific configuration file
  -q, --quiet                Quiet mode (minimal output)
      --dry-run              Test provider selection without launching Claude
  -h, --help                 Show this help message
  -v, --version              Show version information

Environment Variables:
  CLAUDE_LAUNCHER_CONFIG     Path to configuration file
  AUTO_SELECT_PROVIDER       Auto-select provider without menu
  QUIET_MODE                 Enable quiet mode
  ZAI_API_KEY               Z.ai API key
  PREFERRED_MODELS           Comma-separated list of preferred model names
  PROVIDER_MODELS_ONLY_FREE  Show only free models (default: true)
  PROVIDER_MODELS_ONLY_REASONING Show only reasoning models (default: true)

Provider API Keys:
  Each OpenAI-compatible provider requires its own API key.
  The script will prompt for the required key based on the selected provider.
  Common environment variables:
  - OPENAI_API_KEY           For OpenAI-compatible providers
  - ANTHROPIC_API_KEY        For Anthropic-compatible providers
  - GOOGLE_API_KEY          For Google AI providers
  And others depending on the provider.

Examples:
  $SCRIPT_NAME                          # Interactive mode
  $SCRIPT_NAME -p claude                # Launch standard Claude
  $SCRIPT_NAME -p zai -- --model opus   # Launch Z.ai with model argument
  $SCRIPT_NAME -p openai                # Launch via OpenAI-compatible provider
  $SCRIPT_NAME -p openai --dry-run      # Test openai provider selection
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
            --dry-run)
                DRY_RUN="true"
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

    # Clean up any leftover proxy processes from previous runs
    cleanup_leftover_proxies

    # Check dependencies
    check_dependencies
    check_optional_dependencies

    # Validate Claude Connect script path if using OpenRouter
    validate_claude_connect_script
    
    # Auto-select provider if configured
    if [[ -n "$AUTO_SELECT_PROVIDER" ]]; then
        choice="$AUTO_SELECT_PROVIDER"
    else
        # Show menu and get choice
        choice=$(gum choose \
            "claude" \
            "zai" \
            "claude via openai-compatible provider" \
            "quit") || exit 0
    fi

    case "$choice" in
        "claude")
            launch_claude_standard "${CLAUDE_ARGS[@]}"
            ;;
        "zai")
            launch_claude_zai "${CLAUDE_ARGS[@]}"
            ;;
        "claude via openai-compatible provider"|"openai"|"openrouter")
            launch_claude_openai_provider "${CLAUDE_ARGS[@]}"
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
    # Ensure cleanup happens even if script is interrupted
    # Our cleanup() function now preserves exit codes internally
    trap cleanup EXIT INT TERM HUP QUIT ABRT
    main "$@"
fi