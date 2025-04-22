#!/bin/bash

# This script sets up an EKS cluster with configurations for Aerospike and AVS node pools.
# It handles the creation of the EKS cluster, the use of AKO (Aerospike Kubernetes Operator) to deploy an Aerospike cluster,
# deploys the AVS cluster, and the deployment of necessary operators, configurations, node pools, and monitoring.

set -eo pipefail
export PS4='+($LINENO): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
 set -x
trap 'handle_error ${LINENO}' ERR

WORKSPACE="$(pwd)"
USERNAME=$(whoami)
CHART_VERSION="1.2.0"
REVERSE_DNS_AVS=""
IMAGE_TAG=""

# Default values
DEFAULT_CLUSTER_NAME_SUFFIX="avs"
DEFAULT_MACHINE_TYPE="m5.xlarge"            # 4 vCPUs, 16 GiB RAM - General purpose
DEFAULT_STANDALONE_MACHINE_TYPE="r5.2xlarge" # 8 vCPUs, 64 GiB RAM - Memory optimized
DEFAULT_QUERY_MACHINE_TYPE="m5.xlarge"       # 4 vCPUs, 16 GiB RAM - General purpose
DEFAULT_INDEX_MACHINE_TYPE="m5.xlarge"       # 4 vCPUs, 16 GiB RAM - General purpose
DEFAULT_NUM_AVS_NODES=3
DEFAULT_NUM_QUERY_NODES=1
DEFAULT_NUM_INDEX_NODES=1
DEFAULT_NUM_STANDALONE_NODES=1
DEFAULT_NUM_AEROSPIKE_NODES=1
JFROG_DOCKER_REPO="artifact.aerospike.io/container"
JFROG_HELM_REPO="https://artifact.aerospike.io/helm"
DEFAULT_LOG_LEVEL="info"
DEFAULT_REGION="us-east-1"

# Create log directory if it doesn't exist
LOG_DIR="/tmp/avs-logs"
mkdir -p "$LOG_DIR"

# Set default cluster name if not provided
if [ -z "$CLUSTER_NAME" ]; then
    CLUSTER_NAME="${USERNAME:-$(whoami)}-${DEFAULT_CLUSTER_NAME_SUFFIX:-avs}"
fi

# Create unique log files with cluster name and timestamp for logs
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_PREFIX="${LOG_DIR}/avs-setup-${CLUSTER_NAME}-${TIMESTAMP}-$$"
STDOUT_LOG="${LOG_PREFIX}.log"
STDERR_LOG="${LOG_PREFIX}.err"

# Checkpoint file is cluster-specific, not timestamp-specific
CHECKPOINT_FILE="${LOG_DIR}/avs-setup-${CLUSTER_NAME}.checkpoint"

# Set up logging
exec 1> >(tee "${STDOUT_LOG}")
exec 2> "${STDERR_LOG}"
echo "Logging to:"
echo "  stdout: ${STDOUT_LOG}"
echo "  stderr: ${STDERR_LOG}"
echo "  checkpoint: ${CHECKPOINT_FILE}"

# Define steps in order with their checkpoint names
STEPS=(
    "cluster_created:create_eks_cluster"
    "nodes_created:create_node_groups"
    "nodes_labeled:label_nodes"
    "namespaces_created:create_namespaces"
    "certs_generated:generate_certs"
    "aerospike_setup:setup_aerospike"
    "avs_setup:setup_avs"
    "helm_deployed:deploy_avs_helm_chart"
    "monitoring_setup:setup_monitoring"
)

usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --chart-location, -l <path>           If specified, uses a local directory for AVS Helm chart (default: official repo)"
    echo "  --cluster-name, -c <name>             Override the default cluster name"
    echo "  --image-tag, -g <tag>                 Docker image tag for AVS (default: chart default)"
    echo "  --jfrog-user, -u <name>               JFrog username for pulling unpublished images"
    echo "  --jfrog-token, -t <token>             JFrog token for pulling unpublished images"
    echo "  --jfrog-helm-repo, -H <repo_url>      JFrog Helm repository URL"
    echo "  --jfrog-docker-repo, -D <registry>    JFrog Docker registry prefix"
    echo "  --chart-version, -v <ver>             Helm chart version (default: ${CHART_VERSION})"
    echo "  --machine-type, -m <type>             Specify the default machine type (default: ${DEFAULT_MACHINE_TYPE})"
    echo "  --standalone-machine-type, -S <type>  Specify machine type for standalone nodes (default: ${DEFAULT_STANDALONE_MACHINE_TYPE})"
    echo "  --query-machine-type, -Q <type>       Specify machine type for query nodes (default: ${DEFAULT_QUERY_MACHINE_TYPE})"
    echo "  --index-machine-type, -X <type>       Specify machine type for index nodes (default: ${DEFAULT_INDEX_MACHINE_TYPE})"
    echo "  --num-avs-nodes, -a <num>             Specify the number of AVS nodes (default: ${DEFAULT_NUM_AVS_NODES})"
    echo "  --num-query-nodes, -q <num>           Specify the number of AVS query nodes (default: ${DEFAULT_NUM_QUERY_NODES})"
    echo "  --num-index-nodes, -i <num>           Specify the number of AVS index nodes (default: ${DEFAULT_NUM_INDEX_NODES})"
    echo "  --num-standalone-nodes, -d <num>      Specify the number of AVS standalone nodes (default: ${DEFAULT_NUM_STANDALONE_NODES})"
    echo "  --num-aerospike-nodes, -s <num>       Specify the number of Aerospike nodes (default: ${DEFAULT_NUM_AEROSPIKE_NODES})"
    echo "  --region, -r <region>                 AWS region (default: ${DEFAULT_REGION})"
    echo "  --run-insecure, -I                    Run setup cluster without auth or TLS (no argument)"
    echo "  --cleanup|-C                          Clean up the cluster and exit"
    echo "  --resume|-R                           Resume from last checkpoint"
    echo "  --cleanup-partial|-CP                 Clean up only the failed stage"
    echo "  --help, -h                            Show this help message"
    echo "  --log-level, -L <level>               Set AVS logging level (default: ${DEFAULT_LOG_LEVEL})"
    exit 1
}

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --chart-location|-l) CHART_LOCATION="$2"; shift 2 ;;
        --cluster-name|-c) CLUSTER_NAME="$2"; shift 2 ;;
        --image-tag|-g) IMAGE_TAG="$2"; shift 2 ;;
        --jfrog-user|-u) JFROG_USER="$2"; shift 2 ;;
        --jfrog-token|-t) JFROG_TOKEN="$2"; shift 2 ;;
        --jfrog-helm-repo|-H) JFROG_HELM_REPO="$2"; shift 2 ;;
        --jfrog-docker-repo|-D) JFROG_DOCKER_REPO="$2"; shift 2 ;;
        --chart-version|-v) CHART_VERSION="$2"; shift 2 ;;
        --machine-type|-m) MACHINE_TYPE="$2"; shift 2 ;;
        --standalone-machine-type|-S) STANDALONE_MACHINE_TYPE="$2"; shift 2 ;;
        --query-machine-type|-Q) QUERY_MACHINE_TYPE="$2"; shift 2 ;;
        --index-machine-type|-X) INDEX_MACHINE_TYPE="$2"; shift 2 ;;
        --num-avs-nodes|-a) NUM_AVS_NODES="$2"; shift 2 ;;
        --num-query-nodes|-q) NUM_QUERY_NODES="$2"; shift 2 ;;
        --num-index-nodes|-i) NUM_INDEX_NODES="$2"; shift 2 ;;
        --num-standalone-nodes|-d) NUM_STANDALONE_NODES="$2"; shift 2 ;;
        --num-aerospike-nodes|-s) NUM_AEROSPIKE_NODES="$2"; shift 2 ;;
        --region|-r) REGION="$2"; shift 2 ;;
        --run-insecure|-I) RUN_INSECURE=1; shift ;;
        --cleanup|-C) CLEANUP=1; shift ;;
        --resume|-R) RESUME=1; shift ;;
        --cleanup-partial|-CP) CLEANUP_PARTIAL=1; shift ;;
        --help|-h) usage ;;
        --log-level|-L) LOG_LEVEL="$2"; shift 2 ;;
        *) echo "Unknown parameter passed: $1"; usage ;;
    esac
done

# Function to check dependencies
check_dependencies() {
    local deps=("eksctl" "kubectl" "helm" "aws" "openssl" "keytool" "curl" "jq")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        echo "Error: Missing dependencies: ${missing[*]}"
        echo "Install with:"
        echo "eksctl: https://docs.aws.amazon.com/eks/latest/userguide/eksctl.html"
        echo "kubectl: https://kubernetes.io/docs/tasks/tools/"
        echo "helm: https://helm.sh/docs/intro/install/"
        echo "aws: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
        echo "openssl, keytool, curl, jq: sudo apt-get update && sudo apt-get install -y openssl default-jdk curl jq"
        exit 1
    fi

    # Quick version checks
    echo "Versions:"
    eksctl version || echo "eksctl: unknown"
    kubectl version --client || echo "kubectl: unknown"
    helm version --short || echo "Helm: unknown"
    aws --version || echo "AWS CLI: unknown"
}

# Function to set environment variables
set_env_variables() {
    export NODE_POOL_NAME_AEROSPIKE="aerospike-pool"
    export NODE_POOL_NAME_AVS="avs-pool"
    export REGION="${REGION:-$DEFAULT_REGION}"
    export FEATURES_CONF="$WORKSPACE/features.conf"
    export BUILD_DIR="$WORKSPACE/generated"
    export MACHINE_TYPE="${MACHINE_TYPE:-$DEFAULT_MACHINE_TYPE}"
    export STANDALONE_MACHINE_TYPE="${STANDALONE_MACHINE_TYPE:-$DEFAULT_STANDALONE_MACHINE_TYPE}"
    export QUERY_MACHINE_TYPE="${QUERY_MACHINE_TYPE:-$DEFAULT_QUERY_MACHINE_TYPE}"
    export INDEX_MACHINE_TYPE="${INDEX_MACHINE_TYPE:-$DEFAULT_INDEX_MACHINE_TYPE}"
    export NUM_AVS_NODES="${NUM_AVS_NODES:-$DEFAULT_NUM_AVS_NODES}"
    export NUM_QUERY_NODES="${NUM_QUERY_NODES:-$DEFAULT_NUM_QUERY_NODES}"
    export NUM_INDEX_NODES="${NUM_INDEX_NODES:-$DEFAULT_NUM_INDEX_NODES}"
    export NUM_STANDALONE_NODES="${NUM_STANDALONE_NODES:-$DEFAULT_NUM_STANDALONE_NODES}"
    export NUM_AEROSPIKE_NODES="${NUM_AEROSPIKE_NODES:-$DEFAULT_NUM_AEROSPIKE_NODES}"
    export LOG_LEVEL="${LOG_LEVEL:-$DEFAULT_LOG_LEVEL}"

    if [[ $((NUM_STANDALONE_NODES + NUM_QUERY_NODES + NUM_INDEX_NODES)) -gt $NUM_AVS_NODES ]]; then
        NUM_AVS_NODES=$((NUM_STANDALONE_NODES + NUM_QUERY_NODES + NUM_INDEX_NODES))
        echo "NUM_AVS_NODES adjusted to: $NUM_AVS_NODES (the sum of standalone, query, and index nodes)"
    fi
}

# Function to print environment variables
print_env() {
    echo "Environment Variables:"
    echo "export CLUSTER_NAME=$CLUSTER_NAME"
    echo "export NODE_POOL_NAME_AEROSPIKE=$NODE_POOL_NAME_AEROSPIKE"
    echo "export NODE_POOL_NAME_AVS=$NODE_POOL_NAME_AVS"
    echo "export REGION=$REGION"
    echo "export MACHINE_TYPE=$MACHINE_TYPE"
    echo "export STANDALONE_MACHINE_TYPE=$STANDALONE_MACHINE_TYPE"
    echo "export QUERY_MACHINE_TYPE=$QUERY_MACHINE_TYPE"
    echo "export INDEX_MACHINE_TYPE=$INDEX_MACHINE_TYPE"
    echo "export NUM_AVS_NODES=$NUM_AVS_NODES"
    echo "export NUM_QUERY_NODES=$NUM_QUERY_NODES"
    echo "export NUM_INDEX_NODES=$NUM_INDEX_NODES"
    echo "export NUM_STANDALONE_NODES=$NUM_STANDALONE_NODES"
    echo "export NUM_AEROSPIKE_NODES=$NUM_AEROSPIKE_NODES"
    echo "export LOG_LEVEL=$LOG_LEVEL"
}

# Function to validate inputs
validate_inputs() {
    local errors=0
    
    # Check if AWS CLI is installed and configured
    if ! command -v aws &> /dev/null; then
        echo "Error: AWS CLI is not installed"
        errors=$((errors + 1))
    fi

    # Check if logged into AWS
    if ! aws sts get-caller-identity &> /dev/null; then
        echo "Error: Not logged into AWS. Please run 'aws configure' first"
        errors=$((errors + 1))
    fi

    # Validate node counts
    if [[ "$NUM_AVS_NODES" -lt $((NUM_STANDALONE_NODES + NUM_QUERY_NODES + NUM_INDEX_NODES)) ]]; then
        echo "Error: Total of standalone ($NUM_STANDALONE_NODES), query ($NUM_QUERY_NODES), and index ($NUM_INDEX_NODES) nodes exceeds NUM_AVS_NODES ($NUM_AVS_NODES)"
        errors=$((errors + 1))
    fi

    # Validate machine types exist in AWS
    local machine_types=("$MACHINE_TYPE" "$STANDALONE_MACHINE_TYPE" "$QUERY_MACHINE_TYPE" "$INDEX_MACHINE_TYPE")
    for instance_type in "${machine_types[@]}"; do
        if ! aws ec2 describe-instance-types --instance-types "$instance_type" &> /dev/null; then
            echo "Error: Machine type $instance_type is not available in AWS"
            errors=$((errors + 1))
        fi
    done

    # Check EC2 instance limits
    echo "Checking EC2 instance limits..."
    local total_nodes=$((NUM_AVS_NODES + NUM_AEROSPIKE_NODES))
    
    # Get current running instances
    local current_usage
    current_usage=$(aws ec2 describe-instances \
        --filters "Name=instance-state-name,Values=running" \
        --query 'length(Reservations[*].Instances[*])' \
        --output text) || {
        echo "Warning: Could not check current EC2 usage"
        return 0
    }

    # Get account quota
    local quota_limit
    quota_limit=$(aws ec2 describe-account-attributes \
        --attribute-names max-instances \
        --query 'AccountAttributes[0].AttributeValues[0].AttributeValue' \
        --output text) || {
        echo "Warning: Could not check EC2 quota limits"
        return 0
    }

    if [[ -n "$current_usage" && -n "$quota_limit" ]]; then
        # Convert to integer
        current_usage=$(printf '%.0f' "$current_usage")
        quota_limit=$(printf '%.0f' "$quota_limit")
        
        if ((current_usage + total_nodes > quota_limit)); then
            echo "Warning: Total requested nodes ($total_nodes) may exceed your quota limit ($quota_limit)"
            echo "Current usage: $current_usage"
            echo "Please verify your quota in AWS console"
            echo "You can request a quota increase at: https://console.aws.amazon.com/servicequotas"
        fi
    fi

    # Validate cluster name
    if [[ ! "$CLUSTER_NAME" =~ ^[a-z0-9][-a-z0-9]*[a-z0-9]$ ]]; then
        echo "Error: Cluster name '$CLUSTER_NAME' must consist of lower case alphanumeric characters or '-', and must start and end with an alphanumeric character"
        errors=$((errors + 1))
    fi

    if [[ "$errors" -gt 0 ]]; then
        echo "Found $errors error(s). Please fix the issues and try again."
        exit 1
    fi
}

# Function to create EKS cluster
create_eks_cluster() {
    # Validate inputs before any resource creation
    validate_inputs
    
    if ! eksctl get cluster --name "$CLUSTER_NAME" --region "$REGION" &> /dev/null; then
        echo "Cluster $CLUSTER_NAME does not exist. Creating..."
    else
        echo "Error: Cluster $CLUSTER_NAME already exists. Please use a new cluster name or delete the existing cluster."
        return 1
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting EKS cluster creation..."
    
    # Create cluster with initial node group
    eksctl create cluster \
        --name "$CLUSTER_NAME" \
        --region "$REGION" \
        --node-type "$MACHINE_TYPE" \
        --nodes 1 \
        --managed

    # Setup OIDC provider for IRSA
    echo "Setting up OIDC provider for IRSA..."
    eksctl utils associate-iam-oidc-provider \
        --region "$REGION" \
        --cluster "$CLUSTER_NAME" \
        --approve

    # Create service account and IAM role for EBS CSI driver
    eksctl create iamserviceaccount \
        --name ebs-csi-controller-sa \
        --namespace kube-system \
        --cluster "$CLUSTER_NAME" \
        --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
        --approve \
        --role-name AmazonEKS_EBS_CSI_DriverRole

    # Install EBS CSI Driver addon
    echo "Installing EBS CSI Driver addon..."
    aws eks create-addon \
        --cluster-name "$CLUSTER_NAME" \
        --addon-name aws-ebs-csi-driver \
        --service-account-role-arn "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/AmazonEKS_EBS_CSI_DriverRole" \
        --region "$REGION" \
        --resolve-conflicts OVERWRITE

    # Wait for the addon to be active
    echo "Waiting for EBS CSI Driver addon to be active..."
    while true; do
        status=$(aws eks describe-addon \
            --cluster-name "$CLUSTER_NAME" \
            --addon-name aws-ebs-csi-driver \
            --query "addon.status" \
            --output text)
        
        if [ "$status" = "ACTIVE" ]; then
            echo "EBS CSI Driver addon is active"
            break
        elif [ "$status" = "DEGRADED" ] || [ "$status" = "ERROR" ]; then
            echo "Error: EBS CSI Driver addon installation failed with status: $status"
            return 1
        fi
        
        echo "Waiting for EBS CSI Driver addon to be active (current status: $status)..."
        sleep 10
    done

    # Update kubeconfig
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"
}

# Function to create node groups
create_node_groups() {
    # Create Aerospike node group
    create_node_group "$NODE_POOL_NAME_AEROSPIKE" "$NUM_AEROSPIKE_NODES" "default-rack"

    # Create AVS node groups
    if [ "$NUM_STANDALONE_NODES" -gt 0 ]; then
        create_node_group "avs-standalone-pool" "$NUM_STANDALONE_NODES" "standalone-indexer-nodes"
    fi
    
    if [ "$NUM_QUERY_NODES" -gt 0 ]; then
        create_node_group "avs-query-pool" "$NUM_QUERY_NODES" "query-nodes"
    fi
    
    if [ "$NUM_INDEX_NODES" -gt 0 ]; then
        create_node_group "avs-index-pool" "$NUM_INDEX_NODES" "indexer-nodes"
    fi

    # Create mixed nodes group if needed
    local mixed_nodes=$((NUM_AVS_NODES - NUM_STANDALONE_NODES - NUM_QUERY_NODES - NUM_INDEX_NODES))
    if [ "$mixed_nodes" -gt 0 ]; then
        create_node_group "avs-mixed-pool" "$mixed_nodes" "default-nodes"
    fi
}

# Function to create a single node group
# Arguments:
#   $1: group_name - The name of the node group to create
#   $2: node_count - The number of nodes to create in the group
#   $3: node_role - The role to assign to the nodes (e.g., default-rack, standalone-indexer-nodes)
create_node_group() {
    local group_name=$1
    local node_count=$2
    local node_role=$3
    local machine_type=$MACHINE_TYPE

    case $node_role in
        "default-rack")
            machine_type=$MACHINE_TYPE
            ;;
        "standalone-indexer-nodes")
            machine_type=$STANDALONE_MACHINE_TYPE
            ;;
        "query-nodes")
            machine_type=$QUERY_MACHINE_TYPE
            ;;
        "indexer-nodes")
            machine_type=$INDEX_MACHINE_TYPE
            ;;
    esac

    echo "Creating $group_name node group with machine type $machine_type..."
    
    # Create node group
    eksctl create nodegroup \
        --cluster "$CLUSTER_NAME" \
        --region "$REGION" \
        --name "$group_name" \
        --node-type "$machine_type" \
        --nodes "$node_count" \
        --managed

    # Wait for nodes to be ready
    echo "Waiting for nodes in group $group_name to be ready..."
    local timeout=600
    local interval=20
    local elapsed=0
    
    while true; do
        if kubectl get nodes -l eks.amazonaws.com/nodegroup=$group_name --no-headers 2>/dev/null | grep -q "Ready"; then
            echo "Nodes in group $group_name are ready"
            break
        fi
        
        echo "Waiting for nodes to be ready... (${elapsed}s elapsed)"
        elapsed=$((elapsed + interval))
        if [ "$elapsed" -ge "$timeout" ]; then
            echo "Error: Timeout waiting for nodes to be ready in group $group_name"
            kubectl describe nodes -l eks.amazonaws.com/nodegroup=$group_name
            return 1
        fi
        sleep $interval
    done
}

# Function to label a single node group
# Arguments:
#   $1: group_name - The name of the node group to label
#   $2: node_role - The role to assign to the nodes (e.g., default-rack, standalone-indexer-nodes)
#   $3: node_pool - The node pool label to apply (e.g., default-rack, avs)
label_node_group() {
    local group_name=$1
    local node_role=$2
    local node_pool=$3

    # Skip if this node group doesn't exist
    if ! kubectl get nodes -l eks.amazonaws.com/nodegroup=$group_name -o name &>/dev/null; then
        return
    fi
    
    kubectl get nodes -l eks.amazonaws.com/nodegroup=$group_name -o name | \
        xargs -I '{}' kubectl label '{}' \
            aerospike.io/node-pool=$node_pool \
            aerospike.io/role=$node_role \
            aerospike.io/group=$group_name --overwrite
}

# Function to label all nodes
label_nodes() {
    echo "Labeling all nodes..."
    
    # Label Aerospike nodes
    label_node_group "$NODE_POOL_NAME_AEROSPIKE" "default-rack" "default-rack"

    # Label AVS nodes
    label_node_group "avs-standalone-pool" "standalone-indexer-nodes" "avs"
    label_node_group "avs-query-pool" "query-nodes" "avs"
    label_node_group "avs-index-pool" "indexer-nodes" "avs"
    label_node_group "avs-mixed-pool" "default-nodes" "avs"
}

# Function to create namespaces
create_namespaces() {
    kubectl create namespace aerospike || true
    kubectl create namespace avs || true
}

# Function to create resources if they don't exist
# Arguments:
#   $@: command - The command to execute
create_if_not_exists() {
    output=$("$@" 2>&1) || {
        if ! grep -q "already exists" <<<"$output"; then
            echo "$output" >&2  # Print error if it's not "already exists"
            return 1
        fi
        echo "ignoring already exists error."
    }
    return 0
}

# Function to setup Aerospike
setup_aerospike() {
    echo "Setting up namespaces..."
    create_if_not_exists kubectl create namespace aerospike

    echo "Deploying Aerospike Kubernetes Operator (AKO)..."

    if ! kubectl get ns olm &> /dev/null; then
        echo "Installing OLM..."
        if ! curl -sL https://github.com/operator-framework/operator-lifecycle-manager/releases/download/v0.31.0/install.sh | bash -s v0.31.0; then
            echo "Error: Failed to install OLM"
            exit 1
        fi
    else
        echo "OLM is already installed in olm namespace. Skipping installation."
    fi

    # Check if the subscription already exists
    if ! kubectl get subscription my-aerospike-kubernetes-operator --namespace operators &> /dev/null; then
        echo "Installing AKO subscription..."
        if ! kubectl create -f https://operatorhub.io/install/aerospike-kubernetes-operator.yaml; then
            echo "Error: Failed to create AKO subscription"
            exit 1
        fi
    else
        echo "AKO subscription already exists. Skipping installation."
    fi

    echo "Waiting for AKO to be ready..."
    local timeout=300  # 5 minutes timeout
    local interval=10  # Check every 10 seconds
    local elapsed=0
    
    while true; do
        if kubectl --namespace operators get deployment/aerospike-operator-controller-manager &> /dev/null; then
            echo "AKO deployment found, checking readiness..."
            if kubectl --namespace operators wait --for=condition=available --timeout=30s deployment/aerospike-operator-controller-manager; then
                echo "AKO is ready."
                break
            fi
        else
            echo "AKO setup is still in progress... (${elapsed}s elapsed)"
        fi
        
        elapsed=$((elapsed + interval))
        if [ "$elapsed" -ge "$timeout" ]; then
            echo "Error: Timeout waiting for AKO to be ready"
            exit 1
        fi
        sleep $interval
    done

    echo "Granting permissions to the target namespace..."
    create_if_not_exists kubectl --namespace aerospike create serviceaccount aerospike-operator-controller-manager
    create_if_not_exists kubectl create clusterrolebinding aerospike-cluster \
        --clusterrole=aerospike-cluster --serviceaccount=aerospike:aerospike-operator-controller-manager

    echo "Setting secrets for Aerospike cluster..."
    create_if_not_exists kubectl --namespace aerospike create secret generic aerospike-secret --from-file="$BUILD_DIR/secrets"
    create_if_not_exists kubectl --namespace aerospike create secret generic auth-secret --from-literal=password='admin123'
    if [[ "${RUN_INSECURE}" != 1 ]]; then
        create_if_not_exists kubectl --namespace aerospike create secret generic aerospike-tls \
            --from-file="$BUILD_DIR/certs"
    fi

    echo "Adding storage class..."
    kubectl apply -f ./manifests/eks-storage-class.yaml

    echo "Deploying Aerospike cluster..."
    kubectl apply -f $BUILD_DIR/manifests/aerospike-cr.yaml

    echo "Waiting for Aerospike cluster to be ready..."
    local timeout=600
    local elapsed=0

    while true; do
        status=$(kubectl get aerospikecluster -n aerospike aerocluster -o 'jsonpath={.status.phase}' 2>/dev/null)
        if [[ "$status" == "Completed" ]]; then
            echo "Aerospike cluster is ready (status: Completed)"
            break
        elif [[ "$status" == "Failed" ]]; then
            echo "Error: Aerospike cluster deployment failed"
            kubectl describe aerospikecluster -n aerospike aerocluster
            exit 1
        fi
        
        echo "Waiting for Aerospike cluster to be ready... ($elapsed seconds elapsed)"
        elapsed=$((elapsed + 10))
        if [ "$elapsed" -ge "$timeout" ]; then
            echo "Error: Timeout waiting for Aerospike cluster to be ready"
            kubectl describe aerospikecluster -n aerospike aerocluster
            exit 1
        fi
        sleep 10
    done

    echo "Aerospike setup completed successfully"
}

# Function to setup AVS
setup_avs() {
    kubectl create namespace avs || true 

    echo "Setting secrets for AVS cluster..."
    kubectl --namespace avs create secret generic auth-secret --from-literal=password='admin123'
    kubectl --namespace avs create secret generic aerospike-tls \
        --from-file="$BUILD_DIR/certs"
    kubectl --namespace avs create secret generic aerospike-secret \
        --from-file="$BUILD_DIR/secrets"
}

# Function to deploy AVS Helm chart
deploy_avs_helm_chart() {
    local helm_set_args=()
    local helm_repo_args=()

    if [[ -n "$JFROG_USER" && -n "$JFROG_TOKEN" ]]; then
        kubectl create secret docker-registry jfrog-secret \
            --docker-server=aerospike.jfrog.io \
            --docker-username="$JFROG_USER" \
            --docker-password="$JFROG_TOKEN" \
            --docker-email="$JFROG_USER" \
            --namespace=avs\
            --dry-run=client -o yaml | kubectl apply -f -
        helm_set_args=(--set jfrog.user="$JFROG_USER" --set jfrog.token="$JFROG_TOKEN")
        helm_repo_args=(--username "$JFROG_USER" --password "$JFROG_TOKEN")
    fi

    if [[ -n $IMAGE_TAG ]]; then
        helm_set_args+=(--set image.tag="$IMAGE_TAG")
    fi

    helm repo add aerospike-helm "$JFROG_HELM_REPO" --force-update "${helm_repo_args[@]}"
    helm repo update

    helm install avs-app aerospike-helm/aerospike-vector-search \
        --namespace avs --version "$CHART_VERSION" \
        --set imagePullSecrets[0].name=jfrog-secret \
        --set initContainer.image.repository="$JFROG_DOCKER_REPO/avs-init-container" \
        --set initContainer.image.tag="$CHART_VERSION" \
        --set aerospikeVectorSearchConfig.logging.levels.root="$LOG_LEVEL" \
        --set replicaCount="$NUM_AVS_NODES" \
        --values "$BUILD_DIR/manifests/avs-values.yaml" \
        --atomic --wait --debug --create-namespace "${helm_set_args[@]}"
}

# Function to setup monitoring
setup_monitoring() {
    echo "Adding monitoring setup..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update
    helm install monitoring-stack prometheus-community/kube-prometheus-stack --namespace monitoring --create-namespace

    echo "Applying additional monitoring manifests..."
    kubectl apply -f manifests/monitoring/aerospike-exporter-service.yaml
    kubectl apply -f manifests/monitoring/aerospike-servicemonitor.yaml
    kubectl apply -f manifests/monitoring/avs-servicemonitor.yaml
}

# Function to print final instructions
print_final_instructions() {
    echo "Check your deployment using our command line tool asvec available at https://github.com/aerospike/asvec."

    echo "Use the asvec tool to change your password with"
    echo -n asvec nodes ls --seeds "$(kubectl get nodes --selector=aerospike.io/node-pool=avs --output=jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')"
    echo
    
    if [[ -z "${RUN_INSECURE}" || "${RUN_INSECURE}" == "0" ]]; then
        echo " --tls-cafile $BUILD_DIR/certs/ca.aerospike.com.pem --tls-hostname-override avs-app-aerospike-vector-search.aerospike.svc.cluster.local --credentials admin:admin"
        echo "note: the ca file will be overwritten if the script is re run so copy it over to a safe location"
    fi
    echo "Setup Complete!"
}

# Function to handle errors
handle_error() {
    local exit_code=$?
    local line_number=$1
    echo "Error: Command failed with exit code $exit_code at line $line_number" >&2
    
    # Get the last few lines of kubectl logs if available
    if command -v kubectl &> /dev/null; then
        echo "Recent events:"
        kubectl get events --sort-by='.lastTimestamp' --namespace aerospike 2>/dev/null | tail -n 5 || true
        kubectl get events --sort-by='.lastTimestamp' --namespace avs 2>/dev/null | tail -n 5 || true
        
        echo "Pod status:"
        kubectl get pods -A 2>/dev/null || true
        
        echo "Node status:"
        kubectl get nodes 2>/dev/null || true
        
        echo "Resource usage:"
        kubectl top nodes 2>/dev/null || true
        kubectl top pods -A 2>/dev/null || true
    fi

    # Check AWS service health
    if command -v aws &> /dev/null; then
        echo "Checking AWS service health..."
        aws cloudwatch describe-alarms --alarm-name-prefix "$CLUSTER_NAME" 2>/dev/null || true
    fi
    
    exit $exit_code
}

# Function to cleanup resources
cleanup() {
    echo "Cleaning up resources..."
    
    if [[ "${CLEANUP_PARTIAL}" == 1 ]]; then
        # Get last checkpoint and clean up from there
        local last_checkpoint
        last_checkpoint=$(get_checkpoint)
        case $last_checkpoint in
            "helm_deployed")
                helm uninstall avs-app -n avs || true
                ;;
            "avs_setup")
                kubectl delete namespace avs --timeout=60s || true
                ;;
            "aerospike_setup")
                kubectl delete namespace aerospike --timeout=60s || true
                ;;
            "namespaces_created")
                kubectl delete namespace avs --timeout=60s || true
                kubectl delete namespace aerospike --timeout=60s || true
                ;;
        esac
    else
        # Full cleanup
        if [ -f "$CHECKPOINT_FILE" ]; then
            rm "$CHECKPOINT_FILE"
        fi
        helm uninstall avs-app -n avs || true
        helm uninstall monitoring-stack -n monitoring || true
    kubectl delete namespace avs --timeout=60s || true
    kubectl delete namespace aerospike --timeout=60s || true
    kubectl delete namespace monitoring --timeout=60s || true
        eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION" || true
    fi
}

reset_build() {
    if [ -d "$BUILD_DIR" ]; then
        temp_dir=$(mktemp -d /tmp/avs-deploy-previous.XXXXXX)
        mv -f "$BUILD_DIR" "$temp_dir"
    fi
    mkdir -p "$BUILD_DIR/input" "$BUILD_DIR/output" "$BUILD_DIR/secrets" "$BUILD_DIR/certs" "$BUILD_DIR/manifests"
    cp "$FEATURES_CONF" "$BUILD_DIR/secrets/features.conf"
    cp "$WORKSPACE/manifests/avs-values.yaml" "$BUILD_DIR/manifests/avs-values.yaml"
    cp "$WORKSPACE/manifests/aerospike-cr.yaml" "$BUILD_DIR/manifests/aerospike-cr.yaml"

    # override aerospike-cr.yaml with secure version if run insecure not specified
    if [[ "${RUN_INSECURE}" != 1 ]]; then
        cp $WORKSPACE/manifests/aerospike-cr-auth.yaml $BUILD_DIR/manifests/aerospike-cr.yaml
        cp $WORKSPACE/manifests/avs-values-auth.yaml $BUILD_DIR/manifests/avs-values.yaml
    fi
}

generate_certs() {
    echo "Generating certificates..."
    echo "Generate Root"
    openssl genrsa \
    -out "$BUILD_DIR/output/ca.aerospike.com.key" 2048

    openssl req \
    -x509 \
    -new \
    -nodes \
    -config "$WORKSPACE/ssl/openssl_ca.conf" \
    -extensions v3_ca \
    -key "$BUILD_DIR/output/ca.aerospike.com.key" \
    -sha256 \
    -days 3650 \
    -out "$BUILD_DIR/output/ca.aerospike.com.pem" \
    -subj "/C=UK/ST=London/L=London/O=abs/OU=Support/CN=ca.aerospike.com"

    echo "Generate Requests & Private Key"
    SVC_NAME="aerospike-cluster.aerospike.svc.cluster.local" COMMON_NAME="asd.aerospike.com" openssl req \
    -new \
    -nodes \
    -config "$WORKSPACE/ssl/openssl.conf" \
    -extensions v3_req \
    -out "$BUILD_DIR/input/asd.aerospike.com.req" \
    -keyout "$BUILD_DIR/output/asd.aerospike.com.key" \
    -subj "/C=UK/ST=London/L=London/O=abs/OU=Server/CN=asd.aerospike.com"

    SVC_NAME="avs-app-aerospike-vector-search.aerospike.svc.cluster.local" COMMON_NAME="avs.aerospike.com" openssl req \
    -new \
    -nodes \
    -config "$WORKSPACE/ssl/openssl.conf" \
    -extensions v3_req \
    -out "$BUILD_DIR/input/avs.aerospike.com.req" \
    -keyout "$BUILD_DIR/output/avs.aerospike.com.key" \
    -subj "/C=UK/ST=London/L=London/O=abs/OU=Client/CN=avs.aerospike.com"

    SVC_NAME="avs-app-aerospike-vector-search.aerospike.svc.cluster.local" COMMON_NAME="svc.aerospike.com" openssl req \
    -new \
    -nodes \
    -config "$WORKSPACE/ssl/openssl_svc.conf" \
    -extensions v3_req \
    -out "$BUILD_DIR/input/svc.aerospike.com.req" \
    -keyout "$BUILD_DIR/output/svc.aerospike.com.key" \
    -subj "/C=UK/ST=London/L=London/O=abs/OU=Client/CN=svc.aerospike.com"

    echo "Generate Certificates"
    SVC_NAME="aerospike-cluster.aerospike.svc.cluster.local" COMMON_NAME="asd.aerospike.com" openssl x509 \
    -req \
    -extfile "$WORKSPACE/ssl/openssl.conf" \
    -in "$BUILD_DIR/input/asd.aerospike.com.req" \
    -CA "$BUILD_DIR/output/ca.aerospike.com.pem" \
    -CAkey "$BUILD_DIR/output/ca.aerospike.com.key" \
    -extensions v3_req \
    -days 3649 \
    -outform PEM \
    -out "$BUILD_DIR/output/asd.aerospike.com.pem" \
    -set_serial 110

    SVC_NAME="avs-app-aerospike-vector-search.aerospike.svc.cluster.local" COMMON_NAME="avs.aerospike.com" openssl x509 \
    -req \
    -extfile "$WORKSPACE/ssl/openssl.conf" \
    -in "$BUILD_DIR/input/avs.aerospike.com.req" \
    -CA "$BUILD_DIR/output/ca.aerospike.com.pem" \
    -CAkey "$BUILD_DIR/output/ca.aerospike.com.key" \
    -extensions v3_req \
    -days 3649 \
    -outform PEM \
    -out "$BUILD_DIR/output/avs.aerospike.com.pem" \
    -set_serial 210

    SVC_NAME="avs-app-aerospike-vector-search.aerospike.svc.cluster.local" COMMON_NAME="svc.aerospike.com" openssl x509 \
    -req \
    -extfile "$WORKSPACE/ssl/openssl_svc.conf" \
    -in "$BUILD_DIR/input/svc.aerospike.com.req" \
    -CA "$BUILD_DIR/output/ca.aerospike.com.pem" \
    -CAkey "$BUILD_DIR/output/ca.aerospike.com.key" \
    -extensions v3_req \
    -days 3649 \
    -outform PEM \
    -out "$BUILD_DIR/output/svc.aerospike.com.pem" \
    -set_serial 310

    echo "Verify Certificate signed by root"
    openssl verify \
    -verbose \
    -CAfile "$BUILD_DIR/output/ca.aerospike.com.pem" \
    "$BUILD_DIR/output/asd.aerospike.com.pem"

    openssl verify \
    -verbose \
    -CAfile "$BUILD_DIR/output/ca.aerospike.com.pem" \
    "$BUILD_DIR/output/avs.aerospike.com.pem"

    openssl verify \
    -verbose \
    -CAfile "$BUILD_DIR/output/ca.aerospike.com.pem" \
    "$BUILD_DIR/output/svc.aerospike.com.pem"

    PASSWORD="citrusstore"
    echo -n "$PASSWORD" | tee "$BUILD_DIR/output/storepass" \
    "$BUILD_DIR/output/keypass" > \
    "$BUILD_DIR/secrets/client-password.txt"

    ADMIN_PASSWORD="admin123"
    echo -n "$ADMIN_PASSWORD" > "$BUILD_DIR/secrets/aerospike-password.txt"

    keytool \
    -import \
    -file "$BUILD_DIR/output/ca.aerospike.com.pem" \
    --storepass "$PASSWORD" \
    -keystore "$BUILD_DIR/output/ca.aerospike.com.truststore.jks" \
    -alias "ca.aerospike.com" \
    -noprompt

    openssl pkcs12 \
    -export \
    -out "$BUILD_DIR/output/avs.aerospike.com.p12" \
    -in "$BUILD_DIR/output/avs.aerospike.com.pem" \
    -inkey "$BUILD_DIR/output/avs.aerospike.com.key" \
    -password file:"$BUILD_DIR/output/storepass"

    keytool \
    -importkeystore \
    -srckeystore "$BUILD_DIR/output/avs.aerospike.com.p12" \
    -destkeystore "$BUILD_DIR/output/avs.aerospike.com.keystore.jks" \
    -srcstoretype pkcs12 \
    -srcstorepass "$(cat $BUILD_DIR/output/storepass)" \
    -deststorepass "$(cat $BUILD_DIR/output/storepass)" \
    -noprompt

    openssl pkcs12 \
    -export \
    -out "$BUILD_DIR/output/svc.aerospike.com.p12" \
    -in "$BUILD_DIR/output/svc.aerospike.com.pem" \
    -inkey "$BUILD_DIR/output/svc.aerospike.com.key" \
    -password file:"$BUILD_DIR/output/storepass"

    keytool \
    -importkeystore \
    -srckeystore "$BUILD_DIR/output/svc.aerospike.com.p12" \
    -destkeystore "$BUILD_DIR/output/svc.aerospike.com.keystore.jks" \
    -srcstoretype pkcs12 \
    -srcstorepass "$(cat $BUILD_DIR/output/storepass)" \
    -deststorepass "$(cat $BUILD_DIR/output/storepass)" \
    -noprompt

    mv "$BUILD_DIR/output/svc.aerospike.com.keystore.jks" \
    "$BUILD_DIR/certs/svc.aerospike.com.keystore.jks"

    mv "$BUILD_DIR/output/avs.aerospike.com.keystore.jks" \
    "$BUILD_DIR/certs/avs.aerospike.com.keystore.jks"

    mv "$BUILD_DIR/output/ca.aerospike.com.truststore.jks" \
    "$BUILD_DIR/certs/ca.aerospike.com.truststore.jks"

    mv "$BUILD_DIR/output/asd.aerospike.com.pem" \
    "$BUILD_DIR/certs/asd.aerospike.com.pem"

    mv "$BUILD_DIR/output/avs.aerospike.com.pem" \
    "$BUILD_DIR/certs/avs.aerospike.com.pem"

    mv "$BUILD_DIR/output/svc.aerospike.com.pem" \
    "$BUILD_DIR/certs/svc.aerospike.com.pem"

    mv "$BUILD_DIR/output/asd.aerospike.com.key" \
    "$BUILD_DIR/certs/asd.aerospike.com.key"

    mv "$BUILD_DIR/output/ca.aerospike.com.pem" \
    "$BUILD_DIR/certs/ca.aerospike.com.pem"

    mv "$BUILD_DIR/output/keypass" \
    "$BUILD_DIR/certs/keypass"

    mv "$BUILD_DIR/output/storepass" \
    "$BUILD_DIR/certs/storepass"

    echo "Generate Auth Keys"
    openssl genpkey \
    -algorithm RSA \
    -out "$BUILD_DIR/secrets/private_key.pem" \
    -pkeyopt rsa_keygen_bits:2048 \
    -pass "pass:$PASSWORD"

    openssl rsa \
    -pubout \
    -in "$BUILD_DIR/secrets/private_key.pem" \
    -out "$BUILD_DIR/secrets/public_key.pem" \
    -passin "pass:$PASSWORD"
}

# Function to save checkpoint
# Arguments:
#   $1: checkpoint - The checkpoint name to save
save_checkpoint() {
    echo "$1" > "$CHECKPOINT_FILE"
    echo "Checkpoint saved: $1"
}

# Function to get last checkpoint
# Returns:
#   The last checkpoint name or "none" if no checkpoint exists
get_checkpoint() {
    if [ -f "$CHECKPOINT_FILE" ]; then
        cat "$CHECKPOINT_FILE"
    else
        echo "none"
    fi
}

# Function to verify cluster state
# Arguments:
#   $1: state - The state to verify (e.g., cluster_created, namespaces_created)
verify_cluster_state() {
    local state=$1
    case $state in
        "cluster_created")
            if ! eksctl get cluster --name "$CLUSTER_NAME" --region "$REGION" &> /dev/null; then
                return 1
            fi
            # Check if all expected nodes are present
            local expected_nodes=$((NUM_AVS_NODES + NUM_AEROSPIKE_NODES + 1)) # +1 for control plane
            local actual_nodes
            actual_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
            if [ "$actual_nodes" -ne "$expected_nodes" ]; then
                return 1
            fi
            ;;
        "namespaces_created")
            if ! kubectl get namespace aerospike &>/dev/null || ! kubectl get namespace avs &>/dev/null; then
                return 1
            fi
            ;;
        "aerospike_setup")
            if ! kubectl get aerospikecluster -n aerospike aerocluster &>/dev/null; then
                return 1
            fi
            ;;
        "avs_setup")
            if ! kubectl get secret -n avs auth-secret &>/dev/null; then
                return 1
            fi
            ;;
        "helm_deployed")
            if ! helm status avs-app -n avs &>/dev/null; then
                return 1
            fi
            ;;
        "monitoring_setup")
            if ! kubectl get namespace monitoring &>/dev/null; then
                return 1
            fi
            ;;
    esac
    return 0
}

# Function to get step index
# Arguments:
#   $1: checkpoint - The checkpoint name to find the index for
get_step_index() {
    local checkpoint=$1
    for i in "${!STEPS[@]}"; do
        if [[ "$(get_checkpoint_from_step "${STEPS[$i]}")" == "$checkpoint" ]]; then
            echo "$i"
            return 0
        fi
    done
    echo "-1"
    return 1
}

# Function to execute steps from checkpoint
execute_from_checkpoint() {
    local start_index=0
    
    # If resuming, find where to start
    if [[ "${RESUME}" == 1 && -f "${CHECKPOINT_FILE}" ]]; then
        last_checkpoint=$(cat "${CHECKPOINT_FILE}")
        echo "Debug: Found checkpoint: $last_checkpoint"
        
        # Verify the state of the last checkpoint before resuming
        if ! verify_cluster_state "$last_checkpoint"; then
            echo "Error: Cluster state verification failed for checkpoint: $last_checkpoint"
            echo "The cluster state does not match the checkpoint. Please clean up and start fresh."
            exit 1
        fi
        
        start_index=$(($(get_step_index "$last_checkpoint") + 1))
        echo "Debug: Calculated start_index: $start_index"
        
        if [[ $start_index -eq 0 ]]; then
            echo "Error: Invalid checkpoint found: $last_checkpoint"
            exit 1
        fi
    else
        echo "Debug: Not resuming or checkpoint file not found"
        echo "Debug: RESUME=$RESUME"
        echo "Debug: CHECKPOINT_FILE=$CHECKPOINT_FILE"
    fi

    # Execute steps in sequence
    for ((i=start_index; 
          i < ${#STEPS[@]}; 
          i++)); do
        
        local step="${STEPS[$i]}"
        local checkpoint="$(get_checkpoint_from_step "$step")"
        local function_name="$(get_function_from_step "$step")"
        
        # Skip cert generation if running insecure
        if [[ "$checkpoint" == "certs_generated" && "${RUN_INSECURE}" == 1 ]]; then
            echo "Skipping certificate generation (running insecure)"
            continue
        fi

        echo "Executing step $((i + 1))/${#STEPS[@]}: $function_name"
        $function_name
        
        # Verify the state after executing the function
        if ! verify_cluster_state "$checkpoint"; then
            echo "Error: Cluster state verification failed after executing: $function_name"
            echo "The cluster state does not match the expected state for checkpoint: $checkpoint"
            return 1
        fi
        
        save_checkpoint "$checkpoint"
    done
}

# Main function
main() {
    check_dependencies
    set_env_variables
    print_env
    
    if [[ "${CLEANUP}" == 1 || "${CLEANUP_PARTIAL}" == 1 ]]; then
        cleanup
        exit 0
    fi
    
    execute_from_checkpoint
    print_final_instructions
}

# Run the main function
main