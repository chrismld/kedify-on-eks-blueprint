#!/bin/bash

# Terminal Dashboard for Tube Scaling Demo
# Shows real-time metrics with Tube-themed visualization

# Colors
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Tube lines (for visual representation)
TUBE_LINES=("Piccadilly" "Central" "Northern" "Jubilee" "Victoria" "District" "Circle" "Metropolitan" "Bakerloo" "All Lines!")

# Function to draw a progress bar
draw_bar() {
    local current=$1
    local max=$2
    local width=40
    local filled=$((current * width / max))
    local empty=$((width - filled))
    
    printf "["
    printf "%${filled}s" | tr ' ' '█'
    printf "%${empty}s" | tr ' ' '░'
    printf "]"
}

# Function to get pod count
get_pod_count() {
    kubectl get pods -l app=vllm -o json 2>/dev/null | \
        jq -r '.items | length' 2>/dev/null || echo "0"
}

# Function to get node count
get_node_count() {
    kubectl get nodes -l workload=inference -o json 2>/dev/null | \
        jq -r '.items | length' 2>/dev/null || echo "0"
}

# Function to get queue depth from vLLM metrics
get_queue_depth() {
    # Try to get from OTEL scaler metrics
    local queue=$(curl -s http://localhost:8080/metrics 2>/dev/null | \
        grep "vllm_num_requests_waiting" | \
        grep -v "#" | \
        awk '{print $2}' | \
        head -1)
    echo "${queue:-0}"
}

# Function to get HPA status
get_hpa_status() {
    kubectl get hpa vllm-queue-scaler -o json 2>/dev/null | \
        jq -r '{current: .status.currentReplicas, desired: .status.desiredReplicas, max: .spec.maxReplicas}'
}

# Function to get question count
get_question_count() {
    curl -s http://localhost:8000/api/questions 2>/dev/null | \
        jq -r '.questions | length' 2>/dev/null || echo "0"
}

# Function to get a fun message based on current state
get_fun_message() {
    local queue=$1
    local pods=$2
    local nodes=$3
    local max_pods=10
    
    # Calculate scaling efficiency
    local pod_utilization=$((pods * 100 / max_pods))
    
    # Different messages based on situation
    if [ $queue -gt 100 ] && [ $pods -lt 5 ]; then
        echo "😰 \"It'll scale, I promise!\" - Famous last words"
    elif [ $queue -gt 80 ] && [ $pods -lt 4 ]; then
        echo "🤞 Narrator: It was at this moment they knew... they should've tested this"
    elif [ $queue -gt 50 ] && [ $pods -eq 1 ]; then
        echo "😅 \"This worked in my laptop!\" - Every developer ever"
    elif [ $queue -gt 30 ] && [ $pods -eq 1 ]; then
        echo "🎭 Plot twist: The demo becomes a lesson in what NOT to do"
    elif [ $pods -eq 1 ] && [ $queue -gt 20 ]; then
        echo "☕ That awkward silence while we wait for Kubernetes to wake up..."
    elif [ $pods -ge 8 ] && [ $queue -lt 10 ]; then
        echo "🎉 \"See? I told you it would work!\" - Relieved speaker"
    elif [ $pods -ge 6 ] && [ $queue -lt 20 ]; then
        echo "😎 Smooth like butter. We totally planned this. Definitely."
    elif [ $pods -ge 5 ]; then
        echo "🚀 Look at it go! *Frantically checks if this is actually working*"
    elif [ $nodes -eq 0 ]; then
        echo "🙈 Karpenter is taking a coffee break. This is fine. Everything is fine."
    elif [ $queue -eq 0 ] && [ $pods -eq 1 ]; then
        echo "😴 *Crickets* Come on audience, send more questions! Make us sweat!"
    elif [ $queue -lt 5 ] && [ $pods -gt 5 ]; then
        echo "🤔 We may have over-engineered this. Just a bit. Maybe."
    elif [ $pods -eq 10 ]; then
        echo "🎊 ALL LINES RUNNING! *Tries to act like this wasn't stressful*"
    else
        # Random fun messages for normal operation
        local random=$((RANDOM % 10))
        case $random in
            0) echo "🎪 Live demo: Where Murphy's Law meets Kubernetes" ;;
            1) echo "🎲 Will it scale? Stay tuned for this episode of DevOps Drama!" ;;
            2) echo "🎬 This is either going to be epic or a great learning experience" ;;
            3) echo "🤹 Juggling GPUs, pods, and our reputation simultaneously" ;;
            4) echo "🎯 Confidence level: Somewhere between 'it works' and 'please work'" ;;
            5) echo "🎪 Remember: It's not a bug, it's an unplanned feature demonstration" ;;
            6) echo "🎭 The show must go on! (Please Kubernetes, make it go on...)" ;;
            7) echo "🎸 Scaling live is like playing guitar - looks easy until you try it" ;;
            8) echo "🎨 Creating art with YAML and hoping it doesn't become abstract" ;;
            9) echo "🎵 🎶 Scaling, scaling, 1-2-3... Please don't fail in front of me 🎶" ;;
        esac
    fi
}

# Function to get Tube line name based on pod count
get_tube_line() {
    local pods=$1
    local index=$((pods - 1))
    if [ $index -lt 0 ]; then index=0; fi
    if [ $index -ge ${#TUBE_LINES[@]} ]; then index=$((${#TUBE_LINES[@]} - 1)); fi
    echo "${TUBE_LINES[$index]}"
}

# Function to get speaker stress level emoji
get_stress_level() {
    local queue=$1
    local pods=$2
    
    if [ $queue -gt 100 ] && [ $pods -lt 3 ]; then
        echo "😱😱😱"
    elif [ $queue -gt 80 ] && [ $pods -lt 4 ]; then
        echo "😰😰"
    elif [ $queue -gt 50 ] && [ $pods -lt 5 ]; then
        echo "😅"
    elif [ $pods -ge 8 ]; then
        echo "😎"
    elif [ $pods -ge 6 ]; then
        echo "🙂"
    else
        echo "🤞"
    fi
}

# Function to draw pod visualization
draw_pods() {
    local current=$1
    local max=$2
    local output=""
    
    for ((i=1; i<=max; i++)); do
        if [ $i -le $current ]; then
            output+="🟢"
        else
            output+="⚪"
        fi
    done
    echo "$output"
}

# Function to draw nodes
draw_nodes() {
    local current=$1
    local max=5
    local output=""
    
    for ((i=1; i<=max; i++)); do
        if [ $i -le $current ]; then
            output+="🟢"
        else
            output+="⚪"
        fi
    done
    echo "$output"
}

# Function to get elapsed time
get_elapsed_time() {
    local start_time=$1
    local current_time=$(date +%s)
    local elapsed=$((current_time - start_time))
    local minutes=$((elapsed / 60))
    local seconds=$((elapsed % 60))
    printf "%02d:%02d" $minutes $seconds
}

# Main dashboard loop
main() {
    local start_time=$(date +%s)
    local demo_duration=1800  # 30 minutes in seconds
    local last_pods=0
    local last_queue=0
    
    # Hide cursor
    tput civis
    
    # Trap to show cursor on exit
    trap 'tput cnorm; exit' INT TERM
    
    while true; do
        clear
        
        # Get current metrics
        local queue=$(get_queue_depth)
        local pods=$(get_pod_count)
        local nodes=$(get_node_count)
        local questions=$(get_question_count)
        local elapsed=$(get_elapsed_time $start_time)
        local tube_line=$(get_tube_line $pods)
        
        # Detect scaling
        local scaling_indicator=""
        if [ $pods -gt $last_pods ]; then
            scaling_indicator="${GREEN}↑ SCALING UP!${NC}"
        elif [ $pods -lt $last_pods ]; then
            scaling_indicator="${YELLOW}↓ SCALING DOWN${NC}"
        fi
        
        # Header
        echo -e "${BOLD}${CYAN}"
        echo "╔═══════════════════════════════════════════════════════════════════╗"
        echo "║           🚇 KUBERNETES TUBE SCALING DEMO 🚇                      ║"
        echo "╠═══════════════════════════════════════════════════════════════════╣"
        echo -e "${NC}"
        
        # Queue Depth
        echo -e "${BOLD}📊 QUEUE DEPTH${NC} (50x multiplier active)"
        local queue_bar=$(draw_bar $queue 100)
        echo -e "${CYAN}$queue_bar${NC} ${BOLD}$queue${NC} requests"
        if [ $queue -gt $last_queue ]; then
            echo -e "${GREEN}↑ +$((queue - last_queue))${NC}"
        fi
        echo ""
        
        # Tube Lines (Pods)
        echo -e "${BOLD}🚇 TUBE LINES${NC} (vLLM Pods)"
        echo "┌─────────────────────────────────────────────────────────────────┐"
        echo -e "│ ${BOLD}Current Line:${NC} ${YELLOW}$tube_line${NC}"
        echo -e "│ ${BOLD}Pods:${NC} $(draw_pods $pods 10) ${BOLD}$pods/10${NC} $scaling_indicator"
        echo "└─────────────────────────────────────────────────────────────────┘"
        echo ""
        
        # GPU Nodes
        echo -e "${BOLD}🖥️  GPU NODES${NC} (Karpenter)"
        echo -e "$(draw_nodes $nodes) ${BOLD}$nodes${NC} nodes (g5.2xlarge Spot)"
        echo ""
        
        # Audience Stats
        echo -e "${BOLD}👥 AUDIENCE CONTRIBUTION${NC}"
        echo -e "Real questions: ${BOLD}$questions${NC}"
        echo -e "Amplified load: ${BOLD}$((questions * 50))${NC} requests"
        echo ""
        
        # Speaker Stress Level
        local stress=$(get_stress_level $queue $pods)
        echo -e "${BOLD}🎭 SPEAKER STRESS LEVEL${NC}"
        echo -e "${YELLOW}$stress${NC}"
        echo ""
        
        # Fun Commentary
        local fun_msg=$(get_fun_message $queue $pods $nodes)
        echo -e "${BOLD}💬 LIVE COMMENTARY${NC}"
        echo -e "${CYAN}$fun_msg${NC}"
        echo ""
        
        # Latest Events
        echo -e "${BOLD}⚡ LATEST EVENTS${NC}"
        if [ $pods -gt $last_pods ]; then
            echo -e "${GREEN}[$(date +%H:%M:%S)] 🚇 Mind the Gap! Scaling $last_pods→$pods pods${NC}"
        fi
        if [ $nodes -gt 0 ]; then
            echo -e "${CYAN}[$(date +%H:%M:%S)] 🖥️  GPU nodes active: $nodes${NC}"
        fi
        if [ $queue -gt 50 ]; then
            echo -e "${YELLOW}[$(date +%H:%M:%S)] 📈 Rush hour! Queue: $queue requests${NC}"
        fi
        echo ""
        
        # Demo Progress
        local elapsed_seconds=$(($(date +%s) - start_time))
        local progress=$((elapsed_seconds * 100 / demo_duration))
        if [ $progress -gt 100 ]; then progress=100; fi
        
        echo -e "${BOLD}🎯 DEMO PROGRESS${NC}"
        local progress_bar=$(draw_bar $progress 100)
        echo -e "${CYAN}$progress_bar${NC} Time: ${BOLD}$elapsed${NC} / 30:00 min"
        echo ""
        
        echo "╚═══════════════════════════════════════════════════════════════════╝"
        echo -e "${BOLD}Press Ctrl+C to exit${NC}"
        
        # Update last values
        last_pods=$pods
        last_queue=$queue
        
        # Refresh every 2 seconds
        sleep 2
    done
}

# Run the dashboard
main
