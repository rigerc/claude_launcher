#!/usr/bin/env bash
#
# claude_launcher.sh - Multi-provider Claude CLI launcher
#
# Description: Launch Claude CLI with various providers and configurations,
#              including via proxy powered by Claude-Connect for OpenAI-compatible providers.
#              Provider and model data retrieved from https://models.dev/api.json
#
# Dependencies: gum, jq, curl, python/python3 (for Claude-Connect)
# Version: 3.0.0
# License: MIT

set -euo pipefail

# ============================================================================
# Script Metadata & Constants
# ============================================================================

readonly SCRIPT_NAME="claude_launcher"
readonly SCRIPT_VERSION="3.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_PID=$$

# ============================================================================
# Exit Codes
# ============================================================================

readonly E_SUCCESS=0
readonly E_GENERAL=1
readonly E_DEPENDENCY=2
readonly E_CONFIG=3
readonly E_NETWORK=4
readonly E_API=5
readonly E_USER_CANCEL=6
readonly E_PROXY=7

# ============================================================================
# Configuration File Locations (in order of precedence)
# ============================================================================

readonly CONFIG_FILES=(
    "${CLAUDE_LAUNCHER_CONFIG:-}"
    "${HOME}/.claude_launcher.conf"
    "${XDG_CONFIG_HOME:-${HOME}/.config}/claude_launcher/config"
    "${HOME}/.config/claude_launcher/config"
    "/etc/claude_launcher.conf"
)

# ============================================================================
# Cache & Runtime Directories
# ============================================================================

readonly CACHE_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/${SCRIPT_NAME}"
readonly RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}/${SCRIPT_NAME}_${USER}"
readonly API_CACHE="${CACHE_DIR}/models_dev_api.json"
readonly LOG_DIR="${HOME}/.local/share/${SCRIPT_NAME}/logs"

# Ensure directories exist
mkdir -p "${CACHE_DIR}" "${RUNTIME_DIR}" "${LOG_DIR}" 2>/dev/null || true

# ============================================================================
# Default Configuration Values (can be overridden by config file)
# ============================================================================

# Claude Connect script path
CLAUDE_CONNECT_SCRIPT="${CLAUDE_CONNECT_SCRIPT:-}"

# API settings
MODELS_DEV_API_URL="${MODELS_DEV_API_URL:-https://models.dev/api.json}"
CACHE_TTL="${CACHE_TTL:-3600}"  # 1 hour in seconds

# Proxy settings
PROXY_PORT="${PROXY_PORT:-8080}"
PROXY_STARTUP_TIMEOUT="${PROXY_STARTUP_TIMEOUT:-30}"
PROXY_HEALTH_CHECK_INTERVAL="${PROXY_HEALTH_CHECK_INTERVAL:-1}"

# Provider filter settings
PROVIDER_MODELS_ONLY_FREE="${PROVIDER_MODELS_ONLY_FREE:-true}"
PROVIDER_MODELS_ONLY_REASONING="${PROVIDER_MODELS_ONLY_REASONING:-true}"
PREFERRED_MODELS="${PREFERRED_MODELS:-}"

# Z.ai configuration
ZAI_BASE_URL="${ZAI_BASE_URL:-https://api.z.ai/api/anthropic}"
ZAI_HAIKU_MODEL="${ZAI_HAIKU_MODEL:-glm-4.5-air}"
ZAI_OPUS_MODEL="${ZAI_OPUS_MODEL:-glm-4.6}"
ZAI_SONNET_MODEL="${ZAI_SONNET_MODEL:-glm-4.6}"

# UI preferences
AUTO_SELECT_PROVIDER="${AUTO_SELECT_PROVIDER:-}"
QUIET_MODE="${QUIET_MODE:-false}"
DRY_RUN="${DRY_RUN:-false}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"  # DEBUG, INFO, WARN, ERROR

# Update checking
CHECK_CLAUDE_CONNECT_UPDATES="${CHECK_CLAUDE_CONNECT_UPDATES:-true}"  # Set to "false" to disable update checks

# ============================================================================
# Global State Variables
# ============================================================================

declare -g config_loaded=false
declare -g proxy_pid=""
declare -g proxy_port=""
declare -g cleanup_running=false
declare -a temp_files=()

# ============================================================================
# Logging Framework
# ============================================================================

# Log levels (numeric for comparison)
readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARN=2
readonly LOG_LEVEL_ERROR=3

# Current log level (set from config)
declare -g current_log_level="${LOG_LEVEL_INFO}"

# Convert log level name to numeric value
get_log_level_value() {
    local level="${1:-INFO}"
    case "${level^^}" in
        DEBUG) echo "${LOG_LEVEL_DEBUG}" ;;
        INFO)  echo "${LOG_LEVEL_INFO}" ;;
        WARN)  echo "${LOG_LEVEL_WARN}" ;;
        ERROR) echo "${LOG_LEVEL_ERROR}" ;;
        *)     echo "${LOG_LEVEL_INFO}" ;;
    esac
}

# Initialize log level from environment
current_log_level=$(get_log_level_value "${LOG_LEVEL}")

# Log file rotation
rotate_logs() {
    local log_file="${LOG_DIR}/${SCRIPT_NAME}.log"
    local max_size=$((10 * 1024 * 1024))  # 10MB

    if [[ -f "${log_file}" ]] && [[ $(stat -c%s "${log_file}" 2>/dev/null || echo 0) -gt ${max_size} ]]; then
        mv "${log_file}" "${log_file}.old" 2>/dev/null || true
    fi
}

# Core logging function
_log() {
    local level="$1"
    local level_value
    level_value=$(get_log_level_value "${level}")
    shift

    # Check if we should log this level
    if [[ ${level_value} -lt ${current_log_level} ]]; then
        return 0
    fi

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="$*"
    local log_entry="[${timestamp}] [${level}] ${message}"

    # Rotate logs if needed
    rotate_logs

    # Write to log file
    echo "${log_entry}" >> "${LOG_DIR}/${SCRIPT_NAME}.log" 2>/dev/null || true

    # Output to console based on quiet mode and level
    if [[ "${QUIET_MODE}" != "true" ]] || [[ "${level}" == "ERROR" ]]; then
        case "${level}" in
            ERROR)
                echo "${log_entry}" >&2
                ;;
            WARN)
                echo "${log_entry}" >&2
                ;;
            *)
                echo "${log_entry}"
                ;;
        esac
    fi
}

# Convenience logging functions
log_debug() { _log "DEBUG" "$@"; }
log_info()  { _log "INFO" "$@"; }
log_warn()  { _log "WARN" "$@"; }
log_error() { _log "ERROR" "$@"; }

# Styled messages using gum (when available and not quiet)
styled_message() {
    local style="$1"
    local message="$2"

    # Always show errors
    if [[ "${QUIET_MODE}" == "true" ]] && [[ "${style}" != "error" ]]; then
        return 0
    fi

    if ! command -v gum &>/dev/null; then
        echo "${message}"
        return 0
    fi

    case "${style}" in
        error)
            gum style --foreground 196 --border-foreground 196 "${message}"
            log_error "${message}"
            ;;
        info)
            gum style --foreground 33 "${message}"
            log_info "${message}"
            ;;
        success)
            gum style --foreground 82 "${message}"
            log_info "${message}"
            ;;
        warning)
            gum style --foreground 214 "${message}"
            log_warn "${message}"
            ;;
        *)
            echo "${message}"
            ;;
    esac
}

# ============================================================================
# Error Handling
# ============================================================================

# Print error and exit with code
die() {
    local exit_code="$1"
    shift
    log_error "$*"

    if command -v gum &>/dev/null && [[ "${QUIET_MODE}" != "true" ]]; then
        styled_message error "FATAL: $*"
    fi

    exit "${exit_code}"
}

# Cleanup function for trap
cleanup() {
    # Prevent cleanup from running multiple times
    if [[ "${cleanup_running}" == "true" ]]; then
        return 0
    fi
    cleanup_running=true

    # Disable further signal traps during cleanup to prevent recursion
    trap - EXIT INT TERM HUP QUIT ABRT

    # Preserve exit code before any operations
    local exit_code=$?

    log_debug "Running cleanup (exit code: ${exit_code})"

    # Stop proxy server if running
    if [[ -n "${proxy_pid}" ]] && is_valid_pid "${proxy_pid}"; then
        if kill -0 "${proxy_pid}" 2>/dev/null; then
            local cmd_line
            cmd_line=$(ps -p "${proxy_pid}" -o args= 2>/dev/null || echo "")

            if [[ "${cmd_line}" == *"claude_connect.py"* ]]; then
                log_info "Stopping proxy server (PID: ${proxy_pid})"
                terminate_process_safely "${proxy_pid}" 30 "proxy server"
            fi
        fi
    fi

    # Clean up leftover proxy processes
    cleanup_leftover_proxies_silent

    # Remove temporary files
    if [[ ${#temp_files[@]} -gt 0 ]]; then
        for temp_file in "${temp_files[@]}"; do
            [[ -f "${temp_file}" ]] && rm -f "${temp_file}" 2>/dev/null || true
        done
    fi

    # Clean up tracking files
    rm -f "${RUNTIME_DIR}/proxy.pid" \
          "${RUNTIME_DIR}/proxy.start" \
          "${RUNTIME_DIR}/proxy_info.txt" 2>/dev/null || true

    log_debug "Cleanup complete"

    exit "${exit_code}"
}

# ============================================================================
# Utility Functions
# ============================================================================

# Check if a command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Check if a process is running
process_running() {
    pgrep -f "$1" >/dev/null 2>&1
}

# Validate PID format and range
is_valid_pid() {
    local pid="$1"

    # Check if it's a number
    if ! [[ "${pid}" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    # Check if it's in valid range (PIDs are typically positive and < 4194304)
    if [[ ${pid} -lt 1 ]] || [[ ${pid} -gt 4194304 ]]; then
        return 1
    fi

    return 0
}

# Safely terminate a process with proper escalation
terminate_process_safely() {
    local pid="$1"
    local timeout="${2:-30}"
    local process_name="${3:-process}"

    if ! is_valid_pid "${pid}"; then
        log_warn "Invalid PID: ${pid}"
        return 1
    fi

    if ! kill -0 "${pid}" 2>/dev/null; then
        log_debug "${process_name} (PID: ${pid}) is not running"
        return 0
    fi

    log_info "Sending SIGTERM to ${process_name} (PID: ${pid})..."
    kill -TERM "${pid}" 2>/dev/null || return 0

    # Wait for graceful shutdown
    local count=0
    local interval=0.5
    local max_count=$((timeout * 2))

    while [[ ${count} -lt ${max_count} ]] && kill -0 "${pid}" 2>/dev/null; do
        sleep "${interval}"
        ((count++))

        # Progress indicator every 5 seconds
        if [[ $((count % 10)) -eq 0 ]] && [[ ${count} -gt 0 ]]; then
            log_debug "Waiting for ${process_name} to terminate... ($((count / 2))/${timeout}s)"
        fi
    done

    # Check if terminated
    if ! kill -0 "${pid}" 2>/dev/null; then
        log_info "${process_name} terminated gracefully"
        return 0
    fi

    # Force kill
    log_warn "Timeout expired, sending SIGKILL to ${process_name}..."
    kill -KILL "${pid}" 2>/dev/null || true
    sleep 1

    if kill -0 "${pid}" 2>/dev/null; then
        log_error "Failed to terminate ${process_name} (PID: ${pid})"
        return 1
    else
        log_info "${process_name} terminated (forced)"
        return 0
    fi
}

# Validate PID file integrity
validate_pid_file() {
    local pid_file="$1"
    local expected_command="$2"

    if [[ ! -f "${pid_file}" ]]; then
        return 1
    fi

    local pid
    pid=$(cat "${pid_file}" 2>/dev/null || echo "")

    # Validate PID format
    if ! is_valid_pid "${pid}"; then
        log_error "Invalid PID in file ${pid_file}: ${pid}"
        return 1
    fi

    # Check if process exists
    if ! kill -0 "${pid}" 2>/dev/null; then
        log_debug "Process ${pid} does not exist (stale PID file)"
        return 1
    fi

    # Verify command line
    local cmd_line
    cmd_line=$(ps -p "${pid}" -o args= 2>/dev/null || echo "")
    if [[ "${cmd_line}" != *"${expected_command}"* ]]; then
        log_warn "PID ${pid} is not ${expected_command}: ${cmd_line}"
        return 1
    fi

    return 0
}

# Check for running claude_connect.py processes
check_claude_connect_running() {
    # Check for tracked PID first
    local pid_file="${RUNTIME_DIR}/proxy.pid"

    if [[ -f "${pid_file}" ]]; then
        local pid
        pid=$(cat "${pid_file}" 2>/dev/null || echo "")

        if [[ -n "${pid}" ]] && is_valid_pid "${pid}" && kill -0 "${pid}" 2>/dev/null; then
            # Verify it's actually claude_connect.py
            local cmd_line
            cmd_line=$(ps -p "${pid}" -o args= 2>/dev/null || echo "")

            if [[ "${cmd_line}" == *"claude_connect.py"* ]]; then
                return 0
            else
                # Stale PID file - different process has this PID
                log_debug "Removing stale PID file (process ${pid} is not claude_connect.py)"
                rm -f "${pid_file}"
            fi
        fi
    fi

    # Fallback to process search
    pgrep -f "python.*claude_connect.py" >/dev/null 2>&1
}

# Cleanup leftover proxy processes (silent version for cleanup)
cleanup_leftover_proxies_silent() {
    local pid_file="${RUNTIME_DIR}/proxy.pid"

    if [[ -f "${pid_file}" ]]; then
        local old_pid
        old_pid=$(cat "${pid_file}" 2>/dev/null || echo "")

        if [[ -n "${old_pid}" ]] && is_valid_pid "${old_pid}"; then
            if kill -0 "${old_pid}" 2>/dev/null; then
                local cmd_line
                cmd_line=$(ps -p "${old_pid}" -o args= 2>/dev/null || echo "")

                if [[ "${cmd_line}" == *"claude_connect.py"* ]]; then
                    terminate_process_safely "${old_pid}" 10 "claude_connect.py" >/dev/null 2>&1 || true
                fi
            fi
        fi

        rm -f "${pid_file}" \
              "${RUNTIME_DIR}/proxy.start" \
              "${RUNTIME_DIR}/proxy_info.txt" 2>/dev/null || true
    fi

    # Clean up orphaned processes if pkill is available
    if command_exists pkill; then
        local pids
        pids=$(pgrep -f "python.*claude_connect.py" 2>/dev/null || echo "")

        if [[ -n "${pids}" ]]; then
            pkill -TERM -f "python.*claude_connect.py" 2>/dev/null || true
            sleep 2

            if pgrep -f "python.*claude_connect.py" >/dev/null 2>&1; then
                pkill -KILL -f "python.*claude_connect.py" 2>/dev/null || true
            fi
        fi
    fi
}

# Cleanup leftover proxy processes (verbose version)
cleanup_leftover_proxies() {
    local cleaned=false
    local pid_file="${RUNTIME_DIR}/proxy.pid"

    log_debug "Checking for leftover proxy processes..."

    if [[ -f "${pid_file}" ]]; then
        local old_pid
        old_pid=$(cat "${pid_file}" 2>/dev/null || echo "")

        if [[ -n "${old_pid}" ]] && is_valid_pid "${old_pid}"; then
            if kill -0 "${old_pid}" 2>/dev/null; then
                local cmd_line
                cmd_line=$(ps -p "${old_pid}" -o args= 2>/dev/null || echo "")

                if [[ "${cmd_line}" == *"claude_connect.py"* ]]; then
                    log_info "Found leftover proxy process (PID: ${old_pid}), cleaning up..."

                    if terminate_process_safely "${old_pid}" 10 "claude_connect.py"; then
                        cleaned=true
                    fi
                else
                    log_debug "PID ${old_pid} exists but is not claude_connect.py (PID reused)"
                fi
            fi
        fi

        rm -f "${pid_file}" \
              "${RUNTIME_DIR}/proxy.start" \
              "${RUNTIME_DIR}/proxy_info.txt" 2>/dev/null || true
    fi

    # Only use pkill if we didn't find a tracked process
    if [[ "${cleaned}" == "false" ]] && command_exists pkill; then
        local pids
        pids=$(pgrep -f "python.*claude_connect.py" 2>/dev/null || echo "")

        if [[ -n "${pids}" ]]; then
            log_info "Found orphaned claude_connect.py processes: ${pids}"
            pkill -TERM -f "python.*claude_connect.py" 2>/dev/null || true
            sleep 2

            if pgrep -f "python.*claude_connect.py" >/dev/null 2>&1; then
                log_warn "Forcing termination of orphaned processes..."
                pkill -KILL -f "python.*claude_connect.py" 2>/dev/null || true
            fi
        fi
    fi
}

# Sanitize string for safe use (remove potentially dangerous characters)
sanitize_string() {
    local input="$1"
    # Allow only alphanumeric, dash, underscore, dot, slash, colon, space
    echo "${input}" | LC_ALL=C sed 's/[^a-zA-Z0-9._/:@ -]//g'
}

# Validate URL format
is_valid_url() {
    local url="$1"
    [[ "${url}" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?(/.*)?$ ]]
}

# Validate environment variable exists and is not empty
require_env() {
    local var_name="$1"
    local var_value="${!var_name:-}"

    if [[ -z "${var_value}" ]]; then
        die "${E_CONFIG}" "${var_name} environment variable is not set"
    fi
}

# ============================================================================
# Dependency Checks
# ============================================================================

# Required dependencies
readonly -a REQUIRED_DEPS=(
    "gum"
    "jq"
    "curl"
)

check_dependencies() {
    log_debug "Checking required dependencies..."

    local missing_deps=()
    local dep

    for dep in "${REQUIRED_DEPS[@]}"; do
        if ! command_exists "${dep}"; then
            missing_deps+=("${dep}")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        cat >&2 <<EOF
Error: Missing required dependencies: ${missing_deps[*]}

Installation instructions:
  gum:
    macOS: brew install gum
    Linux: https://github.com/charmbracelet/gum#installation

  jq:
    macOS: brew install jq
    Linux: apt-get install jq / yum install jq

  curl:
    macOS: (pre-installed)
    Linux: apt-get install curl / yum install curl
EOF
        exit "${E_DEPENDENCY}"
    fi

    log_debug "All required dependencies present"
}

check_optional_dependencies() {
    log_debug "Checking optional dependencies..."

    local warnings=()

    if ! command_exists python && ! command_exists python3; then
        warnings+=("python (required for OpenRouter)")
    fi

    if [[ ${#warnings[@]} -gt 0 ]]; then
        log_warn "Missing optional dependencies: ${warnings[*]}"
    fi
}

# ============================================================================
# Configuration Management
# ============================================================================

# Load configuration from file
load_config() {
    log_debug "Loading configuration..."

    for config_file in "${CONFIG_FILES[@]}"; do
        if [[ -n "${config_file}" ]] && [[ -f "${config_file}" ]]; then
            log_info "Loading configuration from: ${config_file}"

            # Check file permissions (warn if too permissive)
            if [[ "$(uname)" != "Darwin" ]]; then
                local perms
                perms=$(stat -c %a "${config_file}" 2>/dev/null || echo "644")
                if [[ "${perms}" != "600" ]] && [[ "${perms}" != "400" ]]; then
                    log_warn "Config file ${config_file} has permissive permissions (${perms}). Consider: chmod 600 ${config_file}"
                fi
            fi

            # shellcheck source=/dev/null
            if ! source "${config_file}"; then
                log_error "Failed to source configuration file: ${config_file}"
                return 1
            fi

            config_loaded=true
            return 0
        fi
    done

    log_debug "No configuration file found (using defaults)"
    return 1
}

# Validate and sanitize configuration values
validate_config() {
    log_debug "Validating configuration..."

    # Validate cache TTL
    if ! [[ "${CACHE_TTL}" =~ ^[0-9]+$ ]] || [[ ${CACHE_TTL} -lt 0 ]]; then
        log_warn "Invalid CACHE_TTL value: ${CACHE_TTL}. Using default: 3600"
        CACHE_TTL=3600
    fi

    # Validate proxy port
    if ! [[ "${PROXY_PORT}" =~ ^[0-9]+$ ]] || [[ ${PROXY_PORT} -lt 1024 ]] || [[ ${PROXY_PORT} -gt 65535 ]]; then
        log_warn "Invalid PROXY_PORT value: ${PROXY_PORT}. Using default: 8080"
        PROXY_PORT=8080
    fi

    # Validate API URL if set
    if [[ -n "${MODELS_DEV_API_URL}" ]] && ! is_valid_url "${MODELS_DEV_API_URL}"; then
        log_warn "Invalid MODELS_DEV_API_URL: ${MODELS_DEV_API_URL}. Using default."
        MODELS_DEV_API_URL="https://models.dev/api.json"
    fi

    # Validate Z.ai Base URL
    if [[ -n "${ZAI_BASE_URL}" ]] && ! is_valid_url "${ZAI_BASE_URL}"; then
        log_warn "Invalid ZAI_BASE_URL: ${ZAI_BASE_URL}. Using default."
        ZAI_BASE_URL="https://api.z.ai/api/anthropic"
    fi

    # Update current log level
    current_log_level=$(get_log_level_value "${LOG_LEVEL}")

    log_debug "Configuration validation complete"
}

# ============================================================================
# API Data Management & Caching
# ============================================================================

# Check if cache is valid
is_cache_valid() {
    local cache_file="$1"
    local max_age="${2:-${CACHE_TTL}}"

    if [[ ! -f "${cache_file}" ]]; then
        log_debug "Cache file does not exist: ${cache_file}"
        return 1
    fi

    local file_age
    if [[ "$(uname)" == "Darwin" ]]; then
        file_age=$(( $(date +%s) - $(stat -f %m "${cache_file}" 2>/dev/null || echo 0) ))
    else
        file_age=$(( $(date +%s) - $(stat -c %Y "${cache_file}" 2>/dev/null || echo 0) ))
    fi

    if [[ ${file_age} -ge ${max_age} ]]; then
        log_debug "Cache expired (age: ${file_age}s, max: ${max_age}s)"
        return 1
    fi

    log_debug "Cache valid (age: ${file_age}s)"
    return 0
}

# Fetch API data from models.dev
fetch_api_data() {
    local temp_file="${CACHE_DIR}/api.tmp.${SCRIPT_PID}"
    temp_files+=("${temp_file}")

    log_info "Fetching API data from ${MODELS_DEV_API_URL}..."

    # Use timeout and follow redirects
    if ! curl --fail --silent --show-error \
              --max-time 30 \
              --location \
              --output "${temp_file}" \
              "${MODELS_DEV_API_URL}"; then
        rm -f "${temp_file}"

        # Try to use stale cache if available
        if [[ -f "${API_CACHE}" ]]; then
            log_warn "Failed to fetch API data, using stale cache"
            return 0
        fi

        die "${E_NETWORK}" "Failed to fetch API data from ${MODELS_DEV_API_URL}"
    fi

    # Validate JSON before accepting
    if ! jq empty "${temp_file}" 2>/dev/null; then
        rm -f "${temp_file}"

        # Try to use stale cache if available
        if [[ -f "${API_CACHE}" ]]; then
            log_warn "Invalid JSON received, using stale cache"
            return 0
        fi

        die "${E_API}" "Invalid JSON received from API"
    fi

    # Atomic move to cache location
    if ! mv "${temp_file}" "${API_CACHE}"; then
        rm -f "${temp_file}"
        die "${E_API}" "Failed to update API cache"
    fi

    log_info "API data cached successfully"
}

# Load API data (with caching)
load_api_data() {
    log_debug "Loading API data..."

    # Check cache validity
    if ! is_cache_valid "${API_CACHE}"; then
        fetch_api_data
    else
        log_debug "Using cached API data"
    fi

    # Verify cache exists after fetch
    if [[ ! -f "${API_CACHE}" ]]; then
        die "${E_API}" "API cache file not available"
    fi
}

# Get OpenAI-compatible providers with tool_call capable models
get_openai_compatible_providers() {
    local filter="$1"

    if [[ ! -f "${API_CACHE}" ]]; then
        die "${E_API}" "API cache not loaded. Call load_api_data first."
    fi

    local jq_filter
    case "${filter}" in
        "free")
            jq_filter='select(.value.tool_call == true and .value.cost.input == 0 and .value.cost.output == 0)'
            ;;
        "reasoning")
            jq_filter='select(.value.tool_call == true and .value.reasoning == true)'
            ;;
        *)
            jq_filter='select(.value.tool_call == true)'
            ;;
    esac

    jq --arg jq_filter "${jq_filter}" 'to_entries | map(
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
                '"${jq_filter}"' |
                {
                    id: .key,
                    name: .value.name,
                    reasoning: .value.reasoning,
                    cost: .value.cost
                }
            ]
        }
    ) | map(select(.models | length > 0)) | .[]' "${API_CACHE}"
}

# Get provider list for selection
get_provider_list() {
    local filter="$1"
    get_openai_compatible_providers "${filter}" | jq -r '"\(.name) (\(.api))"'
}

# Get models for a selected provider
get_provider_models() {
    local provider_name="$1"
    local filter="$2"

    get_openai_compatible_providers "${filter}" | \
        jq --arg provider_name "${provider_name}" \
           'select(.name == $provider_name) | .models[] | "\(.name) (\(.id))"'
}

# Get provider details by name
get_provider_details() {
    local provider_name="$1"
    local filter="$2"

    get_openai_compatible_providers "${filter}" | \
        jq --arg provider_name "${provider_name}" 'select(.name == $provider_name)'
}

# ============================================================================
# Claude Connect Management
# ============================================================================

# Save Claude Connect script path to configuration file
save_claude_connect_to_config() {
    local script_path="$1"
    local config_file="${HOME}/.claude_launcher.conf"

    log_info "Saving CLAUDE_CONNECT_SCRIPT to ${config_file}"

    # Create or update the config file
    if [[ -f "${config_file}" ]]; then
        # Check if CLAUDE_CONNECT_SCRIPT already exists in config
        if grep -q "^CLAUDE_CONNECT_SCRIPT=" "${config_file}" 2>/dev/null; then
            # Update existing line
            log_debug "Updating existing CLAUDE_CONNECT_SCRIPT in config"
            sed -i.tmp "s|^CLAUDE_CONNECT_SCRIPT=.*|CLAUDE_CONNECT_SCRIPT=\"${script_path}\"|g" "${config_file}"
        else
            # Add new line
            log_debug "Adding new CLAUDE_CONNECT_SCRIPT to config"
            echo "CLAUDE_CONNECT_SCRIPT=\"${script_path}\"" >> "${config_file}"
        fi
    else
        # Create new config file
        log_debug "Creating new config file with CLAUDE_CONNECT_SCRIPT"
        cat > "${config_file}" << EOF
# Claude Launcher Configuration
# Generated automatically by claude_launcher.sh

CLAUDE_CONNECT_SCRIPT="${script_path}"
EOF
    fi

    # Remove temporary file if it exists
    rm -f "${config_file}.tmp" 2>/dev/null || true

    # Set secure permissions
    chmod 600 "${config_file}" 2>/dev/null || true

    log_info "CLAUDE_CONNECT_SCRIPT saved to configuration file"
    styled_message success "Path saved! Future runs will use this automatically."
}

# Prompt user for Claude Connect script path
prompt_claude_connect_path() {
    echo
    styled_message warning "Claude Connect script not found at: ${CLAUDE_CONNECT_SCRIPT}"
    echo
    echo "Please enter the path to your claude_connect.py script from https://github.com/drbarq/Claude-Connect"
    echo "You can download it from: https://github.com/drbarq/Claude-Connect/"
    echo

    local new_path
    new_path=$(gum input --placeholder "Enter path to claude_connect.py") || exit "${E_USER_CANCEL}"

    if [[ -z "${new_path}" ]]; then
        die "${E_CONFIG}" "Path to claude_connect.py is required for OpenAI provider"
    fi

    # Convert to absolute path if relative
    if [[ "${new_path}" != /* ]]; then
        new_path="$(pwd)/${new_path}"
    fi

    # Check if the new path exists
    if [[ ! -f "${new_path}" ]]; then
        styled_message error "File not found at: ${new_path}"
        echo "Would you like to try again? (y/n)"

        local retry
        retry=$(gum choose "yes" "no") || exit "${E_USER_CANCEL}"

        if [[ "${retry}" == "yes" ]]; then
            prompt_claude_connect_path
            return
        else
            die "${E_CONFIG}" "Claude Connect script path is required for OpenAI provider"
        fi
    fi

    # Validate that it's a Python script
    if [[ "${new_path}" != *.py ]] && ! grep -q "python\|#!/usr/bin/env python" "${new_path}" 2>/dev/null; then
        styled_message warning "Warning: ${new_path} does not appear to be a Python script"
        echo "Continue anyway? (y/n)"

        local continue_anyway
        continue_anyway=$(gum choose "yes" "no") || exit "${E_USER_CANCEL}"

        if [[ "${continue_anyway}" != "yes" ]]; then
            prompt_claude_connect_path
            return
        fi
    fi

    # Update the variable
    CLAUDE_CONNECT_SCRIPT="${new_path}"

    # Export to environment so it's remembered for future runs
    export CLAUDE_CONNECT_SCRIPT="${CLAUDE_CONNECT_SCRIPT}"

    # Optionally save to config file for persistence
    # Only ask for confirmation if we have a proper TTY
    if [[ -t 0 ]] && command -v gum >/dev/null 2>&1; then
        if gum confirm "Save this path to your configuration file for future sessions?" --default=yes; then
            save_claude_connect_to_config "${CLAUDE_CONNECT_SCRIPT}"
        fi
    else
        # Automatically save if we can't ask for confirmation
        log_info "TTY not available, automatically saving to config"
        save_claude_connect_to_config "${CLAUDE_CONNECT_SCRIPT}"
    fi

    styled_message success "Using Claude Connect script: ${CLAUDE_CONNECT_SCRIPT}"
    log_info "CLAUDE_CONNECT_SCRIPT exported to environment for future use"
}

# Validate Claude Connect script
validate_claude_connect_script() {
    # Check if script already exists
    if [[ -f "${CLAUDE_CONNECT_SCRIPT}" ]]; then
        log_info "Found Claude Connect script: ${CLAUDE_CONNECT_SCRIPT}"
        return 0
    fi

    # If auto-selecting OpenRouter, we need the script now
    if [[ "${AUTO_SELECT_PROVIDER:-}" == "openrouter" ]] || \
       [[ "${AUTO_SELECT_PROVIDER:-}" == "claude via openrouter" ]] || \
       [[ "${AUTO_SELECT_PROVIDER:-}" == "claude via openai-compatible provider" ]]; then
        prompt_claude_connect_path
        return 0
    fi

    # In interactive mode, we can defer the check
    log_debug "Claude Connect script not found at: ${CLAUDE_CONNECT_SCRIPT}"
    log_debug "Will prompt for path if OpenAI provider is selected"
}

# Check for Claude Connect updates
check_claude_connect_updates() {
    local script_path="$1"
    local remote_url="https://raw.githubusercontent.com/drbarq/Claude-Connect/main/claude_connect.py"
    local cache_file="${CACHE_DIR}/claude_connect_remote_version"
    local max_age=86400  # 24 hours in seconds

    # Skip if we've checked recently
    if [[ -f "${cache_file}" ]] && is_cache_valid "${cache_file}" "${max_age}"; then
        return 0
    fi

    log_info "Checking for Claude Connect updates..."

    # Get remote file content hash (first 1KB for quick comparison)
    local remote_hash=""
    local remote_content
    remote_content=$(curl --silent --max-time 10 --connect-timeout 5 "${remote_url}" 2>/dev/null | \
                    head -c 1024) || remote_content=""

    if [[ -n "${remote_content}" ]]; then
        remote_hash=$(echo "${remote_content}" | md5sum 2>/dev/null | cut -d' ' -f1 || echo "")
    fi

    # Skip update check if we can't get remote info (network issues, etc.)
    if [[ -z "${remote_content}" ]] || [[ -z "${remote_hash}" ]]; then
        log_debug "Unable to check for Claude Connect updates (network issue or remote file not found)"
        # Cache a partial check to avoid repeated attempts
        echo "failed" > "${cache_file}"
        return 0
    fi

    # Get local file content hash (first 1KB for comparison)
    local local_hash=""
    if [[ -f "${script_path}" ]]; then
        local local_content
        local_content=$(head -c 1024 "${script_path}" 2>/dev/null) || local_content=""
        if [[ -n "${local_content}" ]]; then
            local_hash=$(echo "${local_content}" | md5sum 2>/dev/null | cut -d' ' -f1 || echo "")
        fi
    fi

    # Get local file modification time for display
    local local_timestamp=""
    if [[ -f "${script_path}" ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            local_timestamp=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "${script_path}" 2>/dev/null || echo "")
        else
            local_timestamp=$(stat -c "%y" "${script_path}" 2>/dev/null | \
                              cut -d. -f1 | \
                              sed 's/\.[0-9]*//' || echo "")
        fi
    fi

    # Compare hashes
    if [[ -n "${remote_hash}" ]] && [[ -n "${local_hash}" ]] && [[ "${remote_hash}" != "${local_hash}" ]]; then
        styled_message warning "⚠️  New version of claude_connect.py is available"
        if [[ -n "${local_timestamp}" ]]; then
            echo "   Your version: ${local_timestamp}"
        else
            echo "   Your version: Unknown"
        fi
        echo "   Update at: https://github.com/drbarq/Claude-Connect/blob/main/claude_connect.py"
        echo
    elif [[ -n "${remote_hash}" ]] && [[ -n "${local_hash}" ]] && [[ "${remote_hash}" == "${local_hash}" ]]; then
        log_debug "Claude Connect script is up to date"
    fi

    # Cache the check result
    echo "checked" > "${cache_file}"
}

# Check if Claude Connect is available
check_claude_connect() {
    # If script doesn't exist, prompt for it
    if [[ ! -f "${CLAUDE_CONNECT_SCRIPT}" ]]; then
        prompt_claude_connect_path
    fi

    if ! command_exists python && ! command_exists python3; then
        die "${E_DEPENDENCY}" "Python is not installed (required for Claude Connect)"
    fi

    # Check for updates (only if enabled and script exists)
    if [[ "${CHECK_CLAUDE_CONNECT_UPDATES}" == "true" ]] && [[ -f "${CLAUDE_CONNECT_SCRIPT}" ]]; then
        check_claude_connect_updates "${CLAUDE_CONNECT_SCRIPT}"
    fi
}

# ============================================================================
# Proxy Server Management
# ============================================================================

# Find available port
find_available_port() {
    local start_port="${1:-8000}"
    local end_port="${2:-9000}"
    local port

    for port in $(seq "${start_port}" "${end_port}"); do
        if ! (exec 3<>/dev/tcp/localhost/"${port}") 2>/dev/null; then
            echo "${port}"
            return 0
        else
            exec 3>&- 2>/dev/null || true
        fi
    done

    return 1
}

# Wait for port to be available
wait_for_port() {
    local port="$1"
    local log_file="$2"  # Optional: path to log file for debugging
    local max_attempts="${PROXY_STARTUP_TIMEOUT}"
    local attempt=0
    local interval="${PROXY_HEALTH_CHECK_INTERVAL}"

    log_info "Waiting for port ${port} to become available..."

    while [[ ${attempt} -lt ${max_attempts} ]]; do
        # Use bash's /dev/tcp/ feature for portability
        if (exec 3<>/dev/tcp/localhost/"${port}") 2>/dev/null; then
            exec 3>&-
            log_info "Port ${port} is ready after ${attempt} attempts (${attempt}s)"
            return 0
        fi

        # Show progress every 5 seconds
        if [[ $((attempt % 5)) -eq 0 ]] && [[ ${attempt} -gt 0 ]]; then
            log_debug "Still waiting for port ${port}... (${attempt}/${max_attempts})"
        fi

        sleep "${interval}"
        ((attempt++))
    done

    log_error "Timeout: Port ${port} did not become available after ${max_attempts} seconds"

    # Show last 5 lines of log for immediate debugging (cleanup will show more)
    if [[ -n "${log_file}" ]] && [[ -f "${log_file}" ]] && [[ -s "${log_file}" ]]; then
        log_error "Last 5 lines of proxy log (immediate debugging):"
        tail -n 5 "${log_file}" >&2
        log_error "Process cleanup will show full log details..."
    elif [[ -n "${log_file}" ]]; then
        log_error "Proxy log file exists but is empty or missing: ${log_file}"
    fi

    return 1
}

# Start proxy server
start_proxy_server() {
    local base_url="$1"
    local api_key="$2"
    local model="$3"

    log_info "Starting proxy server with model ID: ${model}"

    # Find python command
    local python_cmd
    if command_exists python; then
        python_cmd="python"
    elif command_exists python3; then
        python_cmd="python3"
    else
        die "${E_DEPENDENCY}" "Python not found"
    fi

    # Find available port if default is taken
    if (exec 3<>/dev/tcp/localhost/"${PROXY_PORT}") 2>/dev/null; then
        exec 3>&-
        log_warn "Port ${PROXY_PORT} is already in use, finding alternative..."

        proxy_port=$(find_available_port)
        if [[ -z "${proxy_port}" ]]; then
            die "${E_PROXY}" "No available ports found"
        fi

        log_info "Using alternative port: ${proxy_port}"
    else
        proxy_port="${PROXY_PORT}"
    fi

    # Create log file for proxy output
    local log_file="${LOG_DIR}/proxy.log"
    : > "${log_file}"  # Truncate log file

    # Store proxy info
    echo "${base_url}" > "${RUNTIME_DIR}/proxy_info.txt"

    # Start the proxy in a new process group
    # Use setsid to create new session and prevent SIGINT propagation
    (
        setsid env \
            OPENAI_BASE_URL="${base_url}" \
            OPENAI_API_KEY="${api_key}" \
            OPENAI_MODEL="${model}" \
            "${python_cmd}" "${CLAUDE_CONNECT_SCRIPT}" \
            >> "${log_file}" 2>&1 &
        echo $! > "${RUNTIME_DIR}/proxy.pid"
    )

    # Small delay to ensure PID file is written
    sleep 0.5

    local pid
    pid=$(cat "${RUNTIME_DIR}/proxy.pid" 2>/dev/null || echo "")

    if [[ -z "${pid}" ]] || ! is_valid_pid "${pid}"; then
        die "${E_PROXY}" "Failed to capture proxy process PID"
    fi

    # Store start timestamp
    date +%s > "${RUNTIME_DIR}/proxy.start"

    # Wait for proxy to start
    if wait_for_port "${proxy_port}" "${log_file}"; then
        proxy_pid="${pid}"
        log_info "Proxy server started successfully (PID: ${pid}, Port: ${proxy_port})"
        log_info "Proxy logs available at: ${log_file}"
        echo "${pid}"
    else
        # Cleanup on failure
        log_error "Failed to start proxy server (timeout waiting for port ${proxy_port})"

        if kill -0 "${pid}" 2>/dev/null; then
            log_info "Terminating failed proxy process..."
            kill -TERM "${pid}" 2>/dev/null || true
            sleep 2
            if kill -0 "${pid}" 2>/dev/null; then
                kill -KILL "${pid}" 2>/dev/null || true
            fi
        fi

        rm -f "${RUNTIME_DIR}/proxy.pid" "${RUNTIME_DIR}/proxy.start"

        # Show last few lines of log for debugging
        if [[ -f "${log_file}" ]] && [[ -s "${log_file}" ]]; then
            log_error "Last 10 lines of proxy log:"
            tail -n 10 "${log_file}" >&2
        else
            log_error "Proxy log file is empty or missing"
        fi

        die "${E_PROXY}" "Proxy server failed to start"
    fi
}

# ============================================================================
# Provider Launch Functions
# ============================================================================

# Launch standard Claude
launch_claude_standard() {
    log_info "Starting Claude (standard)..."
    claude "$@"
}

# Launch Claude with Z.ai
launch_claude_zai() {
    require_env "ZAI_API_KEY"

    log_info "Starting Claude with Z.ai..."

    env ANTHROPIC_AUTH_TOKEN="${ZAI_API_KEY}" \
        ANTHROPIC_BASE_URL="${ZAI_BASE_URL}" \
        ANTHROPIC_DEFAULT_HAIKU_MODEL="${ZAI_HAIKU_MODEL}" \
        ANTHROPIC_DEFAULT_OPUS_MODEL="${ZAI_OPUS_MODEL}" \
        ANTHROPIC_DEFAULT_SONNET_MODEL="${ZAI_SONNET_MODEL}" \
        claude "$@"
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

    # Check dependencies (skip for dry run)
    if [[ "${DRY_RUN}" != "true" ]]; then
        check_claude_connect

        # Check if proxy is already running
        if check_claude_connect_running; then
            styled_message error "claude_connect.py is already running. Please stop it first."
            exit "${E_PROXY}"
        fi
    fi

    # Determine filter based on settings
    filter=""
    if [[ "${PROVIDER_MODELS_ONLY_FREE}" == "true" ]]; then
        filter="free"
    elif [[ "${PROVIDER_MODELS_ONLY_REASONING}" == "true" ]]; then
        filter="reasoning"
    fi

    # Get available providers
    local provider_list
    provider_list=$(get_provider_list "${filter}")

    if [[ -z "${provider_list}" ]]; then
        die "${E_API}" "No providers found matching the specified filters"
    fi

    # Select provider
    provider_name=$(echo "${provider_list}" | gum choose --header "Select Provider") || exit "${E_USER_CANCEL}"

    if [[ -z "${provider_name}" ]]; then
        die "${E_USER_CANCEL}" "No provider selected"
    fi

    # Extract provider name (remove API URL from display)
    provider_name=$(echo "${provider_name}" | sed 's/ (.*//')
    provider_name=$(sanitize_string "${provider_name}")

    log_info "Selected provider: ${provider_name}"

    # Get provider details
    provider_details=$(get_provider_details "${provider_name}" "${filter}")

    if [[ -z "${provider_details}" ]]; then
        die "${E_API}" "Failed to get provider details"
    fi

    # Extract provider information
    base_url=$(echo "${provider_details}" | jq -r '.api')
    api_key_env=$(echo "${provider_details}" | jq -r '.env[0] // empty')

    # Validate base URL
    if ! is_valid_url "${base_url}"; then
        die "${E_CONFIG}" "Invalid base URL for provider: ${base_url}"
    fi

    # Get API key (skip for dry run)
    if [[ "${DRY_RUN}" != "true" ]]; then
        if [[ -n "${api_key_env}" ]] && [[ -n "${!api_key_env:-}" ]]; then
            api_key="${!api_key_env}"
            log_info "Using ${api_key_env} from environment"
        else
            local prompt="Enter API Key"
            if [[ -n "${api_key_env}" ]]; then
                prompt="Enter ${api_key_env}"
            fi

            api_key=$(gum input --password --placeholder "${prompt}") || exit "${E_USER_CANCEL}"

            if [[ -z "${api_key}" ]]; then
                die "${E_CONFIG}" "API key is required"
            fi
        fi
    else
        # For dry run, simulate API key
        api_key="********-****-****-****-************"
        if [[ -n "${api_key_env}" ]]; then
            log_info "Would use ${api_key_env} environment variable for API key"
        else
            log_info "Would prompt for API key"
        fi
    fi

    # Get available models for the provider
    models=$(get_provider_models "${provider_name}" "${filter}")

    if [[ -z "${models}" ]]; then
        die "${E_API}" "No models found for ${provider_name}"
    fi

    # Check for preferred models
    local model_selected=false
    if [[ -n "${PREFERRED_MODELS}" ]]; then
        IFS=',' read -ra PREFERRED_ARRAY <<< "${PREFERRED_MODELS}"
        for preferred in "${PREFERRED_ARRAY[@]}"; do
            if echo "${models}" | grep -q "${preferred}"; then
                model="${preferred}"
                log_info "Auto-selecting preferred model: ${model}"
                model_selected=true
                break
            fi
        done
    fi

    # Select model if not auto-selected
    if [[ "${model_selected}" == "false" ]]; then
        model=$(echo "${models}" | gum choose --header "Select Model") || exit "${E_USER_CANCEL}"
    fi

    if [[ -z "${model}" ]]; then
        die "${E_USER_CANCEL}" "No model selected"
    fi

    # Extract model ID (remove name from display)
    model_id=$(echo "${model}" | sed 's/.*(\(.*\))/\1/')

    log_info "Selected model: ${model} (ID: ${model_id})"

    # Display summary for dry run
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo
        styled_message info "Dry Run Summary:"
        echo "  Provider: ${provider_name}"
        echo "  API URL: ${base_url}"
        echo "  Model: ${model} (${model_id})"
        if [[ -n "${api_key_env}" ]]; then
            echo "  API Key: Would use environment variable ${api_key_env}"
        else
            echo "  API Key: Would prompt for input"
        fi
        echo "  Proxy Port: ${proxy_port}"
        echo
        echo "Command that would be executed:"
        echo "  ANTHROPIC_BASE_URL=\"http://localhost:${proxy_port}\" claude --model \"${provider_name} ${model}\" $*"
        return 0
    fi

    # Start proxy server (trap is already set)
    start_proxy_server "${base_url}" "${api_key}" "${model_id}"

    # Launch Claude with proxy
    log_info "Starting Claude via ${provider_name} (model: ${model})..."
    ANTHROPIC_BASE_URL="http://localhost:${proxy_port}" claude --model "${provider_name} ${model}" "$@"
}

# ============================================================================
# Main Function
# ============================================================================

show_help() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS] [-- CLAUDE_ARGS]

Multi-provider launcher for Claude CLI

Options:
  -p, --provider PROVIDER    Select provider (claude, zai, openai)
  -c, --config FILE          Use specific configuration file
  -q, --quiet                Quiet mode (minimal output)
      --dry-run              Test provider selection without launching Claude
      --log-level LEVEL      Set log level (DEBUG, INFO, WARN, ERROR)
  -h, --help                 Show this help message
  -v, --version              Show version information

Environment Variables:
  CLAUDE_LAUNCHER_CONFIG            Path to configuration file
  AUTO_SELECT_PROVIDER              Auto-select provider without menu
  QUIET_MODE                        Enable quiet mode (true/false)
  LOG_LEVEL                         Logging level (DEBUG, INFO, WARN, ERROR)
  ZAI_API_KEY                      Z.ai API key
  PREFERRED_MODELS                  Comma-separated list of preferred model names
  PROVIDER_MODELS_ONLY_FREE         Show only free models (true/false)
  PROVIDER_MODELS_ONLY_REASONING    Show only reasoning models (true/false)
  CACHE_TTL                         API cache TTL in seconds (default: 3600)

Provider API Keys:
  Each OpenAI-compatible provider requires its own API key.
  The script will prompt for the required key or use environment variables:
  - OPENAI_API_KEY          For OpenAI-compatible providers
  - ANTHROPIC_API_KEY       For Anthropic-compatible providers
  - GOOGLE_API_KEY          For Google AI providers

Examples:
  ${SCRIPT_NAME}                          # Interactive mode
  ${SCRIPT_NAME} -p claude                # Launch standard Claude
  ${SCRIPT_NAME} -p zai -- --model opus   # Launch Z.ai with model argument
  ${SCRIPT_NAME} -p openai                # Launch via OpenAI-compatible provider
  ${SCRIPT_NAME} -p openai --dry-run      # Test openai provider selection
  ${SCRIPT_NAME} --log-level DEBUG        # Enable debug logging

Configuration Files (checked in order):
  \$CLAUDE_LAUNCHER_CONFIG
  ~/.claude_launcher.conf
  \$XDG_CONFIG_HOME/claude_launcher/config
  ~/.config/claude_launcher/config
  /etc/claude_launcher.conf

Logs:
  Runtime logs: ${LOG_DIR}/${SCRIPT_NAME}.log
  Proxy logs:   ${LOG_DIR}/proxy.log
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
            --log-level)
                LOG_LEVEL="$2"
                current_log_level=$(get_log_level_value "${LOG_LEVEL}")
                shift 2
                ;;
            -h|--help)
                show_help
                exit "${E_SUCCESS}"
                ;;
            -v|--version)
                echo "Claude Launcher v${SCRIPT_VERSION}"
                exit "${E_SUCCESS}"
                ;;
            --)
                shift
                claude_args=("$@")
                break
                ;;
            *)
                echo "Unknown option: $1" >&2
                echo "Use -h for help" >&2
                exit "${E_GENERAL}"
                ;;
        esac
    done

    # Load specific config if provided
    if [[ -n "${config_file}" ]]; then
        if [[ -f "${config_file}" ]]; then
            # shellcheck source=/dev/null
            source "${config_file}"
        else
            die "${E_CONFIG}" "Configuration file not found: ${config_file}"
        fi
    fi

    # Override with command line provider if specified
    if [[ -n "${provider}" ]]; then
        AUTO_SELECT_PROVIDER="${provider}"
    fi

    # Return claude args
    printf '%s\n' "${claude_args[@]}"
}

main() {
    local choice
    local -a claude_args

    # Parse command line arguments
    mapfile -t claude_args < <(parse_arguments "$@")

    log_info "Claude Launcher v${SCRIPT_VERSION} starting..."

    # Load configuration
    load_config || true
    validate_config

    # Clean up any leftover proxy processes
    cleanup_leftover_proxies

    # Check dependencies
    check_dependencies
    check_optional_dependencies

    # Load API data
    load_api_data

    # Validate Claude Connect script path if using OpenAI
    validate_claude_connect_script

    # Auto-select provider if configured
    if [[ -n "${AUTO_SELECT_PROVIDER}" ]]; then
        choice="${AUTO_SELECT_PROVIDER}"
        log_info "Auto-selecting provider: ${choice}"
    else
        # Show menu and get choice
        choice=$(gum choose \
            "claude" \
            "zai" \
            "claude via openai-compatible provider" \
            "quit") || exit "${E_USER_CANCEL}"
    fi

    case "${choice}" in
        "claude")
            launch_claude_standard "${claude_args[@]}"
            ;;
        "zai")
            launch_claude_zai "${claude_args[@]}"
            ;;
        "claude via openai-compatible provider"|"openai"|"openrouter")
            launch_claude_openai_provider "${claude_args[@]}"
            ;;
        "quit")
            echo "Goodbye!"
            exit "${E_SUCCESS}"
            ;;
        *)
            die "${E_GENERAL}" "Invalid choice: ${choice}"
            ;;
    esac
}

# ============================================================================
# Entry Point
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ -z "${BASH_SOURCE_OVERRIDE:-}" ]]; then
    # Ensure cleanup happens even if script is interrupted
    trap cleanup EXIT INT TERM HUP QUIT ABRT
    main "$@"
fi
