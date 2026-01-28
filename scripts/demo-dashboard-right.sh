#!/bin/bash

NC='\033[0m'
BOLD='\033[1m'
BOLD_CYAN='\033[1;36m'
BOLD_WHITE='\033[1;37m'
COLOR_GOOD='\033[38;5;40m'
COLOR_WARNING='\033[38;5;226m'
COLOR_ERROR='\033[38;5;196m'
COLOR_INFO='\033[38;5;51m'
COLOR_MUTED='\033[38;5;245m'

BOX_L_TL='┌'
BOX_L_TR='┐'
BOX_L_BL='└'
BOX_L_BR='┘'
BOX_L_H='─'
BOX_L_V='│'

CURSOR_HOME='\033[H'
CLEAR_SCREEN='\033[2J'
CLEAR_LINE='\033[K'
CURSOR_HIDE='\033[?25l'
CURSOR_SHOW='\033[?25h'

REFRESH_INTERVAL=1
MAX_ROWS=15

cleanup() {
    printf "${CURSOR_SHOW}${NC}"
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

get_pod_timing_info() {
    kubectl get pods -n default -l app=vllm -o json 2>/dev/null | jq -r '
        .items[] | 
        {
            name: .metadata.name,
            phase: .status.phase,
            creationTime: .metadata.creationTimestamp,
            scheduledCondition: (.status.conditions[] | select(.type=="PodScheduled") | .lastTransitionTime // ""),
            readyCondition: (.status.conditions[] | select(.type=="Ready"))
        } |
        .name + "|" + 
        .phase + "|" + 
        (if .readyCondition.status == "True" then "Ready" else "NotReady" end) + "|" +
        .creationTime + "|" +
        .scheduledCondition + "|" +
        (if .readyCondition.status == "True" then .readyCondition.lastTransitionTime else "" end)
    ' 2>/dev/null || echo ""
}

render_pod_timing_panel() {
    local pod_data="$1"
    local panel_width=58
    
    printf "${BOLD_CYAN}${BOX_L_TL}${BOX_L_H}${NC}${BOLD_WHITE} vLLM Pods ${NC}${BOLD_CYAN}"
    for ((i=0; i<46; i++)); do printf "${BOX_L_H}"; done
    printf "${BOX_L_TR}${NC}${CLEAR_LINE}\n"
    
    printf "${BOLD_CYAN}${BOX_L_V}${NC} ${BOLD}%-18s %-10s %-8s %-8s %-6s${NC}" "Name" "Status" "Node" "Pod" "Total"
    printf "   ${BOLD_CYAN}${BOX_L_V}${NC}${CLEAR_LINE}\n"
    
    printf "${BOLD_CYAN}${BOX_L_V}"
    for ((i=0; i<panel_width; i++)); do printf "${BOX_L_H}"; done
    printf "${BOX_L_V}${NC}${CLEAR_LINE}\n"
    
    local row_count=0
    
    if [[ -z "$pod_data" ]]; then
        printf "${BOLD_CYAN}${BOX_L_V}${NC} ${COLOR_MUTED}No pods found${NC}"
        printf "%*s${BOLD_CYAN}${BOX_L_V}${NC}${CLEAR_LINE}\n" "$((panel_width - 14))" ""
        row_count=1
    else
        while IFS='|' read -r name phase ready_status creation_time scheduled_time ready_time; do
            [[ -z "$name" ]] && continue
            
            local short_name="${name: -16}"
            
            local status_display="$ready_status"
            local status_color="$COLOR_INFO"
            [[ "$ready_status" == "Ready" ]] && status_color="$COLOR_GOOD"
            [[ "$ready_status" == "NotReady" ]] && status_color="$COLOR_WARNING"
            [[ "$phase" == "Failed" ]] && status_color="$COLOR_ERROR" && status_display="Failed"
            [[ "$phase" == "Pending" ]] && status_color="$COLOR_WARNING" && status_display="Pending"
            
            local node_time_display="-"
            local pod_time_display="-"
            local total_time_display="-"
            
            if [[ -n "$creation_time" ]] && [[ -n "$scheduled_time" ]]; then
                local creation_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$creation_time" "+%s" 2>/dev/null)
                local scheduled_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$scheduled_time" "+%s" 2>/dev/null)
                if [[ -n "$creation_epoch" ]] && [[ -n "$scheduled_epoch" ]]; then
                    local node_secs=$((scheduled_epoch - creation_epoch))
                    [[ $node_secs -lt 0 ]] && node_secs=0
                    node_time_display="${node_secs}s"
                fi
            fi
            
            if [[ -n "$scheduled_time" ]] && [[ -n "$ready_time" ]] && [[ "$ready_status" == "Ready" ]]; then
                local scheduled_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$scheduled_time" "+%s" 2>/dev/null)
                local ready_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ready_time" "+%s" 2>/dev/null)
                if [[ -n "$scheduled_epoch" ]] && [[ -n "$ready_epoch" ]]; then
                    local pod_secs=$((ready_epoch - scheduled_epoch))
                    [[ $pod_secs -lt 0 ]] && pod_secs=0
                    pod_time_display="${pod_secs}s"
                fi
            fi
            
            if [[ -n "$creation_time" ]] && [[ -n "$ready_time" ]] && [[ "$ready_status" == "Ready" ]]; then
                local creation_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$creation_time" "+%s" 2>/dev/null)
                local ready_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ready_time" "+%s" 2>/dev/null)
                if [[ -n "$creation_epoch" ]] && [[ -n "$ready_epoch" ]]; then
                    local total_secs=$((ready_epoch - creation_epoch))
                    [[ $total_secs -lt 0 ]] && total_secs=0
                    total_time_display="${total_secs}s"
                fi
            fi
            
            printf "${BOLD_CYAN}${BOX_L_V}${NC} %-18s ${status_color}%-10s${NC} %-8s %-8s %-6s" \
                "$short_name" "$status_display" "$node_time_display" "$pod_time_display" "$total_time_display"
            printf "   ${BOLD_CYAN}${BOX_L_V}${NC}${CLEAR_LINE}\n"
            
            ((row_count++))
        done <<< "$pod_data"
    fi
    
    printf "${BOLD_CYAN}${BOX_L_BL}"
    for ((i=0; i<panel_width; i++)); do printf "${BOX_L_H}"; done
    printf "${BOX_L_BR}${NC}${CLEAR_LINE}\n"
    
    for ((i=row_count; i<MAX_ROWS; i++)); do
        printf "${CLEAR_LINE}\n"
    done
}

main() {
    printf "${CURSOR_HIDE}${CLEAR_SCREEN}${CURSOR_HOME}"
    
    while true; do
        printf "${CURSOR_HOME}"
        
        echo ""
        echo ""
        echo ""
        echo ""
        echo ""
        echo ""
        echo ""
        
        local pod_data=$(get_pod_timing_info)
        render_pod_timing_panel "$pod_data"
        
        sleep $REFRESH_INTERVAL
    done
}

main
