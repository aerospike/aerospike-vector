#!/bin/bash
# Add line numbers to debug output by modifying PS4
export PS4='+($LINENO): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
trap 'handle_error ${LINENO}' ERR
handle_error() {
  local lineno=$1
  echo "❌ Script exited with error at line $lineno"
  exit 1
}

# set -euo pipefail
if [ "${DEBUG:-false}" = true ]; then
  set -x
fi


# Configuration
NAMESPACE="avs"
INIT_CONTAINER="config-injector"
CONFIG_PATH="/etc/aerospike-vector-search/aerospike-vector-search.yml"
OUTPUT_DIR="./avs-inspection-output"
TMP_FILE="avs-full-context.txt"
MARKDOWN_REPORT="$OUTPUT_DIR/analysis.md"
TEXT_SUMMARY="$OUTPUT_DIR/summary-report.txt"
MODEL="gpt-4o"
# Ensure OpenAI CLI is installed
command -v openai >/dev/null 2>&1 || {
  echo >&2 "❌ OpenAI CLI not found. Install with: pip install openai"; exit 1;
}

# Ensure output directory is clean
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

echo "📦 Collecting diagnostics from namespace: $NAMESPACE"
echo "" > "$TMP_FILE"

# Function to process and summarize GC histogram
process_gc_histogram() {
    local input_file="$1"
    local output_file="$2"
    cat "$input_file"
    
    {
        echo "=== GC Histogram Summary ==="
        echo "Top $TOP_CLASSES memory-consuming classes:"
        # Skip header (first 3 lines), then take top N entries
        tail -n +4 "$input_file" | head -n $TOP_CLASSES
        
        echo -e "\n=== Memory Usage Statistics ==="
        # Calculate total instances and bytes from the full histogram
        tail -n +4 "$input_file" | awk '
            BEGIN { total_instances=0; total_bytes=0 }
            { 
                total_instances += $2; 
                total_bytes += $3;
            }
            END { 
                printf "Total Instances: %d\nTotal Bytes: %d\nAverage Bytes per Instance: %.2f\n", 
                    total_instances, total_bytes, (total_bytes/total_instances)
            }'
    } > "$output_file"
}

# Function to collect node information
collect_node_info() {
    local node="$1"
    local NODE_DIR="$OUTPUT_DIR/nodes/$node"
    mkdir -p "$NODE_DIR"

    echo "📊 Collecting node information for: $node"
    {
        echo "=== Node Description ==="
        kubectl describe node "$node"
        echo -e "\n=== Node Resources ==="
        kubectl get node "$node" -o json | jq '.status.capacity'
        echo -e "\n=== Node Allocatable Resources ==="
        kubectl get node "$node" -o json | jq '.status.allocatable'
        echo -e "\n=== Node Conditions ==="
        kubectl get node "$node" -o json | jq '.status.conditions'
        
        echo -e "\n=== Cloud Instance Information ==="
        # Get common labels
        local labels=$(kubectl get node "$node" -o json | jq -r '.metadata.labels')
        local instance_type=$(echo "$labels" | jq -r '."node.kubernetes.io/instance-type" // "N/A"')
        local region=$(echo "$labels" | jq -r '."topology.kubernetes.io/region" // "N/A"')
        local zone=$(echo "$labels" | jq -r '."topology.kubernetes.io/zone" // "N/A"')

        # Determine cloud provider from labels
        local cloud_provider="On-premises"
        if echo "$labels" | jq -e '."eks.amazonaws.com"' >/dev/null; then
            cloud_provider="AWS"
        elif echo "$labels" | jq -e '."cloud.google.com"' >/dev/null; then
            cloud_provider="GCP"
            # For GCP, use machine-type if available
            instance_type=$(echo "$labels" | jq -r '."cloud.google.com/machine-type" // "'$instance_type'"')
        elif echo "$labels" | jq -e '."kubernetes.azure.com"' >/dev/null; then
            cloud_provider="Azure"
        fi

        echo "Cloud Provider: $cloud_provider"
        echo "Instance Type: $instance_type"
        echo "Region: $region"
        echo "Zone: $zone"

        echo -e "\n=== OOMKill Events ==="
        # Get system OOM events from kernel logs
        echo "System OOM Events:"
        kubectl debug node/"$node" -it --image=ubuntu -- dmesg | grep -i "oom-killer" || echo "No system OOM events found"
        
        # Get Kubernetes OOM events
        echo -e "\nKubernetes OOMKill Events:"
        kubectl get events -n "$NAMESPACE" --field-selector type=Warning | grep -i "OOMKilled" || echo "No Kubernetes OOM events found"

        echo -e "\n=== Node OOMKill Events ==="
        # 1. Get system OOM events
        echo "System OOM Events (last 24h):"
        # Using debug node to access system logs
        kubectl debug node/"$node" -it --image=ubuntu -- journalctl --since "24 hours ago" | grep -i "oom-killer" || \
            echo "No system OOM events found"

        # 2. Get all pod OOMKills on this node
        echo -e "\nPod OOMKills on this node:"
        kubectl get pods -A -o json --field-selector spec.nodeName="$node" | \
            jq '.items[] | select(.status.containerStatuses != null) | 
                .status.containerStatuses[] | select(.lastState.terminated.reason=="OOMKilled") |
                "Pod \(.name) OOMKilled at \(.lastState.terminated.finishedAt)"' || \
            echo "No pod OOMKills found"
    } > "$NODE_DIR/node-info.txt"
}

# Function to collect pod information
collect_pod_info() {
    local pod="$1"
    local node="$2"
    local POD_DIR="$OUTPUT_DIR/nodes/$node/pods/$pod"
    
    echo "🔍 Inspecting pod: $pod on node: $node"
  mkdir -p "$POD_DIR"

  # 1. Config file
  kubectl exec -n "$NAMESPACE" "$pod" -- cat "$CONFIG_PATH" > "$POD_DIR/config.yml" 2>/dev/null || \
    echo "❌ Failed to fetch config" | tee "$POD_DIR/config.yml"

  # 2. Init container logs
  kubectl logs -n "$NAMESPACE" "$pod" -c "$INIT_CONTAINER" > "$POD_DIR/init-container.log" 2>/dev/null || \
    echo "❌ Failed to fetch init container logs" | tee "$POD_DIR/init-container.log"

  # 3. JVM info
  kubectl exec -n "$NAMESPACE" "$pod" -- sh -c '
    pid=$(jcmd | grep -m1 aerospike-vector | awk "{print \$1}")
    if [ -z "$pid" ]; then
      echo "❌ No Java process found via jcmd" | tee "$POD_DIR/jvm-info.txt"
    else
      echo "➡️ jcmd $pid VM.flags:"
      jcmd "$pid" VM.flags
      echo ""
      echo "➡️ jcmd $pid GC.heap_info:"
      jcmd "$pid" GC.heap_info
      echo ""
      echo "➡️ getting full java command line for pid $pid:"
      ps $pid 
      
    fi
  ' > "$POD_DIR/jvm-info.txt" 2>/dev/null || \
    echo "❌ jcmd not available in $pod" | tee "$POD_DIR/jvm-info.txt"

  # 4. GC class histogram
  kubectl exec -n "$NAMESPACE" "$pod" -- sh -c '
    pid=$(jcmd | grep -m1 aerospike-vector | awk "{print \$1}")
    if [ ! -z "$pid" ]; then
      jcmd "$pid" GC.class_histogram
    fi
  ' > "$POD_DIR/gc-class-histogram.txt" 2>/dev/null || \
    echo "❌ GC.class_histogram unavailable" | tee "$POD_DIR/gc-class-histogram.txt"

  # Append to full context
  {
    echo "=============================="
    echo "🧵 POD: $pod"
        echo "Running on node: $node"
    echo "=============================="
        echo "=== Node Information ==="
        cat "$OUTPUT_DIR/nodes/$node/node-info.txt"
        echo -e "\n=== Pod Information ==="

        for file in config.yml init-container.log jvm-info.txt; do # cannot add gc-class-histogram.txt because it's too large
      if [ -f "$POD_DIR/$file" ]; then
        echo -e "\n📄 FILE: $file"
        echo "------------------------------"
        cat "$POD_DIR/$file"
      fi
    done

    echo -e "\n\n"
  } >> "$TMP_FILE"

  echo "✅ Finished pod: $pod"

    echo -e "\n=== Pod Status and History ==="
    # Get full pod status including all container statuses and restart counts
    kubectl get pod "$pod" -n "$NAMESPACE" -o json > "$POD_DIR/pod-status.json"
    
    # Extract restart history and reasons
    {
        echo "Container Status Summary:"
        jq -r '.status.containerStatuses[] | "Container: \(.name)\nRestart Count: \(.restartCount)\nLast State: \(.lastState)\nCurrent State: \(.state)\n---"' "$POD_DIR/pod-status.json"
        
        echo -e "\nPrevious Terminations (including OOMKills):"
        jq -r '.status.containerStatuses[] | 
            select(.lastState.terminated != null) | 
            "Container: \(.name)\nReason: \(.lastState.terminated.reason)\nExit Code: \(.lastState.terminated.exitCode)\nFinished At: \(.lastState.terminated.finishedAt)\nMessage: \(.lastState.terminated.message)\n---"' "$POD_DIR/pod-status.json"
        
        # Get historical events for this pod
        echo -e "\nPod Events History (last 1 hour):"
        kubectl get events -n "$NAMESPACE" --field-selector involvedObject.name="$pod" \
            --sort-by='.lastTimestamp' > "$POD_DIR/pod-events.txt"
        cat "$POD_DIR/pod-events.txt"
        
        # Check node pressure at time of restarts
        echo -e "\nNode Conditions at Recent Restarts:"
        kubectl get node "$node" -o json | jq '.status.conditions[] | select(.type | test("Memory|Pressure|Disk"))' > "$POD_DIR/node-conditions.json"
        cat "$POD_DIR/node-conditions.json"
    } > "$POD_DIR/restart-history.txt"

    # Add to the context file
    {
        echo -e "\n=== Pod Restart and OOMKill History ==="
        cat "$POD_DIR/restart-history.txt"
        
        # Add memory metrics
        echo -e "\n=== Memory Metrics ==="
        echo "Container Memory Request: $(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.containers[0].resources.requests.memory}')"
        echo "Container Memory Limit: $(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.spec.containers[0].resources.limits.memory}')"
        
        if [ -f "$POD_DIR/jvm-info.txt" ]; then
            echo -e "\nJVM Memory Settings:"
            grep -A 5 "VM.flags" "$POD_DIR/jvm-info.txt" || echo "No JVM flags found"
            echo -e "\nHeap Info:"
            grep -A 5 "GC.heap_info" "$POD_DIR/jvm-info.txt" || echo "No heap info found"
        fi
    } >> "$TMP_FILE"
}

# Function to collect and aggregate node information
collect_node_aggregates() {
    local NODE_AGGREGATES_FILE="$OUTPUT_DIR/node-aggregates.json"
    
    # Initialize JSON structure
    echo '{"nodes": []}' > "$NODE_AGGREGATES_FILE"
    
    # Collect information for each node
    for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
        NODE_DIR="$OUTPUT_DIR/nodes/$node"
        
        # Get node capacity and allocatable resources
        local capacity=$(kubectl get node "$node" -o json | jq '.status.capacity')
        local allocatable=$(kubectl get node "$node" -o json | jq '.status.allocatable')
        
        # Get cloud provider information
        local labels=$(kubectl get node "$node" -o json | jq -r '.metadata.labels')
        local instance_type=$(echo "$labels" | jq -r '."node.kubernetes.io/instance-type" // "N/A"')
        local region=$(echo "$labels" | jq -r '."topology.kubernetes.io/region" // "N/A"')
        local zone=$(echo "$labels" | jq -r '."topology.kubernetes.io/zone" // "N/A"')
        
        # Determine cloud provider
        local cloud_provider="On-premises"
        if echo "$labels" | jq -e '."eks.amazonaws.com"' >/dev/null; then
            cloud_provider="AWS"
        elif echo "$labels" | jq -e '."cloud.google.com"' >/dev/null; then
            cloud_provider="GCP"
            instance_type=$(echo "$labels" | jq -r '."cloud.google.com/machine-type" // "'$instance_type'"')
        elif echo "$labels" | jq -e '."kubernetes.azure.com"' >/dev/null; then
            cloud_provider="Azure"
        fi
        
        # Get node conditions
        local conditions=$(kubectl get node "$node" -o json | jq '.status.conditions')
        
        # Get AVS pods on this node
        local avs_pods=()
        if [ -d "$NODE_DIR/pods" ]; then
            for pod_dir in "$NODE_DIR/pods"/*; do
                if [ -d "$pod_dir" ]; then
                    pod=$(basename "$pod_dir")
                    # Get pod memory requests and limits
                    local memory_request=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.spec.containers[0].resources.requests.memory}')
                    local memory_limit=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.spec.containers[0].resources.limits.memory}')
                    
                    # Get JVM heap info if available
                    local heap_info=""
                    if [ -f "$pod_dir/jvm-info.txt" ]; then
                        heap_info=$(grep -A 2 "GC.heap_info" "$pod_dir/jvm-info.txt" || echo "")
                    fi
                    
                    # Create pod JSON with proper escaping
                    local pod_json=$(jq -n \
                        --arg name "$pod" \
                        --arg memory_request "$memory_request" \
                        --arg memory_limit "$memory_limit" \
                        --arg heap_info "$heap_info" \
                        '{
                            "name": $name,
                            "memory_request": $memory_request,
                            "memory_limit": $memory_limit,
                            "heap_info": $heap_info
                        }')
                    avs_pods+=("$pod_json")
                fi
            done
        fi
        
        # Create node JSON with proper escaping
        local node_json=$(jq -n \
            --arg name "$node" \
            --argjson capacity "$capacity" \
            --argjson allocatable "$allocatable" \
            --arg cloud_provider "$cloud_provider" \
            --arg instance_type "$instance_type" \
            --arg region "$region" \
            --arg zone "$zone" \
            --argjson conditions "$conditions" \
            --argjson avs_pods "[$(IFS=,; echo "${avs_pods[*]}")]" \
            '{
                "name": $name,
                "capacity": $capacity,
                "allocatable": $allocatable,
                "cloud_provider": $cloud_provider,
                "instance_type": $instance_type,
                "region": $region,
                "zone": $zone,
                "conditions": $conditions,
                "avs_pods": $avs_pods
            }')
        
        # Add node to aggregates using jq
        jq --argjson node "$node_json" '.nodes += [$node]' "$NODE_AGGREGATES_FILE" > "$NODE_AGGREGATES_FILE.tmp"
        mv "$NODE_AGGREGATES_FILE.tmp" "$NODE_AGGREGATES_FILE"
    done
}

# First, collect all node information
echo "🌐 Collecting node information..."
for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
    collect_node_info "$node"
done

# Then, process AVS pods on each node
echo "📦 Processing AVS pods..."
for pod in $(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}'); do
    node=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.spec.nodeName}')
    collect_pod_info "$pod" "$node"
done

# After collecting all node information, collect aggregates
echo "📊 Collecting node aggregates..."
collect_node_aggregates

# NEW CODE STARTS HERE
# GPT prompt for node analysis
NODE_PROMPT=$(cat <<EOF
You are analyzing a Kubernetes node and its Aerospike Vector Search pods.

For this node:
- 🖥️ Analyze node capacity, allocatable resources, and conditions
- 🏷️ Review cloud provider details and instance type
- 📊 Evaluate resource allocation and utilization
- 🔍 Check for any node-level issues or warnings

For each AVS pod on this node:
- 🔍 Review 'aerospike-vector-search.yml': validate node roles, heartbeat seeds, listener addresses, and interconnect settings
- 📦 Summarize JVM flags, especially memory/Garbage Collector settings. Include the Xms and Xmx settings.
- 📈 Analyze GC.heap_info and GC.class_histogram for pressure or leaks
- 🔍analyze the full java command line in jvm-info.txt for the pod and extract any JVM flags that are set
- 🛠️ Highlight any failed config-injection logs

Provide specific recommendations for:
1. Node-level optimizations
2. Pod-level configurations
3. Resource allocation adjustments
4. Performance improvements
5. JVM memory settings

Include specific identifiers for the node and pods in your analysis. 
Include use of emojis to make the report more engaging.
EOF
)

# Analyze each node and its pods
echo "🤖 Analyzing nodes and their pods..."
for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
    echo "Analyzing node: $node"
    NODE_DIR="$OUTPUT_DIR/nodes/$node"
    NODE_ANALYSIS_FILE="$NODE_DIR/analysis.md"
    NODE_TMP_FILE="$NODE_DIR/node-context.txt"
    NODE_REQUEST_FILE="$NODE_DIR/request.json"
    NODE_RESPONSE_FILE="$NODE_DIR/response.json"

    # Create node context including its pods
    {
        echo "=============================="
        echo "🖥️ NODE: $node"
        echo "=============================="
        echo -e "\n=== Node Information ==="
        cat "$NODE_DIR/node-info.txt"
        
        # Find and include information for all AVS pods on this node
        if [ -d "$NODE_DIR/pods" ]; then
            echo -e "\n=== AVS Pods on Node ==="
            for pod_dir in "$NODE_DIR/pods"/*; do
                if [ -d "$pod_dir" ]; then
                    pod=$(basename "$pod_dir")
                    echo -e "\n🧵 POD: $pod"
                    echo "------------------------------"
                    for file in config.yml init-container.log jvm-info.txt; do
                        if [ -f "$pod_dir/$file" ]; then
                            echo -e "\n📄 FILE: $file"
                            echo "------------------------------"
                            cat "$pod_dir/$file"
                        fi
                    done
                fi
            done
        else
            echo -e "\n❌ No AVS pods found on this node"
        fi
    } > "$NODE_TMP_FILE"

    # Create the request JSON
    {
        echo '{
            "model": "'"$MODEL"'",
            "temperature": 0.3,
            "messages": [
                {
                    "role": "system",
                    "content": "'"$NODE_PROMPT"'"
                },
                {
                    "role": "user",
                    "content": "'"$(cat "$NODE_TMP_FILE" | sed 's/"/\\"/g')"'"
                }
            ]
        }'
    } > "$NODE_REQUEST_FILE"

    # Make the API call
    curl https://api.openai.com/v1/chat/completions \
        -sS \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d @"$NODE_REQUEST_FILE" > "$NODE_RESPONSE_FILE"

    echo "GPT Analysis for node $node"
    cat "$NODE_RESPONSE_FILE" | jq -r '.choices[0].message.content' | tee "$NODE_ANALYSIS_FILE"

    echo "✅ Analysis for node $node complete"
    echo "  - Analysis report: $NODE_ANALYSIS_FILE"
done

# After individual node analysis, create cluster-wide summary
echo "🤖 Generating cluster-wide analysis..."

# Create cluster summary context
CLUSTER_TMP_FILE="$OUTPUT_DIR/cluster-context.txt"
CLUSTER_REQUEST_FILE="$OUTPUT_DIR/cluster-request.json"
CLUSTER_RESPONSE_FILE="$OUTPUT_DIR/cluster-response.json"

# Collect cluster-wide metrics
{
    echo "=============================="
    echo "🌐 CLUSTER OVERVIEW"
    echo "=============================="

    # Use the aggregated node information to create a detailed summary table
    echo -e "\n=== Node Summary Table ==="
    echo "| Node Name | Total Memory | Allocatable Memory | AVS Pod Memory (Requested vs Used) | Instance Type | Status/Health | Cloud Provider | Region |"
    echo "|----------|--------------|-------------------|-----------------------------------|---------------|--------------|----------------|--------|"
    
    # Process each node from the aggregates
    jq -r '.nodes[] | 
        .name as $node |
        .avs_pods[0] as $pod |
        (.capacity.memory | if . then . else "N/A" end) as $total_mem |
        (.allocatable.memory | if . then . else "N/A" end) as $alloc_mem |
        ($pod.memory_request | if . then . else "N/A" end) as $request |
        ($pod.heap_info // "" | if . != "" then 
            (match("used ([0-9]+[MG])") | .captures[0].string) // "N/A"
        else "N/A" end) as $used |
        (.instance_type | if . then . else "N/A" end) as $instance_type |
        (.cloud_provider | if . then . else "N/A" end) as $cloud_provider |
        (.region | if . then . else "N/A" end) as $region |
        (.conditions[] | select(.type=="Ready") | if .status=="True" then "Healthy" else "Warning" end) as $status |
        "| \($node) | \($total_mem) | \($alloc_mem) | \($request) vs \($used) | \($instance_type) | \($status) | \($cloud_provider) | \($region) |"' \
        "$OUTPUT_DIR/node-aggregates.json"

    echo -e "\n=== Cluster Resources ==="
    kubectl describe nodes | grep -A 4 "Allocated resources"
    
    echo -e "\n=== Node Details ==="
    for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
        echo -e "\n--- Node: $node ---"
        cat "$OUTPUT_DIR/nodes/$node/node-info.txt"
        
        echo -e "\n  AVS Pods on node:"
        if [ -d "$OUTPUT_DIR/nodes/$node/pods" ]; then
            for pod_dir in "$OUTPUT_DIR/nodes/$node/pods"/*; do
                if [ -d "$pod_dir" ]; then
                    pod=$(basename "$pod_dir")
                    echo -e "\n    Pod: $pod"
                    echo "    Memory Request: $(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.spec.containers[0].resources.requests.memory}')"
                    echo "    Memory Limit: $(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.spec.containers[0].resources.limits.memory}')"
                    if [ -f "$pod_dir/jvm-info.txt" ]; then
                        echo "    JVM Memory Info:"
                        grep -A 2 "GC.heap_info" "$pod_dir/jvm-info.txt"
                    fi
                fi
            done
        else
            echo "    No AVS pods"
        fi
    done

    echo -e "\n=== Cluster-wide OOMKill Analysis ==="
    {
        echo "Summary of Pod Restarts and OOMKills across cluster:"
        
        # Get all pods with their restart counts
        kubectl get pods -n "$NAMESPACE" -o json | \
            jq -r '.items[] | "Pod: \(.metadata.name)\nNode: \(.spec.nodeName)\nRestarts: \(.status.containerStatuses[0].restartCount)\nAge: \(.metadata.creationTimestamp)"'
        
        echo -e "\nDetailed Restart Analysis:"
        kubectl get pods -n "$NAMESPACE" -o json | \
            jq -r '.items[] | select(.status.containerStatuses[0].restartCount > 0) | 
                "Pod: \(.metadata.name)\nNode: \(.spec.nodeName)\n" +
                (.status.containerStatuses[] | 
                "Container: \(.name)\nRestart Count: \(.restartCount)\n" +
                if .lastState.terminated != null then
                    "Last Termination:\n  Reason: \(.lastState.terminated.reason)\n  Exit Code: \(.lastState.terminated.exitCode)\n  Finished At: \(.lastState.terminated.finishedAt)\n  Message: \(.lastState.terminated.message)"
                else "No termination information" end + "\n---")'
        
        echo -e "\nNode Memory Pressure Events:"
        for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
            echo -e "\nNode: $node"
            kubectl get events --field-selector involvedObject.name="$node",type=Warning | \
                grep -i -E "memory|pressure|oom" || echo "No memory pressure events found"
        done
    } >> "$CLUSTER_TMP_FILE"
}

# Cluster analysis prompt
CLUSTER_PROMPT=$(cat <<EOF
You are analyzing an Aerospike Vector Search cluster deployment.

Generate a comprehensive cluster analysis report with the following sections:

1. Resource Overview Table
   - Create a table showing each node's:
     * Total Memory (from node-aggregates.json)
     * Allocatable Memory (from node-aggregates.json)
     * AVS pods on node (with name from node-aggregates.json) and JVM Configuration JVM Flags:
     * Instance Type (from node-aggregates.json)
     * Status/Health (from node-aggregates.json)

2. Cluster Health Assessment
   - Memory distribution across nodes (using node-aggregates.json)
   - Resource allocation patterns (using node-aggregates.json)
   - GC pressure indicators (from pod JVM info)
   - Node conditions (from node-aggregates.json)

3. Key Metrics
   - Total cluster memory (sum from node-aggregates.json)
   - Average memory per AVS pod (calculated from node-aggregates.json)
   - Memory utilization percentages (calculated from node-aggregates.json)
   - Resource efficiency (calculated from node-aggregates.json)

4. Potential Issues
   - Memory pressure points (from node conditions and OOM events)
   - Resource imbalances (from node-aggregates.json)
   - GC concerns (from pod JVM info)
   - Configuration inconsistencies (from pod configs)

5. OOMKill Analysis
   - Detailed timeline of all OOMKill events found:
     * Container restart history
     * Previous termination states
     * System OOM events
     * Pod events
   
   - For each OOMKill event analyze:
     * JVM heap settings at the time
     * Node memory capacity
     * Whether it was an isolated incident or part of a pattern
     * Correlation with memory pressure or other events

6. Memory Configuration Assessment
   - Compare nodes/pods with and without OOMKills
   - Analyze if OOMKills correlate with:
     * Higher heap/node memory ratios
     * Specific workload patterns
     * Time of day or specific events
   
7. Recommendations
   - Specific memory configuration changes
   - System-level improvements
   - Monitoring enhancements
   - Prevention strategies

Provide a clear timeline of OOMKill events and their context.
Highlight patterns and potential root causes.

Pay special attention to:
- Pod restart counts and timing
- Last termination states and reasons
- Exit codes (137 indicates OOMKill)
- Time correlation between restarts and node pressure
- Pattern of restarts across the cluster
- Reletive uptime of the pods

When analyzing OOMKills:
1. Look at both container termination states AND system events
2. Check if restarts happened close to memory pressure events
3. Compare memory settings of pods that restarted vs stable pods
4. Consider the timing of restarts relative to pod age
5. Consider the relative uptime of the pods (if nodes restart it looks like 0 restarts)
Use the aggregated node information from node-aggregates.json to ensure accurate and consistent reporting of node resources, instance types, and cloud provider details.

Format the report exactly as shown in the example, with proper markdown formatting and consistent spacing. Please make use of emojis to make the report more engaging.
EOF
)

# Create the final report
{
    # Collect node-specific information for the analysis
    NODE_ANALYSIS_CONTENT=""
    for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
        if [ -f "$OUTPUT_DIR/nodes/$node/analysis.md" ]; then
            NODE_ANALYSIS_CONTENT+="\n### Node: $node\n"
            NODE_ANALYSIS_CONTENT+=$(cat "$OUTPUT_DIR/nodes/$node/analysis.md")
            NODE_ANALYSIS_CONTENT+="\n"
        fi
    done
    
    # Create the cluster analysis request with node-specific information
    {
        echo '{
            "model": "'"$MODEL"'",
            "temperature": 0.3,
            "messages": [
                {
                    "role": "system",
                    "content": "'"$CLUSTER_PROMPT"'"
                },
                {
                    "role": "user",
                    "content": "'"$(cat "$CLUSTER_TMP_FILE" | sed 's/"/\\"/g')"'\n\nNode-Specific Analysis:\n'"$(echo -e "$NODE_ANALYSIS_CONTENT" | sed 's/"/\\"/g')"'"
                }
            ]
        }'
    } > "$CLUSTER_REQUEST_FILE"

    # Make the API call for cluster analysis
    curl https://api.openai.com/v1/chat/completions \
        -sS \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -H "Content-Type: application/json" \
        -d @"$CLUSTER_REQUEST_FILE" > "$CLUSTER_RESPONSE_FILE"
    

    cat "$CLUSTER_RESPONSE_FILE" | jq -r '.choices[0].message.content' 

    
    # Append detailed node analysis
    echo -e "\n## Detailed Node Analysis\n"
    for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
        if [ -f "$OUTPUT_DIR/nodes/$node/analysis.md" ]; then
            echo -e "\n### Node: $node\n"
            cat "$OUTPUT_DIR/nodes/$node/analysis.md"
        fi
    done
} > "$MARKDOWN_REPORT"

cp "$MARKDOWN_REPORT" "$TEXT_SUMMARY"

echo "✅ Cluster analysis complete"
echo "✅ Final report written to: $MARKDOWN_REPORT"
echo "✅ Text summary written to: $TEXT_SUMMARY"
echo "🎉 Full bundle inspection and analysis complete!"
