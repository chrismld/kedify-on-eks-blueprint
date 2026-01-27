#!/bin/bash

OTEL_LOCAL_PORT=18889

# Simplified parse function
parse_metric_from_raw() {
    local raw_metrics="$1"
    local metric_name="$2"
    local mode="${3:-sum}"
    
    local total=0
    local found=false
    local first_value=""
    
    # Create colon variant
    local colon_name="${metric_name/_/:}"
    
    while IFS= read -r line; do
        [[ "$line" =~ ^# ]] && continue
        [[ -z "$line" ]] && continue
        
        local match=false
        case "$line" in
            "${metric_name}{"*|"${metric_name} "*)
                match=true
                ;;
            "${colon_name}{"*|"${colon_name} "*)
                match=true
                ;;
        esac
        
        if [[ "$match" == "true" ]]; then
            local num_fields=$(echo "$line" | awk '{print NF}')
            local value
            if [[ $num_fields -ge 3 ]]; then
                value=$(echo "$line" | awk '{print $(NF-1)}')
            else
                value=$(echo "$line" | awk '{print $NF}')
            fi
            if [[ "$value" =~ ^[0-9]+\.?[0-9]*([eE][+-]?[0-9]+)?$ ]]; then
                found=true
                if [[ "$mode" == "first" ]] && [[ -z "$first_value" ]]; then
                    first_value="$value"
                else
                    local int_value=${value%.*}
                    if [[ "$value" =~ [eE] ]]; then
                        int_value=$(printf "%.0f" "$value" 2>/dev/null || echo "0")
                    fi
                    total=$((total + int_value))
                fi
            fi
        fi
    done <<< "$raw_metrics"
    
    if [[ "$found" == "true" ]]; then
        if [[ "$mode" == "first" ]]; then
            echo "$first_value"
        else
            echo "$total"
        fi
        return 0
    fi
    
    return 1
}

# Get metrics
raw=$(curl -s --max-time 5 "http://localhost:$OTEL_LOCAL_PORT/metrics" 2>/dev/null)
echo "Raw metrics size: ${#raw}"
echo "Lines: $(echo "$raw" | wc -l)"

echo ""
echo "Testing parse_metric_from_raw:"
result=$(parse_metric_from_raw "$raw" "vllm_request_success_total" "sum")
echo "vllm_request_success_total: [$result]"

result=$(parse_metric_from_raw "$raw" "vllm_generation_tokens_total" "sum")
echo "vllm_generation_tokens_total: [$result]"

result=$(parse_metric_from_raw "$raw" "vllm_num_requests_running" "sum")
echo "vllm_num_requests_running: [$result]"
