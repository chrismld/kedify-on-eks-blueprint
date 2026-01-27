#!/bin/bash

# =============================================================================
# Demo Dashboard Right Panel - vLLM Pod Timing Monitor
# =============================================================================
# Companion script to demo-dashboard.sh showing pod timing information
# Usage: ./demo-dashboard-right.sh
# =============================================================================

# Color Constants
NC='\033[0m'
BOLD='\033[1m'
BOLD_CYAN='\033[1;36m'
BOLD_WHITE='\033[1;37m'
COLOR_GOOD='\033[38;5;40m'
COLOR_WARNING='\033[38;5;226m'
COLOR_ERROR='\033[38;5;196m'
COLOR_INFO='\033[38;5;51m'
COLOR_MUTED='\033[38;5;245m'

# Box drawing characters
BOX_L_TL='┌'
BOX_L_TR='┐'
BOX_L_BL='└'
BOX_L_BR='┘'
BOX_L_H='─'
BOX_L_V='│'

# ANSI control codes
CURSOR_HOME='\033[H'
CLEAR_SCREEN='\033[2J'
CLEAR_LINE='\033[K'
CURSOR_HIDE='\033[?25l'
CURSOR_SHOW='\033[?25h'

# Configuration
REFRESH_INTERVAL=1

# Cleanup on exit
cleanup() {
    printf "${CURSOR_SHOW}${NC}"
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

# Get pod timing info
get_pod_timing_info() {
    kubectl get pods -n default -l app=vllm -o json 2>/dev/null | jq -r '
        .items[] | 
        {
            name: .metadata.name,
            phase: .status.phase,
            startTime: .status.startTime,
            readyCondition: (.status.conditions[] | select(.type=="Ready"))
        } |
        .name + "|" + 
        .phase + "|" + 
        (if .readyCondition.status == "True" then "Ready" else "NotReady" end) + "|" +
        .startTime + "|" +
        (if .readyCondition.status == "True" then .readyCondition.lastTransitionTime else "" end)
    ' 2>/dev/null || echo ""
}

# Render pod timing panel
render_pod_timing_panel() {
    local pod_data="$1"
    local panel_width=58
    
    # Section header
    printf "${BOLD_CYAN}${BOX_L_TL}${BOX_L_H}${NC}${BOLD_WHITE} vLLM Pods ${NC}${BOLD_CYAN}"
    for ((i=0; i<46; i++)); do printf "${BOX_L_H}"; done
    printf "${BOX_L_TR}${NC}\n"
    
    # Table header
    printf "${BOLD_CYAN}${BOX_L_V}${NC} ${BOLD}%-18s %-8s %-8s %-8s %-6s${NC}" "Pod" "Status" "Start" "Ready" "Time"
    printf "     ${BOLD_CYAN}${BOX_L_V}${NC}\n"
    
    # Separator
    printf "${BOLD_CYAN}${BOX_L_V}"
    for ((i=0; i<panel_width; i++)); do printf "${BOX_L_H}"; done
    printf "${BOX_L_V}${NC}\n"
    
    if [[ -z "$pod_data" ]]; then
        printf "${BOLD_CYAN}${BOX_L_V}${NC} ${COLOR_MUTED}No pods found${NC}"
        printf "%*s${BOLD_CYAN}${BOX_L_V}${NC}\n" "$((panel_width - 14))" ""
    else
        while IFS='|' read -r name phase ready_status start_time ready_time; do
            [[ -z "$name" ]] && continue
            
            # Shorten pod name (keep last 16 chars)
            local short_name="${name: -16}"
            
            # Format status
            local status_display="$ready_status"
            local status_color="$COLOR_INFO"
            [[ "$ready_status" == "Ready" ]] && status_color="$COLOR_GOOD"
            [[ "$ready_status" == "NotReady" ]] && status_color="$COLOR_WARNING"
            [[ "$phase" == "Failed" ]] && status_color="$COLOR_ERROR" && status_display="Failed"
            [[ "$phase" == "Pending" ]] && status_color="$COLOR_WARNING" && status_display="Pending"
            
            # Format times (HH:MM:SS)
            local start_display="N/A"
            if [[ -n "$start_time" ]]; then
                start_display=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$start_time" "+%H:%M:%S" 2>/dev/null || echo "N/A")
            fi
            
            local ready_display="N/A"
            local time_display="N/A"
            if [[ -n "$ready_time" ]] && [[ "$ready_status" == "Ready" ]]; then
                ready_display=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ready_time" "+%H:%M:%S" 2>/dev/null || echo "N/A")
                
                # Calculate time to ready in seconds
                if [[ "$start_display" != "N/A" ]] && [[ "$ready_display" != "N/A" ]]; then
                    local start_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$start_time" "+%s" 2>/dev/null)
                    local ready_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ready_time" "+%s" 2>/dev/null)
                    if [[ -n "$start_epoch" ]] && [[ -n "$ready_epoch" ]]; then
                        time_display=$((ready_epoch - start_epoch))
                        time_display="${time_display}s"
                    fi
                fi
            fi
            
            # Print row
            printf "${BOLD_CYAN}${BOX_L_V}${NC} %-18s ${status_color}%-8s${NC} %-8s %-8s %-6s" \
                "$short_name" "$status_display" "$start_display" "$ready_display" "$time_display"
            printf "     ${BOLD_CYAN}${BOX_L_V}${NC}\n"
        done <<< "$pod_data"
    fi
    
    # Section footer
    printf "${BOLD_CYAN}${BOX_L_BL}"
    for ((i=0; i<panel_width; i++)); do printf "${BOX_L_H}"; done
    printf "${BOX_L_BR}${NC}\n"
}

# Main loop
main() {
    # Hide cursor and clear screen once
    printf "${CURSOR_HIDE}${CLEAR_SCREEN}${CURSOR_HOME}"
    
    while true; do
        # Move to home
        printf "${CURSOR_HOME}"
        
        # Add spacing to align with Load Graph (header + blank lines)
        echo ""
        echo ""
        echo ""
        echo ""
        echo ""
        echo ""
        echo ""
        
        # Get pod timing data
        local pod_data=$(get_pod_timing_info)
        
        # Render panel
        render_pod_timing_panel "$pod_data"
        
        # Wait for refresh interval
        sleep $REFRESH_INTERVAL
    done
}

main
