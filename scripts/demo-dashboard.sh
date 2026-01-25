#!/bin/bash

# =============================================================================
# Demo Dashboard - Terminal-based Real-time Kubernetes Autoscaling Monitor
# =============================================================================
# A professional dashboard for monitoring vLLM autoscaling demos with KEDA
# and Karpenter. Displays load graphs, queue metrics, pod/node scaling status,
# and performance metrics in a clean, organized layout.
#
# Requirements: kubectl, jq (optional for JSON parsing)
# Usage: ./demo-dashboard.sh
# =============================================================================

# -----------------------------------------------------------------------------
# Color Constants and ANSI Escape Codes
# Requirements: 7.4 (consistent color coding)
# -----------------------------------------------------------------------------

# Reset
NC='\033[0m'           # No Color / Reset

# Standard Colors
BLACK='\033[0;30m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'

# Bold Colors
BOLD='\033[1m'
BOLD_RED='\033[1;31m'
BOLD_GREEN='\033[1;32m'
BOLD_YELLOW='\033[1;33m'
BOLD_BLUE='\033[1;34m'
BOLD_CYAN='\033[1;36m'
BOLD_WHITE='\033[1;37m'

# 256-Color Extended Palette (for status indicators)
COLOR_GOOD='\033[38;5;40m'       # Bright green
COLOR_WARNING='\033[38;5;226m'   # Bright yellow
COLOR_ERROR='\033[38;5;196m'     # Bright red
COLOR_INFO='\033[38;5;51m'       # Bright cyan
COLOR_MUTED='\033[38;5;245m'     # Gray

# Background Colors (for highlights)
BG_GREEN='\033[42m'
BG_YELLOW='\033[43m'
BG_RED='\033[41m'
BG_BLUE='\033[44m'

# Text Formatting
DIM='\033[2m'
UNDERLINE='\033[4m'
BLINK='\033[5m'
REVERSE='\033[7m'

# Cursor Control
CURSOR_HIDE='\033[?25l'
CURSOR_SHOW='\033[?25h'
CURSOR_HOME='\033[H'
CLEAR_SCREEN='\033[2J'
CLEAR_LINE='\033[2K'

# -----------------------------------------------------------------------------
# Configuration Variables
# Requirements: 6.1 (2-second refresh), 7.3 (80-column width)
# -----------------------------------------------------------------------------

# Refresh and Timing
REFRESH_INTERVAL=2               # Seconds between updates
STARTUP_RETRY_INTERVAL=5         # Seconds between connection retries

# Graph Dimensions
GRAPH_WIDTH=50                   # Width of ASCII graph in characters
GRAPH_HEIGHT=10                  # Height of ASCII graph in lines
MAX_HISTORY_SIZE=60              # Rolling window size for load history

# Terminal Layout
TERMINAL_WIDTH=80                # Maximum terminal width

# Kubernetes Configuration
VLLM_NAMESPACE="default"         # Namespace for vLLM deployment
VLLM_DEPLOYMENT="vllm"           # vLLM deployment name
VLLM_LABEL="app=vllm"            # Label selector for vLLM pods
NODE_LABEL="karpenter.sh/nodepool"  # Label for Karpenter-managed nodes
GPU_NODE_LABEL="workload=inference"  # Alternative label for GPU nodes

# -----------------------------------------------------------------------------
# Threshold Configuration
# Requirements: 2.3, 2.4 (scaling indicators), 5.5 (performance color coding)
# -----------------------------------------------------------------------------

# KEDA scaling thresholds
THRESHOLD_QUEUE_TARGET=1              # KEDA target value (triggers scaling)
THRESHOLD_QUEUE_SCALE_UP=5            # Queue depth indicating scale-up pressure
THRESHOLD_QUEUE_HIGH=20               # High queue depth (warning)
THRESHOLD_QUEUE_CRITICAL=50           # Critical queue depth (error)

# Response time thresholds (milliseconds)
THRESHOLD_RESPONSE_GOOD=500           # Response time considered good
THRESHOLD_RESPONSE_WARNING=1000       # Response time considered degraded
THRESHOLD_RESPONSE_CRITICAL=2000      # Response time considered poor

# Throughput thresholds (requests per second)
THRESHOLD_THROUGHPUT_LOW=1            # Low throughput threshold
THRESHOLD_THROUGHPUT_GOOD=10          # Good throughput threshold

# Load intensity thresholds (RPS)
THRESHOLD_LOAD_LOW=10                 # Low load
THRESHOLD_LOAD_MEDIUM=50              # Medium load
THRESHOLD_LOAD_HIGH=100               # High load

# -----------------------------------------------------------------------------
# Data Structure Arrays
# Requirements: 1.2 (rolling window), 6.5 (last known values)
# -----------------------------------------------------------------------------

# Load history for graph (rolling window of last 60 values)
LOAD_HISTORY=()
LOAD_TIMESTAMPS=()

# Current metrics (using individual variables for bash 3.2 compatibility)
METRIC_QUEUE_DEPTH=0
METRIC_PODS_RUNNING=0
METRIC_PODS_DESIRED=0
METRIC_PODS_READY=0
METRIC_NODES_COUNT=0
METRIC_NODE_TYPE="N/A"
METRIC_THROUGHPUT=0
METRIC_RESPONSE_P50=0
METRIC_RESPONSE_P95=0
METRIC_RESPONSE_P99=0
METRIC_RESPONSE_AVG=0
METRIC_SCALING_STATUS="stable"
METRIC_LAST_UPDATE=""
METRIC_CURRENT_RPS=0

# Last known good values (for stale data handling)
LAST_GOOD_QUEUE_DEPTH=0
LAST_GOOD_PODS_RUNNING=0
LAST_GOOD_PODS_DESIRED=0
LAST_GOOD_PODS_READY=0
LAST_GOOD_NODES_COUNT=0
LAST_GOOD_NODE_TYPE="N/A"
LAST_GOOD_THROUGHPUT=0

# RPS calculation state (track request count over time)
LAST_REQUEST_COUNT=0
LAST_REQUEST_TIME=0

# Stale indicators (true if data might be stale)
STALE_QUEUE_DEPTH=false
STALE_PODS=false
STALE_NODES=false
STALE_PERFORMANCE=false

# -----------------------------------------------------------------------------
# Display Configuration
# Requirements: 7.4 (consistent color coding)
# -----------------------------------------------------------------------------

DISPLAY_REFRESH_INTERVAL=$REFRESH_INTERVAL
DISPLAY_GRAPH_WIDTH=$GRAPH_WIDTH
DISPLAY_GRAPH_HEIGHT=$GRAPH_HEIGHT
DISPLAY_TERMINAL_WIDTH=$TERMINAL_WIDTH
DISPLAY_COLOR_GOOD="$COLOR_GOOD"
DISPLAY_COLOR_WARNING="$COLOR_WARNING"
DISPLAY_COLOR_ERROR="$COLOR_ERROR"
DISPLAY_COLOR_INFO="$COLOR_INFO"

# -----------------------------------------------------------------------------
# Runtime State
# -----------------------------------------------------------------------------

# Dashboard start time (for elapsed time calculation)
START_TIME=0

# Error log file
ERROR_LOG="/tmp/demo-dashboard.log"

# Flag to track if we should continue running
RUNNING=true

# -----------------------------------------------------------------------------
# Box Drawing Characters (for visual layout)
# Requirements: 7.2 (box-drawing characters)
# -----------------------------------------------------------------------------

BOX_TL='╔'    # Top-left corner
BOX_TR='╗'    # Top-right corner
BOX_BL='╚'    # Bottom-left corner
BOX_BR='╝'    # Bottom-right corner
BOX_H='═'     # Horizontal line
BOX_V='║'     # Vertical line
BOX_LT='╠'    # Left T-junction
BOX_RT='╣'    # Right T-junction
BOX_TT='╦'    # Top T-junction
BOX_BT='╩'    # Bottom T-junction
BOX_X='╬'     # Cross junction

# Light box characters (for inner sections)
BOX_L_TL='┌'
BOX_L_TR='┐'
BOX_L_BL='└'
BOX_L_BR='┘'
BOX_L_H='─'
BOX_L_V='│'

# Block characters for graphs
BLOCK_FULL='█'
BLOCK_LIGHT='░'
BLOCK_MEDIUM='▒'
BLOCK_DARK='▓'
BLOCK_UPPER='▀'
BLOCK_LOWER='▄'

# Status indicators
INDICATOR_UP='↑'
INDICATOR_DOWN='↓'
INDICATOR_STABLE='●'
INDICATOR_WARNING='⚠'
INDICATOR_CHECK='✓'
INDICATOR_CROSS='✗'

# Pod/Node visual representations
POD_ICON='●'
POD_EMPTY='○'
NODE_ICON='■'
NODE_EMPTY='□'

# =============================================================================
# STARTUP CHECKS AND ERROR HANDLING
# =============================================================================
# These functions verify prerequisites and handle errors gracefully.
# Requirements: 8.2 (prerequisite checks), 8.4 (error logging)
# =============================================================================

# -----------------------------------------------------------------------------
# Log error to file without disrupting display
# Requirements: 8.4
# Parameters:
#   $1 - Error message to log
# Side effects:
#   - Appends timestamped error message to ERROR_LOG file
#   - Creates log file if it doesn't exist
# -----------------------------------------------------------------------------
log_error() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $message" >> "$ERROR_LOG" 2>/dev/null
}

# -----------------------------------------------------------------------------
# Log info to file
# Requirements: 8.4
# Parameters:
#   $1 - Info message to log
# Side effects:
#   - Appends timestamped info message to ERROR_LOG file
# -----------------------------------------------------------------------------
log_info() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $message" >> "$ERROR_LOG" 2>/dev/null
}

# -----------------------------------------------------------------------------
# Log warning to file
# Requirements: 8.4
# Parameters:
#   $1 - Warning message to log
# Side effects:
#   - Appends timestamped warning message to ERROR_LOG file
# -----------------------------------------------------------------------------
log_warning() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $message" >> "$ERROR_LOG" 2>/dev/null
}

# -----------------------------------------------------------------------------
# Initialize error log file
# Requirements: 8.4
# Side effects:
#   - Creates or truncates the error log file
#   - Writes startup header to log
# -----------------------------------------------------------------------------
init_error_log() {
    # Create log directory if needed (for /tmp this is usually not necessary)
    local log_dir
    log_dir=$(dirname "$ERROR_LOG")
    if [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir" 2>/dev/null
    fi
    
    # Write startup header to log (append mode to preserve previous logs)
    echo "" >> "$ERROR_LOG" 2>/dev/null
    echo "============================================================" >> "$ERROR_LOG" 2>/dev/null
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Dashboard session started" >> "$ERROR_LOG" 2>/dev/null
    echo "============================================================" >> "$ERROR_LOG" 2>/dev/null
}

# -----------------------------------------------------------------------------
# check_kubectl_installed - Verify kubectl is installed
# Requirements: 8.2
# Returns: 0 if kubectl is installed, 1 otherwise
# Output: Prints error message to stderr on failure
# -----------------------------------------------------------------------------
check_kubectl_installed() {
    if ! command -v kubectl &>/dev/null; then
        echo -e "${COLOR_ERROR}Error: kubectl is not installed or not in PATH${NC}" >&2
        echo "" >&2
        echo "Please install kubectl to use this dashboard." >&2
        echo "Installation guide: https://kubernetes.io/docs/tasks/tools/" >&2
        log_error "Prerequisite check failed: kubectl not installed"
        return 1
    fi
    log_info "Prerequisite check passed: kubectl is installed"
    return 0
}

# -----------------------------------------------------------------------------
# check_cluster_connectivity - Verify Kubernetes cluster is reachable
# Requirements: 8.2
# Returns: 0 if cluster is reachable, 1 otherwise
# Output: Prints error message to stderr on failure
# -----------------------------------------------------------------------------
check_cluster_connectivity() {
    local cluster_info
    
    # Try to get cluster info with a timeout
    if ! cluster_info=$(kubectl cluster-info --request-timeout=5s 2>&1); then
        echo -e "${COLOR_ERROR}Error: Cannot connect to Kubernetes cluster${NC}" >&2
        echo "" >&2
        echo "Please ensure:" >&2
        echo "  1. Your kubeconfig is properly configured" >&2
        echo "  2. The cluster is running and accessible" >&2
        echo "  3. Your credentials are valid" >&2
        echo "" >&2
        echo "Try running: kubectl cluster-info" >&2
        log_error "Prerequisite check failed: Cannot connect to cluster - $cluster_info"
        return 1
    fi
    
    log_info "Prerequisite check passed: Cluster is reachable"
    return 0
}

# -----------------------------------------------------------------------------
# check_vllm_namespace - Verify vLLM namespace exists
# Requirements: 8.2
# Returns: 0 if namespace exists, 1 otherwise
# Output: Prints error message to stderr on failure
# -----------------------------------------------------------------------------
check_vllm_namespace() {
    local ns_check
    
    # Check if the vLLM namespace exists
    if ! ns_check=$(kubectl get namespace "$VLLM_NAMESPACE" --request-timeout=5s 2>&1); then
        echo -e "${COLOR_ERROR}Error: Namespace '${VLLM_NAMESPACE}' does not exist${NC}" >&2
        echo "" >&2
        echo "Please ensure the vLLM deployment is set up correctly." >&2
        echo "The dashboard expects the vLLM workload in namespace: ${VLLM_NAMESPACE}" >&2
        echo "" >&2
        echo "Try running: kubectl get namespaces" >&2
        log_error "Prerequisite check failed: Namespace '$VLLM_NAMESPACE' not found - $ns_check"
        return 1
    fi
    
    log_info "Prerequisite check passed: Namespace '$VLLM_NAMESPACE' exists"
    return 0
}

# -----------------------------------------------------------------------------
# check_vllm_deployment - Verify vLLM deployment exists (optional check)
# Requirements: 8.2
# Returns: 0 if deployment exists, 1 otherwise (warning only, not fatal)
# Output: Prints warning message to stderr if deployment not found
# -----------------------------------------------------------------------------
check_vllm_deployment() {
    local deploy_check
    
    # Check if the vLLM deployment exists
    if ! deploy_check=$(kubectl get deployment "$VLLM_DEPLOYMENT" -n "$VLLM_NAMESPACE" --request-timeout=5s 2>&1); then
        echo -e "${COLOR_WARNING}Warning: Deployment '${VLLM_DEPLOYMENT}' not found in namespace '${VLLM_NAMESPACE}'${NC}" >&2
        echo "The dashboard will start but may show N/A for some metrics." >&2
        echo "" >&2
        log_warning "Deployment '$VLLM_DEPLOYMENT' not found in namespace '$VLLM_NAMESPACE' - $deploy_check"
        # Return success - this is a warning, not a fatal error
        return 0
    fi
    
    log_info "Prerequisite check passed: Deployment '$VLLM_DEPLOYMENT' exists"
    return 0
}

# -----------------------------------------------------------------------------
# run_prerequisite_checks - Run all prerequisite checks
# Requirements: 8.2
# Returns: 0 if all required checks pass, 1 otherwise
# Output: Prints status messages and errors to stdout/stderr
# Side effects:
#   - Logs check results to error log
#   - May retry cluster connectivity on failure
# -----------------------------------------------------------------------------
run_prerequisite_checks() {
    echo -e "${BOLD_CYAN}Checking prerequisites...${NC}"
    echo ""
    
    # Check 1: kubectl installed (required)
    echo -n "  Checking kubectl... "
    if ! check_kubectl_installed; then
        return 1
    fi
    echo -e "${COLOR_GOOD}✓${NC}"
    
    # Check 2: Cluster connectivity (required)
    echo -n "  Checking cluster connectivity... "
    local retry_count=0
    local max_retries=3
    
    while ! check_cluster_connectivity; do
        retry_count=$((retry_count + 1))
        if [[ $retry_count -ge $max_retries ]]; then
            echo -e "${COLOR_ERROR}✗${NC}"
            echo "" >&2
            echo -e "${COLOR_ERROR}Failed to connect after $max_retries attempts.${NC}" >&2
            return 1
        fi
        echo -e "${COLOR_WARNING}Retrying ($retry_count/$max_retries)...${NC}"
        sleep "$STARTUP_RETRY_INTERVAL"
        echo -n "  Checking cluster connectivity... "
    done
    echo -e "${COLOR_GOOD}✓${NC}"
    
    # Check 3: vLLM namespace exists (required)
    echo -n "  Checking vLLM namespace... "
    if ! check_vllm_namespace; then
        echo -e "${COLOR_ERROR}✗${NC}"
        return 1
    fi
    echo -e "${COLOR_GOOD}✓${NC}"
    
    # Check 4: vLLM deployment exists (optional - warning only)
    echo -n "  Checking vLLM deployment... "
    if check_vllm_deployment; then
        echo -e "${COLOR_GOOD}✓${NC}"
    else
        echo -e "${COLOR_WARNING}⚠${NC} (will continue with warnings)"
    fi
    
    echo ""
    echo -e "${COLOR_GOOD}All prerequisite checks passed!${NC}"
    echo ""
    log_info "All prerequisite checks completed successfully"
    
    return 0
}

# =============================================================================
# DATA PROCESSING FUNCTIONS
# =============================================================================
# These functions transform raw metrics into displayable formats.
# =============================================================================

# -----------------------------------------------------------------------------
# add_to_load_history - Add a new value to the load history array
# Requirements: 1.2 (rolling window), 1.3 (update graph with latest value)
# Parameters:
#   $1 - The load value to add (numeric)
# Side effects:
#   - Appends value to LOAD_HISTORY array
#   - Appends current timestamp to LOAD_TIMESTAMPS array
#   - Removes oldest values if arrays exceed MAX_HISTORY_SIZE
# -----------------------------------------------------------------------------
add_to_load_history() {
    local value="$1"
    local timestamp
    timestamp=$(date '+%H:%M:%S')
    
    # Validate input - default to 0 if not numeric
    if ! [[ "$value" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        value=0
    fi
    
    # Add new value and timestamp to arrays
    LOAD_HISTORY+=("$value")
    LOAD_TIMESTAMPS+=("$timestamp")
    
    # Remove oldest values if we exceed MAX_HISTORY_SIZE
    while [[ ${#LOAD_HISTORY[@]} -gt $MAX_HISTORY_SIZE ]]; do
        # Remove first element (oldest)
        LOAD_HISTORY=("${LOAD_HISTORY[@]:1}")
        LOAD_TIMESTAMPS=("${LOAD_TIMESTAMPS[@]:1}")
    done
}

# -----------------------------------------------------------------------------
# determine_scaling_status - Determine scaling direction based on metrics
# Requirements: 2.3, 2.4 (queue scaling indicators), 3.4, 3.5 (pod scaling indicators)
# Parameters:
#   $1 - Metric type: "queue" or "pods"
#   $2 - Current value
#   $3 - Target/desired value
# Returns: "scaling_up", "scaling_down", or "stable"
# -----------------------------------------------------------------------------
determine_scaling_status() {
    local metric_type="$1"
    local current="$2"
    local target="$3"
    
    # Handle N/A or non-numeric values
    if [[ "$current" == "N/A" ]] || [[ "$target" == "N/A" ]]; then
        echo "stable"
        return 0
    fi
    
    # Ensure values are numeric
    if ! [[ "$current" =~ ^[0-9]+$ ]] || ! [[ "$target" =~ ^[0-9]+$ ]]; then
        echo "stable"
        return 0
    fi
    
    case "$metric_type" in
        "queue")
            # For queue depth: higher than target means scale-up pressure
            # Queue depth > target threshold indicates need for more pods
            if [[ $current -gt $target ]]; then
                echo "scaling_up"
            elif [[ $current -lt $target ]] && [[ $current -eq 0 ]]; then
                # Queue is empty, might scale down
                echo "scaling_down"
            else
                echo "stable"
            fi
            ;;
        "pods")
            # For pods: desired > running means scaling up
            # desired < running means scaling down
            if [[ $target -gt $current ]]; then
                echo "scaling_up"
            elif [[ $target -lt $current ]]; then
                echo "scaling_down"
            else
                echo "stable"
            fi
            ;;
        *)
            # Default comparison: target > current = scaling_up
            if [[ $target -gt $current ]]; then
                echo "scaling_up"
            elif [[ $target -lt $current ]]; then
                echo "scaling_down"
            else
                echo "stable"
            fi
            ;;
    esac
}

# -----------------------------------------------------------------------------
# determine_status_color - Return ANSI color code based on metric type and value
# Requirements: 1.5 (load intensity colors), 5.5 (performance color coding), 7.4 (consistent colors)
# Parameters:
#   $1 - Metric type: "queue", "response", "throughput", "load"
#   $2 - Numeric value
# Returns: ANSI color code string (always returns a valid color)
# -----------------------------------------------------------------------------
determine_status_color() {
    local metric_type="$1"
    local value="$2"
    
    # Handle N/A or non-numeric values - return info color
    if [[ "$value" == "N/A" ]] || [[ -z "$value" ]]; then
        echo "$COLOR_INFO"
        return 0
    fi
    
    # Strip any non-numeric characters for comparison
    local numeric_value
    numeric_value=$(echo "$value" | sed 's/[^0-9.]//g' | cut -d'.' -f1)
    
    # Default to 0 if still not numeric
    if ! [[ "$numeric_value" =~ ^[0-9]+$ ]]; then
        echo "$COLOR_INFO"
        return 0
    fi
    
    case "$metric_type" in
        "queue")
            # Queue depth: low is good, high is bad
            if [[ $numeric_value -ge $THRESHOLD_QUEUE_CRITICAL ]]; then
                echo "$COLOR_ERROR"
            elif [[ $numeric_value -ge $THRESHOLD_QUEUE_HIGH ]]; then
                echo "$COLOR_WARNING"
            elif [[ $numeric_value -ge $THRESHOLD_QUEUE_SCALE_UP ]]; then
                echo "$COLOR_WARNING"
            else
                echo "$COLOR_GOOD"
            fi
            ;;
        "response")
            # Response time: low is good, high is bad
            if [[ $numeric_value -ge $THRESHOLD_RESPONSE_CRITICAL ]]; then
                echo "$COLOR_ERROR"
            elif [[ $numeric_value -ge $THRESHOLD_RESPONSE_WARNING ]]; then
                echo "$COLOR_WARNING"
            elif [[ $numeric_value -ge $THRESHOLD_RESPONSE_GOOD ]]; then
                echo "$COLOR_WARNING"
            else
                echo "$COLOR_GOOD"
            fi
            ;;
        "throughput")
            # Throughput: high is good, low is bad
            if [[ $numeric_value -ge $THRESHOLD_THROUGHPUT_GOOD ]]; then
                echo "$COLOR_GOOD"
            elif [[ $numeric_value -ge $THRESHOLD_THROUGHPUT_LOW ]]; then
                echo "$COLOR_WARNING"
            else
                echo "$COLOR_ERROR"
            fi
            ;;
        "load")
            # Load intensity: informational coloring
            if [[ $numeric_value -ge $THRESHOLD_LOAD_HIGH ]]; then
                echo "$COLOR_ERROR"
            elif [[ $numeric_value -ge $THRESHOLD_LOAD_MEDIUM ]]; then
                echo "$COLOR_WARNING"
            elif [[ $numeric_value -ge $THRESHOLD_LOAD_LOW ]]; then
                echo "$COLOR_GOOD"
            else
                echo "$COLOR_INFO"
            fi
            ;;
        *)
            # Default: return info color for unknown metric types
            echo "$COLOR_INFO"
            ;;
    esac
}

# =============================================================================
# ASCII GRAPH RENDERING FUNCTIONS
# =============================================================================
# These functions generate ASCII-based visualizations for the dashboard.
# =============================================================================

# -----------------------------------------------------------------------------
# strip_ansi - Remove ANSI escape codes from a string
# Requirements: 7.3 (measuring printable character count)
# Parameters:
#   $1 - String potentially containing ANSI escape codes
# Returns: String with all ANSI escape codes removed
# -----------------------------------------------------------------------------
strip_ansi() {
    local input="$1"
    # Remove ANSI escape sequences: ESC[ followed by parameters and command character
    # Pattern: \033[ or \e[ followed by digits, semicolons, and ending with a letter
    echo "$input" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | sed 's/\033\[[0-9;]*[a-zA-Z]//g'
}

# -----------------------------------------------------------------------------
# build_ascii_graph - Generate ASCII area graph from load history data
# Requirements: 1.1 (ASCII-based line graph showing request load over time)
# Parameters:
#   None (uses global LOAD_HISTORY array)
# Output:
#   Prints GRAPH_HEIGHT lines of GRAPH_WIDTH characters to stdout
#   Each line represents a horizontal slice of the graph
# Notes:
#   - Graph is rendered top-to-bottom (highest values at top)
#   - Shows an AREA graph with filled bars and line on top
#   - Scales values to fit within GRAPH_HEIGHT
# -----------------------------------------------------------------------------
build_ascii_graph() {
    local -a history=("${LOAD_HISTORY[@]}")
    local width=$GRAPH_WIDTH
    local height=$GRAPH_HEIGHT
    local history_len=${#history[@]}
    
    # Find max value for scaling (minimum of 10 to have meaningful scale)
    local max_value=10
    for value in "${history[@]}"; do
        if [[ "$value" =~ ^[0-9]+\.?[0-9]*$ ]]; then
            local int_value=${value%.*}
            if [[ $int_value -gt $max_value ]]; then
                max_value=$int_value
            fi
        fi
    done
    
    # Pre-calculate the row for each data point (row = height of bar at this column)
    local -a row_for_col=()
    for (( col = 0; col < width; col++ )); do
        local value=0
        
        if [[ $history_len -eq 0 ]]; then
            row_for_col+=(0)  # No data - zero height
        elif [[ $history_len -ge $width ]]; then
            local history_index=$(( history_len - width + col ))
            value="${history[$history_index]}"
            if ! [[ "$value" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                value=0
            fi
            local int_value=${value%.*}
            # Calculate which row this value maps to (0 = no bar, height = full bar)
            local row=$(( (int_value * height) / max_value ))
            [[ $row -gt $height ]] && row=$height
            row_for_col+=($row)
        else
            local data_start=$(( width - history_len ))
            if [[ $col -lt $data_start ]]; then
                row_for_col+=(0)  # No data yet - zero height
            else
                local history_index=$(( col - data_start ))
                value="${history[$history_index]}"
                if ! [[ "$value" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                    value=0
                fi
                local int_value=${value%.*}
                local row=$(( (int_value * height) / max_value ))
                [[ $row -gt $height ]] && row=$height
                row_for_col+=($row)
            fi
        fi
    done
    
    # Build the graph line by line (top to bottom)
    # Use solid blocks for filled area chart with dot grid background
    local line
    for (( row = height; row >= 1; row-- )); do
        line=""
        for (( col = 0; col < width; col++ )); do
            local bar_height=${row_for_col[$col]}
            if [[ $bar_height -ge $row ]]; then
                # Fill the area under the curve with solid block
                line+="█"
            else
                # Empty space above the curve - use dots for grid
                line+="·"
            fi
        done
        echo "$line"
    done
}

# =============================================================================
# DATA COLLECTION FUNCTIONS
# =============================================================================
# These functions gather metrics from the Kubernetes cluster via kubectl.
# All functions handle failures gracefully by returning "N/A" on error.
# =============================================================================

# -----------------------------------------------------------------------------
# get_vllm_pods - Query vLLM deployment status
# Requirements: 3.1, 3.2, 3.3, 8.1
# Returns: running|desired|ready pipe-separated values, or "N/A|N/A|N/A" on failure
# -----------------------------------------------------------------------------
get_vllm_pods() {
    local deployment_info
    local running=0
    local desired=0
    local ready=0
    
    # Query deployment status using kubectl
    # Format: DESIRED READY UP-TO-DATE AVAILABLE
    deployment_info=$(kubectl get deployment "$VLLM_DEPLOYMENT" \
        -n "$VLLM_NAMESPACE" \
        -o jsonpath='{.spec.replicas}|{.status.readyReplicas}|{.status.availableReplicas}' \
        2>/dev/null)
    
    if [[ $? -ne 0 ]] || [[ -z "$deployment_info" ]]; then
        log_error "Failed to get vLLM deployment status"
        echo "N/A|N/A|N/A"
        return 1
    fi
    
    # Parse the pipe-separated values
    desired=$(echo "$deployment_info" | cut -d'|' -f1)
    ready=$(echo "$deployment_info" | cut -d'|' -f2)
    local available=$(echo "$deployment_info" | cut -d'|' -f3)
    
    # Handle null/empty values from jsonpath (when replicas are 0 or not set)
    [[ -z "$desired" ]] && desired=0
    [[ -z "$ready" ]] && ready=0
    [[ -z "$available" ]] && available=0
    
    # Get actual running pods count (pods in Running phase)
    running=$(kubectl get pods -n "$VLLM_NAMESPACE" \
        -l "$VLLM_LABEL" \
        --field-selector=status.phase=Running \
        -o name 2>/dev/null | wc -l | tr -d ' ')
    
    if [[ $? -ne 0 ]] || [[ -z "$running" ]]; then
        # Fall back to available count if pod query fails
        running=$available
    fi
    
    echo "${running}|${desired}|${ready}"
    return 0
}

# -----------------------------------------------------------------------------
# get_queue_depth - Query KEDA/HPA for current vLLM queue depth metric
# Requirements: 2.1, 8.1
# Returns: integer queue depth value, or "N/A" on failure
# -----------------------------------------------------------------------------
get_queue_depth() {
    local queue_depth=""
    
    # Method 1: Get directly from vLLM pod metrics (most reliable)
    # Select only READY pods (not just Running) to ensure we can query metrics
    local vllm_pod
    vllm_pod=$(kubectl get pods -n "$VLLM_NAMESPACE" \
        -l "$VLLM_LABEL" \
        -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{" "}{.metadata.name}{"\n"}{end}' \
        2>/dev/null | grep '^true ' | head -1 | awk '{print $2}')
    
    if [[ -n "$vllm_pod" ]]; then
        # Query the vLLM metrics endpoint (port 8000, not 8080)
        local metrics_output
        metrics_output=$(kubectl exec -n "$VLLM_NAMESPACE" "$vllm_pod" -- \
            curl -s http://localhost:8000/metrics 2>/dev/null)
        
        if [[ -n "$metrics_output" ]]; then
            # Try vllm:num_requests_waiting first (has labels like {engine="0",model_name="..."})
            # Extract the numeric value after the closing brace
            queue_depth=$(echo "$metrics_output" | \
                grep 'vllm:num_requests_waiting{' | \
                head -1 | \
                sed 's/.*} //' | \
                cut -d'.' -f1)
            
            if [[ -n "$queue_depth" ]] && [[ "$queue_depth" =~ ^[0-9]+$ ]]; then
                echo "$queue_depth"
                return 0
            fi
            
            # Try vllm:num_requests_running as fallback
            queue_depth=$(echo "$metrics_output" | \
                grep 'vllm:num_requests_running{' | \
                head -1 | \
                sed 's/.*} //' | \
                cut -d'.' -f1)
            
            if [[ -n "$queue_depth" ]] && [[ "$queue_depth" =~ ^[0-9]+$ ]]; then
                echo "$queue_depth"
                return 0
            fi
        fi
    fi
    
    # Method 2: Try HPA metrics
    local hpa_metrics
    hpa_metrics=$(kubectl get hpa "keda-hpa-vllm-queue-scaler" \
        -n "$VLLM_NAMESPACE" \
        -o jsonpath='{.status.currentMetrics[0].external.current.value}' \
        2>/dev/null)
    
    if [[ -n "$hpa_metrics" ]] && [[ "$hpa_metrics" != "null" ]]; then
        queue_depth=$(echo "$hpa_metrics" | sed 's/[^0-9.]//g' | cut -d'.' -f1)
        if [[ -n "$queue_depth" ]]; then
            echo "$queue_depth"
            return 0
        fi
    fi
    
    # Default to 0 if no metrics available (system is idle)
    echo "0"
    return 0
}

# -----------------------------------------------------------------------------
# get_node_info - Query kubectl for GPU nodes managed by Karpenter
# Requirements: 4.1, 4.2, 8.1
# Returns: node_count (just the count, simplified)
# -----------------------------------------------------------------------------
get_node_info() {
    local node_count=0
    
    # Query nodes with Karpenter nodepool label (gpu-inference)
    node_count=$(kubectl get nodes \
        -l "karpenter.sh/nodepool=gpu-inference" \
        -o name 2>/dev/null | wc -l | tr -d ' ')
    
    if [[ $node_count -eq 0 ]]; then
        # Try alternative label selector (intent=gpu-inference)
        node_count=$(kubectl get nodes \
            -l "intent=gpu-inference" \
            -o name 2>/dev/null | wc -l | tr -d ' ')
    fi
    
    if [[ $node_count -eq 0 ]]; then
        # Try with nvidia.com/gpu resource
        node_count=$(kubectl get nodes \
            -o jsonpath='{range .items[?(@.status.capacity.nvidia\.com/gpu)]}{.metadata.name}{"\n"}{end}' \
            2>/dev/null | grep -v '^$' | wc -l | tr -d ' ')
    fi
    
    echo "$node_count"
    return 0
}

# -----------------------------------------------------------------------------
# get_performance_metrics - Get throughput and response time metrics
# Requirements: 5.1, 5.2, 5.3, 5.4
# Returns: throughput|p50|p95|p99|avg pipe-separated values, or "N/A|N/A|N/A|N/A|N/A" on failure
# -----------------------------------------------------------------------------
get_performance_metrics() {
    local throughput="N/A"
    local p50="N/A"
    local p95="N/A"
    local p99="N/A"
    local avg="N/A"
    
    # Get a READY vLLM pod to query metrics (not just Running)
    local vllm_pod
    vllm_pod=$(kubectl get pods -n "$VLLM_NAMESPACE" \
        -l "$VLLM_LABEL" \
        -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{" "}{.metadata.name}{"\n"}{end}' \
        2>/dev/null | grep '^true ' | head -1 | awk '{print $2}')
    
    if [[ -z "$vllm_pod" ]]; then
        log_error "No running vLLM pods found for performance metrics"
        echo "N/A|N/A|N/A|N/A|N/A|N/A"
        return 1
    fi
    
    # Query the vLLM metrics endpoint (port 8000, not 8080)
    local metrics_output
    metrics_output=$(kubectl exec -n "$VLLM_NAMESPACE" "$vllm_pod" -- \
        curl -s http://localhost:8000/metrics 2>/dev/null)
    
    if [[ $? -ne 0 ]] || [[ -z "$metrics_output" ]]; then
        log_error "Failed to query vLLM metrics endpoint"
        echo "N/A|N/A|N/A|N/A|N/A|N/A"
        return 1
    fi
    
    # Get total request count from e2e_request_latency_seconds_count (for RPS calculation)
    local request_count
    request_count=$(echo "$metrics_output" | \
        grep 'vllm:e2e_request_latency_seconds_count{' | \
        head -1 | \
        sed 's/.*} //' | \
        cut -d'.' -f1)
    
    if [[ -z "$request_count" ]] || ! [[ "$request_count" =~ ^[0-9]+$ ]]; then
        request_count="0"
    fi
    
    # Parse response time from vllm:e2e_request_latency_seconds histogram
    # Get average latency (sum / count)
    local latency_sum
    local latency_count
    latency_sum=$(echo "$metrics_output" | \
        grep 'vllm:e2e_request_latency_seconds_sum{' | \
        head -1 | \
        sed 's/.*} //')
    
    latency_count=$(echo "$metrics_output" | \
        grep 'vllm:e2e_request_latency_seconds_count{' | \
        head -1 | \
        sed 's/.*} //')
    
    if [[ -n "$latency_sum" ]] && [[ -n "$latency_count" ]] && \
       [[ "$latency_count" != "0" ]] && [[ "$latency_count" != "0.0" ]]; then
        # Calculate average in milliseconds
        avg=$(echo "$latency_sum $latency_count" | awk '{
            if ($2 > 0) {
                printf "%.0f", ($1 / $2) * 1000
            } else {
                print "N/A"
            }
        }')
    fi
    
    # Try to parse time-to-first-token metrics
    local ttft
    ttft=$(echo "$metrics_output" | \
        grep 'vllm:time_to_first_token_seconds_sum{' | \
        head -1 | \
        sed 's/.*} //')
    
    local ttft_count
    ttft_count=$(echo "$metrics_output" | \
        grep 'vllm:time_to_first_token_seconds_count{' | \
        head -1 | \
        sed 's/.*} //')
    
    if [[ -n "$ttft" ]] && [[ -n "$ttft_count" ]] && \
       [[ "$ttft_count" != "0" ]] && [[ "$ttft_count" != "0.0" ]]; then
        # Use TTFT as p50 estimate (time to first token is typically faster than full response)
        p50=$(echo "$ttft $ttft_count" | awk '{
            if ($2 > 0) {
                printf "%.0f", ($1 / $2) * 1000
            } else {
                print "N/A"
            }
        }')
    fi
    
    # If we have average but not percentiles, estimate them
    if [[ "$avg" != "N/A" ]] && [[ "$p50" == "N/A" ]]; then
        # Rough estimates: p50 ≈ avg * 0.8, p95 ≈ avg * 1.5, p99 ≈ avg * 2.0
        p50=$(echo "$avg" | awk '{printf "%.0f", $1 * 0.8}')
        p95=$(echo "$avg" | awk '{printf "%.0f", $1 * 1.5}')
        p99=$(echo "$avg" | awk '{printf "%.0f", $1 * 2.0}')
    elif [[ "$p50" != "N/A" ]] && [[ "$avg" != "N/A" ]]; then
        # If we have p50 and avg, estimate p95 and p99
        p95=$(echo "$avg" | awk '{printf "%.0f", $1 * 1.5}')
        p99=$(echo "$avg" | awk '{printf "%.0f", $1 * 2.0}')
    fi
    
    # Return: throughput(placeholder)|p50|p95|p99|avg|request_count
    # RPS calculation happens in collect_all_metrics where we can track state
    echo "0|${p50}|${p95}|${p99}|${avg}|${request_count}"
    return 0
}

# =============================================================================
# DISPLAY RENDERER FUNCTIONS
# =============================================================================
# These functions handle all terminal output and visual formatting.
# Each function renders a specific section of the dashboard.
# =============================================================================

# -----------------------------------------------------------------------------
# get_elapsed_time - Calculate elapsed time since dashboard started
# Requirements: 6.4 (elapsed time display)
# Returns: Formatted elapsed time string (HH:MM:SS)
# -----------------------------------------------------------------------------
get_elapsed_time() {
    local current_time
    current_time=$(date +%s)
    local elapsed=$((current_time - START_TIME))
    
    local hours=$((elapsed / 3600))
    local minutes=$(((elapsed % 3600) / 60))
    local seconds=$((elapsed % 60))
    
    printf "%02d:%02d:%02d" "$hours" "$minutes" "$seconds"
}

# -----------------------------------------------------------------------------
# render_header - Display dashboard title with box-drawing characters
# Requirements: 7.2 (box-drawing characters), 7.5 (header with demo title),
#               6.3 (timestamp), 6.4 (elapsed time)
# Output: Renders header section to stdout (fits within 80 columns)
# -----------------------------------------------------------------------------
render_header() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local elapsed
    elapsed=$(get_elapsed_time)
    
    local title="vLLM Autoscaling Demo Dashboard"
    local subtitle="KEDA + Karpenter on Amazon EKS"
    local title_len=${#title}
    local subtitle_len=${#subtitle}
    
    # Calculate padding for centering (80 - 2 borders = 78 inner width)
    local inner_width=78
    local title_padding=$(( (inner_width - title_len) / 2 ))
    local subtitle_padding=$(( (inner_width - subtitle_len) / 2 ))
    
    # Top border
    printf "${BOLD_CYAN}${BOX_TL}"
    for ((i=0; i<inner_width; i++)); do printf "${BOX_H}"; done
    printf "${BOX_TR}${NC}\n"
    
    # Title line (centered)
    printf "${BOLD_CYAN}${BOX_V}${NC}"
    printf "%*s" "$title_padding" ""
    printf "${BOLD_WHITE}%s${NC}" "$title"
    printf "%*s" "$((inner_width - title_padding - title_len))" ""
    printf "${BOLD_CYAN}${BOX_V}${NC}\n"
    
    # Subtitle line (centered)
    printf "${BOLD_CYAN}${BOX_V}${NC}"
    printf "%*s" "$subtitle_padding" ""
    printf "${COLOR_INFO}%s${NC}" "$subtitle"
    printf "%*s" "$((inner_width - subtitle_padding - subtitle_len))" ""
    printf "${BOLD_CYAN}${BOX_V}${NC}\n"
    
    # Separator line
    printf "${BOLD_CYAN}${BOX_LT}"
    for ((i=0; i<inner_width; i++)); do printf "${BOX_H}"; done
    printf "${BOX_RT}${NC}\n"
    
    # Timestamp and elapsed time line
    local time_info="Time: ${timestamp}  |  Elapsed: ${elapsed}"
    local time_len=${#time_info}
    local time_padding=$(( (inner_width - time_len) / 2 ))
    
    printf "${BOLD_CYAN}${BOX_V}${NC}"
    printf "%*s" "$time_padding" ""
    printf "${COLOR_MUTED}%s${NC}" "$time_info"
    printf "%*s" "$((inner_width - time_padding - time_len))" ""
    printf "${BOLD_CYAN}${BOX_V}${NC}\n"
    
    # Bottom border
    printf "${BOLD_CYAN}${BOX_BL}"
    for ((i=0; i<inner_width; i++)); do printf "${BOX_H}"; done
    printf "${BOX_BR}${NC}\n"
}

# -----------------------------------------------------------------------------
# render_load_section - Display ASCII load graph with current RPS
# Requirements: 1.1 (ASCII load graph), 1.4 (current RPS), 1.5 (load intensity)
# Output: Renders load visualization section to stdout
# -----------------------------------------------------------------------------
render_load_section() {
    local current_rps="${METRIC_CURRENT_RPS:-0}"
    local load_color
    load_color=$(determine_status_color "load" "$current_rps")
    
    # Determine load intensity label
    local intensity_label="LOW"
    if [[ "$current_rps" =~ ^[0-9]+$ ]]; then
        if [[ $current_rps -ge $THRESHOLD_LOAD_HIGH ]]; then
            intensity_label="HIGH"
        elif [[ $current_rps -ge $THRESHOLD_LOAD_MEDIUM ]]; then
            intensity_label="MEDIUM"
        elif [[ $current_rps -ge $THRESHOLD_LOAD_LOW ]]; then
            intensity_label="LOW"
        else
            intensity_label="IDLE"
        fi
    fi
    
    # Section header (78 inner + 2 borders = 80)
    printf "${BOLD_CYAN}${BOX_L_TL}${BOX_L_H}${NC}${BOLD_WHITE} Load Graph ${NC}${BOLD_CYAN}"
    for ((i=0; i<65; i++)); do printf "${BOX_L_H}"; done
    printf "${BOX_L_TR}${NC}\n"
    
    # Render the ASCII graph
    local graph_output
    graph_output=$(build_ascii_graph)
    
    # Display graph with left border (50 graph chars + padding to 78)
    while IFS= read -r line; do
        printf "${BOLD_CYAN}${BOX_L_V}${NC}${COLOR_INFO}%s${NC}" "$line"
        printf "%*s" "28" ""
        printf "${BOLD_CYAN}${BOX_L_V}${NC}\n"
    done <<< "$graph_output"
    
    # RPS and intensity line (fit in 78 chars)
    printf "${BOLD_CYAN}${BOX_L_V}${NC} RPS: ${load_color}${BOLD}%-6s${NC}" "$current_rps"
    printf " ${COLOR_MUTED}|${NC} Intensity: ${load_color}${BOLD}%-6s${NC}" "$intensity_label"
    printf "%*s" "42" ""
    printf "${BOLD_CYAN}${BOX_L_V}${NC}\n"
    
    # Section footer
    printf "${BOLD_CYAN}${BOX_L_BL}"
    for ((i=0; i<78; i++)); do printf "${BOX_L_H}"; done
    printf "${BOX_L_BR}${NC}\n"
}

# -----------------------------------------------------------------------------
# render_queue_section - Display vLLM queue depth and scaling indicators
# Requirements: 2.1 (queue depth), 2.2 (KEDA target), 2.3, 2.4 (scaling zone)
# Output: Renders queue metrics section to stdout
# -----------------------------------------------------------------------------
render_queue_section() {
    local queue_depth="${METRIC_QUEUE_DEPTH:-0}"
    local queue_color
    queue_color=$(determine_status_color "queue" "$queue_depth")
    
    # Determine scaling zone
    local scaling_status
    scaling_status=$(determine_scaling_status "queue" "$queue_depth" "$THRESHOLD_QUEUE_TARGET")
    
    local zone_label="STABLE"
    local zone_color="$COLOR_GOOD"
    local zone_icon="$INDICATOR_STABLE"
    
    case "$scaling_status" in
        "scaling_up")
            zone_label="SCALE-UP"
            zone_color="$COLOR_WARNING"
            zone_icon="$INDICATOR_UP"
            ;;
        "scaling_down")
            zone_label="SCALE-DOWN"
            zone_color="$COLOR_INFO"
            zone_icon="$INDICATOR_DOWN"
            ;;
        *)
            zone_label="STABLE"
            zone_color="$COLOR_GOOD"
            zone_icon="$INDICATOR_STABLE"
            ;;
    esac
    
    # Add stale indicator if needed
    local stale_marker=""
    if [[ "$STALE_QUEUE_DEPTH" == "true" ]]; then
        stale_marker=" ${COLOR_WARNING}${INDICATOR_WARNING}${NC}"
    fi
    
    # Section header (78 inner + 2 borders = 80)
    printf "${BOLD_CYAN}${BOX_L_TL}${BOX_L_H}${NC}${BOLD_WHITE} Queue Depth ${NC}${BOLD_CYAN}"
    for ((i=0; i<64; i++)); do printf "${BOX_L_H}"; done
    printf "${BOX_L_TR}${NC}\n"
    
    # Queue depth display (fit in 78 chars)
    # Calculate padding based on stale marker presence (stale marker is 2 chars: space + ⚠)
    local stale_padding=0
    [[ "$STALE_QUEUE_DEPTH" == "true" ]] && stale_padding=2
    
    printf "${BOLD_CYAN}${BOX_L_V}${NC} Depth: ${queue_color}${BOLD}%-4s${NC}${stale_marker}" "$queue_depth"
    printf " ${COLOR_MUTED}|${NC} Target: ${COLOR_INFO}%-2s${NC}" "$THRESHOLD_QUEUE_TARGET"
    printf " ${COLOR_MUTED}|${NC} Zone: ${zone_color}%s%-10s${NC}" "$zone_icon" "$zone_label"
    printf "%*s" "$((29 - stale_padding))" ""
    printf "${BOLD_CYAN}${BOX_L_V}${NC}\n"
    
    # Visual queue bar (50 chars + borders)
    local bar_width=50
    local filled=0
    if [[ "$queue_depth" =~ ^[0-9]+$ ]] && [[ $queue_depth -gt 0 ]]; then
        filled=$(( (queue_depth * bar_width) / THRESHOLD_QUEUE_CRITICAL ))
        [[ $filled -gt $bar_width ]] && filled=$bar_width
    fi
    
    printf "${BOLD_CYAN}${BOX_L_V}${NC} ["
    for ((i=0; i<filled; i++)); do printf "${queue_color}${BLOCK_FULL}${NC}"; done
    for ((i=filled; i<bar_width; i++)); do printf "${COLOR_MUTED}${BLOCK_LIGHT}${NC}"; done
    printf "]"
    printf "%*s" "24" ""
    printf "${BOLD_CYAN}${BOX_L_V}${NC}\n"
    
    # Section footer
    printf "${BOLD_CYAN}${BOX_L_BL}"
    for ((i=0; i<78; i++)); do printf "${BOX_L_H}"; done
    printf "${BOX_L_BR}${NC}\n"
}

# -----------------------------------------------------------------------------
# render_pods_section - Display vLLM pod scaling status
# Requirements: 3.1-3.6 (pod counts, scaling indicators, visual representation)
# Output: Renders pod status section to stdout
# -----------------------------------------------------------------------------
render_pods_section() {
    local running="${METRIC_PODS_RUNNING:-0}"
    local desired="${METRIC_PODS_DESIRED:-0}"
    local ready="${METRIC_PODS_READY:-0}"
    
    # Determine scaling direction
    local scaling_status
    scaling_status=$(determine_scaling_status "pods" "$running" "$desired")
    
    local direction_icon="$INDICATOR_STABLE"
    local direction_color="$COLOR_GOOD"
    local direction_label="Stable"
    
    case "$scaling_status" in
        "scaling_up")
            direction_icon="$INDICATOR_UP"
            direction_color="$COLOR_WARNING"
            direction_label="Scaling Up"
            ;;
        "scaling_down")
            direction_icon="$INDICATOR_DOWN"
            direction_color="$COLOR_INFO"
            direction_label="Scaling Down"
            ;;
        *)
            direction_icon="$INDICATOR_STABLE"
            direction_color="$COLOR_GOOD"
            direction_label="Stable"
            ;;
    esac
    
    # Add stale indicator if needed
    local stale_marker=""
    if [[ "$STALE_PODS" == "true" ]]; then
        stale_marker=" ${COLOR_WARNING}${INDICATOR_WARNING}${NC}"
    fi
    
    # Section header (78 inner + 2 borders = 80)
    printf "${BOLD_CYAN}${BOX_L_TL}${BOX_L_H}${NC}${BOLD_WHITE} vLLM Pods ${NC}${BOLD_CYAN}"
    for ((i=0; i<66; i++)); do printf "${BOX_L_H}"; done
    printf "${BOX_L_TR}${NC}\n"
    
    # Pod counts line (fit in 78 chars)
    # Calculate padding based on stale marker presence (stale marker is 2 chars: space + ⚠)
    local stale_padding=0
    [[ "$STALE_PODS" == "true" ]] && stale_padding=2
    
    printf "${BOLD_CYAN}${BOX_L_V}${NC} Running: ${COLOR_GOOD}${BOLD}%-2s${NC}${stale_marker}" "$running"
    printf " ${COLOR_MUTED}|${NC} Desired: ${COLOR_INFO}%-2s${NC}" "$desired"
    printf " ${COLOR_MUTED}|${NC} Ready: ${COLOR_GOOD}%-2s${NC}" "$ready"
    printf " ${COLOR_MUTED}|${NC} ${direction_color}%s%-12s${NC}" "$direction_icon" "$direction_label"
    printf "%*s" "$((22 - stale_padding))" ""
    printf "${BOLD_CYAN}${BOX_L_V}${NC}\n"
    
    # Visual pod representation
    local max_pods=10
    local display_running=$running
    local display_desired=$desired
    
    [[ ! "$display_running" =~ ^[0-9]+$ ]] && display_running=0
    [[ ! "$display_desired" =~ ^[0-9]+$ ]] && display_desired=0
    [[ $display_running -gt $max_pods ]] && display_running=$max_pods
    [[ $display_desired -gt $max_pods ]] && display_desired=$max_pods
    
    # Calculate the max of running and desired for the empty slots
    local max_shown=$display_running
    [[ $display_desired -gt $max_shown ]] && max_shown=$display_desired
    
    printf "${BOLD_CYAN}${BOX_L_V}${NC} "
    for ((i=0; i<display_running; i++)); do
        printf "${COLOR_GOOD}%s${NC} " "$POD_ICON"
    done
    for ((i=display_running; i<display_desired; i++)); do
        printf "${COLOR_WARNING}%s${NC} " "$POD_EMPTY"
    done
    for ((i=max_shown; i<max_pods; i++)); do
        printf "${COLOR_MUTED}%s${NC} " "$POD_EMPTY"
    done
    printf "%*s" "$((78 - max_pods*2 - 1))" ""
    printf "${BOLD_CYAN}${BOX_L_V}${NC}\n"
    
    # Section footer
    printf "${BOLD_CYAN}${BOX_L_BL}"
    for ((i=0; i<78; i++)); do printf "${BOX_L_H}"; done
    printf "${BOX_L_BR}${NC}\n"
}

# -----------------------------------------------------------------------------
# render_nodes_section - Display GPU node scaling status
# Requirements: 4.1-4.3 (node count, visual representation)
# Output: Renders node status section to stdout
# -----------------------------------------------------------------------------
render_nodes_section() {
    local node_count="${METRIC_NODES_COUNT:-0}"
    
    # Determine if nodes are scaling
    local node_color="$COLOR_GOOD"
    local scaling_indicator=""
    
    if [[ "$node_count" =~ ^[0-9]+$ ]]; then
        if [[ $node_count -eq 0 ]]; then
            node_color="$COLOR_WARNING"
            scaling_indicator="(waiting for Karpenter)"
        fi
    else
        node_color="$COLOR_INFO"
    fi
    
    # Add stale indicator if needed
    local stale_marker=""
    if [[ "$STALE_NODES" == "true" ]]; then
        stale_marker=" ${COLOR_WARNING}${INDICATOR_WARNING}${NC}"
    fi
    
    # Section header (78 inner + 2 borders = 80)
    printf "${BOLD_CYAN}${BOX_L_TL}${BOX_L_H}${NC}${BOLD_WHITE} GPU Nodes ${NC}${BOLD_CYAN}"
    for ((i=0; i<66; i++)); do printf "${BOX_L_H}"; done
    printf "${BOX_L_TR}${NC}\n"
    
    # Node info line (fit in 78 chars)
    local stale_padding=0
    [[ "$STALE_NODES" == "true" ]] && stale_padding=2
    
    printf "${BOLD_CYAN}${BOX_L_V}${NC} Count: ${node_color}${BOLD}%-2s${NC}${stale_marker}" "$node_count"
    if [[ -n "$scaling_indicator" ]]; then
        printf " ${COLOR_WARNING}%s${NC}" "$scaling_indicator"
        # "Count: X  (waiting for Karpenter)" = 8 + 2 + 1 + 23 = 34 chars, need 78-34=44 padding
        printf "%*s" "$((44 - stale_padding))" ""
    else
        printf "%*s" "$((68 - stale_padding))" ""
    fi
    printf "${BOLD_CYAN}${BOX_L_V}${NC}\n"
    
    # Visual node representation
    local max_nodes=8
    local display_count=$node_count
    
    [[ ! "$display_count" =~ ^[0-9]+$ ]] && display_count=0
    [[ $display_count -gt $max_nodes ]] && display_count=$max_nodes
    
    printf "${BOLD_CYAN}${BOX_L_V}${NC} "
    for ((i=0; i<display_count; i++)); do
        printf "${COLOR_GOOD}%s${NC} " "$NODE_ICON"
    done
    for ((i=display_count; i<max_nodes; i++)); do
        printf "${COLOR_MUTED}%s${NC} " "$NODE_EMPTY"
    done
    printf "%*s" "$((78 - max_nodes*2 - 1))" ""
    printf "${BOLD_CYAN}${BOX_L_V}${NC}\n"
    
    # Section footer
    printf "${BOLD_CYAN}${BOX_L_BL}"
    for ((i=0; i<78; i++)); do printf "${BOX_L_H}"; done
    printf "${BOX_L_BR}${NC}\n"
}

# -----------------------------------------------------------------------------
# render_performance_section - Display throughput and response time metrics
# Requirements: 5.1-5.5 (throughput, response times, color coding, N/A handling)
# Output: Renders performance metrics section to stdout
# -----------------------------------------------------------------------------
render_performance_section() {
    local throughput="${METRIC_THROUGHPUT:-N/A}"
    local p50="${METRIC_RESPONSE_P50:-N/A}"
    local p95="${METRIC_RESPONSE_P95:-N/A}"
    local p99="${METRIC_RESPONSE_P99:-N/A}"
    local avg="${METRIC_RESPONSE_AVG:-N/A}"
    
    # Get colors for each metric
    local throughput_color
    throughput_color=$(determine_status_color "throughput" "$throughput")
    
    local p50_color
    p50_color=$(determine_status_color "response" "$p50")
    
    local p95_color
    p95_color=$(determine_status_color "response" "$p95")
    
    local p99_color
    p99_color=$(determine_status_color "response" "$p99")
    
    # Add stale indicator if needed
    local stale_marker=""
    if [[ "$STALE_PERFORMANCE" == "true" ]]; then
        stale_marker=" ${COLOR_WARNING}${INDICATOR_WARNING}${NC}"
    fi
    
    # Format values with units (keep short)
    local throughput_display="$throughput"
    [[ "$throughput" != "N/A" ]] && throughput_display="${throughput}"
    
    local p50_display="$p50"
    [[ "$p50" != "N/A" ]] && p50_display="${p50}ms"
    
    local p95_display="$p95"
    [[ "$p95" != "N/A" ]] && p95_display="${p95}ms"
    
    local p99_display="$p99"
    [[ "$p99" != "N/A" ]] && p99_display="${p99}ms"
    
    # Section header (78 inner + 2 borders = 80)
    printf "${BOLD_CYAN}${BOX_L_TL}${BOX_L_H}${NC}${BOLD_WHITE} Performance ${NC}${BOLD_CYAN}"
    for ((i=0; i<64; i++)); do printf "${BOX_L_H}"; done
    printf "${BOX_L_TR}${NC}\n"
    
    # Throughput line (fit in 78 chars)
    # Calculate padding based on stale marker presence (stale marker is 2 chars: space + ⚠)
    local stale_padding=0
    [[ "$STALE_PERFORMANCE" == "true" ]] && stale_padding=2
    
    printf "${BOLD_CYAN}${BOX_L_V}${NC} Throughput: ${throughput_color}${BOLD}%-6s${NC}${stale_marker}" "$throughput_display"
    printf " ${COLOR_MUTED}|${NC} p50: ${p50_color}%-8s${NC}" "$p50_display"
    printf " ${COLOR_MUTED}|${NC} p95: ${p95_color}%-8s${NC}" "$p95_display"
    printf " ${COLOR_MUTED}|${NC} p99: ${p99_color}%-8s${NC}" "$p99_display"
    printf "%*s" "$((4 - stale_padding))" ""
    printf "${BOLD_CYAN}${BOX_L_V}${NC}\n"
    
    # Section footer
    printf "${BOLD_CYAN}${BOX_L_BL}"
    for ((i=0; i<78; i++)); do printf "${BOX_L_H}"; done
    printf "${BOX_L_BR}${NC}\n"
}

# -----------------------------------------------------------------------------
# render_insights_section - Display key insights based on current metrics
# Requirements: 7.1 (organized layout), 7.4 (consistent color coding)
# Output: Renders key insights section to stdout
# -----------------------------------------------------------------------------
render_insights_section() {
    local insights=()
    local insight_colors=()
    
    # Analyze queue depth
    if [[ "$METRIC_QUEUE_DEPTH" =~ ^[0-9]+$ ]]; then
        if [[ $METRIC_QUEUE_DEPTH -ge $THRESHOLD_QUEUE_CRITICAL ]]; then
            insights+=("Queue critical - heavy scaling pressure")
            insight_colors+=("$COLOR_ERROR")
        elif [[ $METRIC_QUEUE_DEPTH -ge $THRESHOLD_QUEUE_HIGH ]]; then
            insights+=("Queue high - scaling in progress")
            insight_colors+=("$COLOR_WARNING")
        elif [[ $METRIC_QUEUE_DEPTH -eq 0 ]]; then
            insights+=("Queue empty - system idle")
            insight_colors+=("$COLOR_INFO")
        fi
    fi
    
    # Analyze pod scaling
    if [[ "$METRIC_PODS_RUNNING" =~ ^[0-9]+$ ]] && [[ "$METRIC_PODS_DESIRED" =~ ^[0-9]+$ ]]; then
        if [[ $METRIC_PODS_DESIRED -gt $METRIC_PODS_RUNNING ]]; then
            local pending=$((METRIC_PODS_DESIRED - METRIC_PODS_RUNNING))
            insights+=("Scaling up: $pending pod(s) pending")
            insight_colors+=("$COLOR_WARNING")
        elif [[ $METRIC_PODS_DESIRED -lt $METRIC_PODS_RUNNING ]]; then
            insights+=("Scaling down in progress")
            insight_colors+=("$COLOR_INFO")
        elif [[ $METRIC_PODS_RUNNING -gt 0 ]]; then
            insights+=("Pods stable at $METRIC_PODS_RUNNING replica(s)")
            insight_colors+=("$COLOR_GOOD")
        fi
    fi
    
    # Analyze node status
    if [[ "$METRIC_NODES_COUNT" =~ ^[0-9]+$ ]]; then
        if [[ $METRIC_NODES_COUNT -eq 0 ]]; then
            insights+=("No GPU nodes - Karpenter may provision")
            insight_colors+=("$COLOR_WARNING")
        elif [[ $METRIC_NODES_COUNT -ge 3 ]]; then
            insights+=("$METRIC_NODES_COUNT GPU nodes active")
            insight_colors+=("$COLOR_GOOD")
        fi
    fi
    
    # If no insights, show a default message
    if [[ ${#insights[@]} -eq 0 ]]; then
        insights+=("Monitoring autoscaling demo...")
        insight_colors+=("$COLOR_INFO")
    fi
    
    # Section header (78 inner + 2 borders = 80)
    printf "${BOLD_CYAN}${BOX_L_TL}${BOX_L_H}${NC}${BOLD_WHITE} Key Insights ${NC}${BOLD_CYAN}"
    for ((i=0; i<63; i++)); do printf "${BOX_L_H}"; done
    printf "${BOX_L_TR}${NC}\n"
    
    # Display up to 3 insights (fit in 78 chars each)
    local max_insights=3
    local displayed=0
    for i in "${!insights[@]}"; do
        if [[ $displayed -ge $max_insights ]]; then
            break
        fi
        
        local insight="${insights[$i]}"
        local color="${insight_colors[$i]}"
        
        # Truncate insight if too long (max 73 chars to fit with bullet and padding)
        if [[ ${#insight} -gt 73 ]]; then
            insight="${insight:0:70}..."
        fi
        
        printf "${BOLD_CYAN}${BOX_L_V}${NC} ${color}${INDICATOR_CHECK}${NC} %-74s${BOLD_CYAN}${BOX_L_V}${NC}\n" "$insight"
        displayed=$((displayed + 1))
    done
    
    # Pad with empty lines if fewer than max_insights
    while [[ $displayed -lt $max_insights ]]; do
        printf "${BOLD_CYAN}${BOX_L_V}${NC}%-78s${BOLD_CYAN}${BOX_L_V}${NC}\n" ""
        displayed=$((displayed + 1))
    done
    
    # Section footer
    printf "${BOLD_CYAN}${BOX_L_BL}"
    for ((i=0; i<78; i++)); do printf "${BOX_L_H}"; done
    printf "${BOX_L_BR}${NC}\n"
}

# -----------------------------------------------------------------------------
# render_footer - Display footer with controls and status
# Requirements: 7.1 (organized layout)
# Output: Renders footer section to stdout
# -----------------------------------------------------------------------------
render_footer() {
    # Render insights section first
    render_insights_section
    
    # Footer line with controls
    printf "\n"
    printf "${COLOR_MUTED}${BOX_L_H}${BOX_L_H}${BOX_L_H} Press ${BOLD}Ctrl+C${NC}${COLOR_MUTED} to exit ${BOX_L_H} Refresh: ${REFRESH_INTERVAL}s ${BOX_L_H}${BOX_L_H}${BOX_L_H}${NC}\n"
}

# =============================================================================
# MAIN DASHBOARD LOOP FUNCTIONS
# =============================================================================
# These functions implement the main dashboard loop including metric collection,
# rendering, and signal handling.
# =============================================================================

# -----------------------------------------------------------------------------
# collect_all_metrics - Collect all metrics from Kubernetes cluster
# Requirements: 6.5 (last known values), 8.3 (continue on failure)
# Side effects:
#   - Updates all METRIC_* variables with current values
#   - Updates LAST_GOOD_* variables on successful collection
#   - Sets STALE_* flags when collection fails
#   - Adds current RPS to load history
# Returns: Always returns 0 (success) - failures are handled gracefully
# -----------------------------------------------------------------------------
collect_all_metrics() {
    local pod_info
    local queue_depth
    local node_info
    local perf_metrics
    local pod_exit_code
    local queue_exit_code
    local node_exit_code
    local perf_exit_code
    
    # Collect vLLM pod status
    # Use || true to prevent errexit from stopping execution on failure
    pod_info=$(get_vllm_pods 2>/dev/null) || true
    pod_exit_code=$?
    # Check if the result indicates failure (N/A values or empty)
    if [[ -n "$pod_info" ]] && [[ "$pod_info" != "N/A|N/A|N/A" ]]; then
        METRIC_PODS_RUNNING=$(echo "$pod_info" | cut -d'|' -f1)
        METRIC_PODS_DESIRED=$(echo "$pod_info" | cut -d'|' -f2)
        METRIC_PODS_READY=$(echo "$pod_info" | cut -d'|' -f3)
        
        # Update last known good values
        LAST_GOOD_PODS_RUNNING="$METRIC_PODS_RUNNING"
        LAST_GOOD_PODS_DESIRED="$METRIC_PODS_DESIRED"
        LAST_GOOD_PODS_READY="$METRIC_PODS_READY"
        STALE_PODS=false
    else
        # Use last known good values and mark as stale
        METRIC_PODS_RUNNING="${LAST_GOOD_PODS_RUNNING:-N/A}"
        METRIC_PODS_DESIRED="${LAST_GOOD_PODS_DESIRED:-N/A}"
        METRIC_PODS_READY="${LAST_GOOD_PODS_READY:-N/A}"
        STALE_PODS=true
        log_error "Failed to collect pod metrics, using last known values"
    fi
    
    # Collect queue depth
    queue_depth=$(get_queue_depth 2>/dev/null) || true
    queue_exit_code=$?
    if [[ -n "$queue_depth" ]] && [[ "$queue_depth" != "N/A" ]]; then
        METRIC_QUEUE_DEPTH="$queue_depth"
        LAST_GOOD_QUEUE_DEPTH="$queue_depth"
        STALE_QUEUE_DEPTH=false
    else
        # Use last known good value and mark as stale
        METRIC_QUEUE_DEPTH="${LAST_GOOD_QUEUE_DEPTH:-N/A}"
        STALE_QUEUE_DEPTH=true
        log_error "Failed to collect queue depth, using last known value"
    fi
    
    # Collect node info (returns just the count)
    node_info=$(get_node_info 2>/dev/null) || true
    node_exit_code=$?
    if [[ -n "$node_info" ]] && [[ "$node_info" =~ ^[0-9]+$ ]]; then
        METRIC_NODES_COUNT="$node_info"
        LAST_GOOD_NODES_COUNT="$METRIC_NODES_COUNT"
        STALE_NODES=false
    else
        # Use last known good value and mark as stale
        METRIC_NODES_COUNT="${LAST_GOOD_NODES_COUNT:-0}"
        STALE_NODES=true
        log_error "Failed to collect node info, using last known value"
    fi
    
    # Collect performance metrics
    perf_metrics=$(get_performance_metrics 2>/dev/null) || true
    perf_exit_code=$?
    if [[ -n "$perf_metrics" ]] && [[ "$perf_metrics" != "N/A|N/A|N/A|N/A|N/A|N/A" ]]; then
        # Parse: throughput(placeholder)|p50|p95|p99|avg|request_count
        METRIC_THROUGHPUT=$(echo "$perf_metrics" | cut -d'|' -f1)
        METRIC_RESPONSE_P50=$(echo "$perf_metrics" | cut -d'|' -f2)
        METRIC_RESPONSE_P95=$(echo "$perf_metrics" | cut -d'|' -f3)
        METRIC_RESPONSE_P99=$(echo "$perf_metrics" | cut -d'|' -f4)
        METRIC_RESPONSE_AVG=$(echo "$perf_metrics" | cut -d'|' -f5)
        local request_count=$(echo "$perf_metrics" | cut -d'|' -f6)
        
        # Calculate RPS from request count delta (must be done here, not in subshell)
        local current_time=$(date +%s)
        if [[ -n "$request_count" ]] && [[ "$request_count" =~ ^[0-9]+$ ]]; then
            if [[ $LAST_REQUEST_TIME -gt 0 ]]; then
                local time_diff=$((current_time - LAST_REQUEST_TIME))
                local count_diff=$((request_count - LAST_REQUEST_COUNT))
                
                if [[ $time_diff -gt 0 ]] && [[ $count_diff -ge 0 ]]; then
                    METRIC_THROUGHPUT=$((count_diff / time_diff))
                fi
            fi
            # Update state for next calculation
            LAST_REQUEST_COUNT=$request_count
            LAST_REQUEST_TIME=$current_time
        fi
        
        # Update last known good values
        LAST_GOOD_THROUGHPUT="$METRIC_THROUGHPUT"
        STALE_PERFORMANCE=false
    else
        # Use last known good values and mark as stale
        METRIC_THROUGHPUT="${LAST_GOOD_THROUGHPUT:-N/A}"
        METRIC_RESPONSE_P50="N/A"
        METRIC_RESPONSE_P95="N/A"
        METRIC_RESPONSE_P99="N/A"
        METRIC_RESPONSE_AVG="N/A"
        STALE_PERFORMANCE=true
        log_error "Failed to collect performance metrics, using last known values"
    fi
    
    # Update current RPS (use throughput or queue depth as proxy)
    if [[ "$METRIC_THROUGHPUT" != "N/A" ]] && [[ "$METRIC_THROUGHPUT" =~ ^[0-9]+$ ]]; then
        METRIC_CURRENT_RPS="$METRIC_THROUGHPUT"
    elif [[ "$METRIC_QUEUE_DEPTH" != "N/A" ]] && [[ "$METRIC_QUEUE_DEPTH" =~ ^[0-9]+$ ]]; then
        # Use queue depth as a proxy for load when throughput is unavailable
        METRIC_CURRENT_RPS="$METRIC_QUEUE_DEPTH"
    else
        METRIC_CURRENT_RPS=0
    fi
    
    # Add current RPS to load history for graph
    add_to_load_history "$METRIC_CURRENT_RPS"
    
    # Update scaling status
    METRIC_SCALING_STATUS=$(determine_scaling_status "pods" "$METRIC_PODS_RUNNING" "$METRIC_PODS_DESIRED")
    
    # Update last update timestamp
    METRIC_LAST_UPDATE=$(date '+%H:%M:%S')
    
    # Always return success - failures are handled gracefully with stale indicators
    return 0
}

# -----------------------------------------------------------------------------
# render_dashboard - Render the complete dashboard to the terminal
# Requirements: 6.2 (cursor positioning), 7.1 (organized layout)
# Side effects:
#   - Moves cursor to home position (top-left)
#   - Renders all dashboard sections in order
#   - Displays footer with controls
# Notes:
#   - Uses cursor positioning instead of full screen clear to avoid flicker
# -----------------------------------------------------------------------------
render_dashboard() {
    # Move cursor to home position (top-left) without clearing screen
    # This prevents flicker during updates
    printf "${CURSOR_HOME}"
    
    # Render all sections in order
    render_header
    echo ""  # Spacing
    render_load_section
    render_queue_section
    render_pods_section
    render_nodes_section
    render_performance_section
    echo ""  # Spacing
    render_footer
    
    # Clear any remaining content from previous renders
    # This handles cases where the new render is shorter than the previous one
    printf "${CLEAR_LINE}"
}

# -----------------------------------------------------------------------------
# cleanup - Cleanup function called on exit
# Requirements: 8.3 (graceful exit)
# Side effects:
#   - Restores cursor visibility
#   - Displays goodbye message
#   - Logs shutdown event
# -----------------------------------------------------------------------------
cleanup() {
    # Restore cursor visibility
    printf "${CURSOR_SHOW}"
    
    # Move to a new line and display goodbye message
    echo ""
    echo -e "${COLOR_GOOD}Dashboard stopped. Goodbye!${NC}"
    
    # Log the shutdown
    log_info "Dashboard session ended (cleanup called)"
    
    # Reset RUNNING flag
    RUNNING=false
}

# -----------------------------------------------------------------------------
# handle_signal - Signal handler for SIGINT and SIGTERM
# Requirements: 8.3 (graceful Ctrl+C handling)
# Side effects:
#   - Sets RUNNING flag to false to stop the main loop
#   - Logs the signal received
# -----------------------------------------------------------------------------
handle_signal() {
    log_info "Received termination signal, shutting down gracefully"
    RUNNING=false
}

# -----------------------------------------------------------------------------
# run_dashboard - Main dashboard loop
# Requirements: 6.1 (2-second refresh), 6.4 (elapsed time)
# Side effects:
#   - Initializes start time
#   - Runs continuous loop: collect → update → render → sleep
#   - Handles Ctrl+C gracefully
# -----------------------------------------------------------------------------
run_dashboard() {
    # Initialize start time for elapsed calculation
    START_TIME=$(date +%s)
    
    # Set up signal handlers for graceful exit
    trap handle_signal SIGINT SIGTERM
    trap cleanup EXIT
    
    # Hide cursor during dashboard operation
    printf "${CURSOR_HIDE}"
    
    # Clear screen once at startup
    printf "${CLEAR_SCREEN}${CURSOR_HOME}"
    
    # Log startup
    log_info "Dashboard started"
    
    # Main loop
    while [[ "$RUNNING" == "true" ]]; do
        # Collect all metrics from Kubernetes
        collect_all_metrics
        
        # Render the dashboard
        render_dashboard
        
        # Sleep for refresh interval
        # Use a loop with shorter sleeps to be more responsive to signals
        local sleep_count=0
        while [[ $sleep_count -lt $REFRESH_INTERVAL ]] && [[ "$RUNNING" == "true" ]]; do
            sleep 1
            sleep_count=$((sleep_count + 1))
        done
    done
    
    # Log shutdown
    log_info "Dashboard stopped"
}

# -----------------------------------------------------------------------------
# Main Entry Point
# -----------------------------------------------------------------------------

main() {
    # Initialize error logging
    init_error_log
    
    # Run prerequisite checks before starting dashboard
    if ! run_prerequisite_checks; then
        echo "" >&2
        echo -e "${COLOR_ERROR}Dashboard cannot start due to failed prerequisite checks.${NC}" >&2
        echo "Check the log file for details: $ERROR_LOG" >&2
        exit 1
    fi
    
    # Small delay to let user see the check results
    sleep 1
    
    # Run the dashboard
    run_dashboard
}

# Run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
