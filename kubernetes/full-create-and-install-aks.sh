#!/bin/bash

# This script sets up an AKS cluster with configurations for Aerospike and AVS node pools.
# It handles the creation of the AKS cluster, the use of AKO (Aerospike Kubernetes Operator) to deploy an Aerospike cluster,
# deploys the AVS cluster, and the deployment of necessary operators, configurations, node pools, and monitoring.

#!/usr/bin/env bash

# Create unique log file in /tmp using username and project
LOG_FILE="/tmp/avs-setup-${USER}-$(date +%Y%m%d_%H%M%S)-$$.log"
# Set up logging - capture all stdout and stderr to file while still showing on console
exec 1> >(tee "${LOG_FILE}")
exec 2> >(tee "${LOG_FILE}_err")

echo "Logging to ${LOG_FILE}"

set -eo pipefail
# Add line numbers to debug output by modifying PS4
export PS4='+($LINENO): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
if [ -n "$DEBUG" ]; then set -x; fi
trap 'echo "Error: $? at line $LINENO" >&2' ERR

WORKSPACE="$(pwd)"
USERNAME=$(whoami)
CHART_VERSION="1.1.0"
REVERSE_DNS_AVS=""
IMAGE_TAG=""

# Default values
DEFAULT_CLUSTER_NAME_SUFFIX="avs"
DEFAULT_MACHINE_TYPE="Standard_D4s_v3"       # 4 vCPU, 16GB memory - General purpose
DEFAULT_STANDALONE_MACHINE_TYPE="Standard_F32s_v2"  # 32 vCPU, 64GB memory - Compute optimized
DEFAULT_QUERY_MACHINE_TYPE="Standard_D4s_v3"      # 4 vCPU, 16GB memory - General purpose
DEFAULT_INDEX_MACHINE_TYPE="Standard_D4s_v3"       # 4 vCPU, 16GB memory - General purpose
DEFAULT_DEFAULT_MACHINE_TYPE="Standard_D4s_v3"    # 4 vCPU, 16GB memory - General purpose
DEFAULT_NUM_AVS_NODES=3
DEFAULT_NUM_QUERY_NODES=1
DEFAULT_NUM_INDEX_NODES=1
DEFAULT_NUM_STANDALONE_NODES=1
DEFAULT_NUM_AEROSPIKE_NODES=1
JFROG_DOCKER_REPO="artifact.aerospike.io/container"
JFROG_HELM_REPO="https://artifact.aerospike.io/helm"
DEFAULT_LOG_LEVEL="info"

usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --chart-location, -l <path>           If specified, uses a local directory for AVS Helm chart (default: official repo)"
    echo "  --cluster-name, -c <name>             Override the default cluster name"
    echo "  --image-tag, -g <tag>                 Docker image tag for AVS (default: chart default)"
    echo "  --jfrog-user, -u <name>               JFrog username for pulling unpublished images"
    echo "  --jfrog-token, -t <token>             JFrog token for pulling unpublished images"
    echo "  --jfrog-helm-repo, -H <repo_url>      JFrog Helm repository URL (e.g. https://.../helm/<repo>)"
    echo "  --jfrog-docker-repo, -D <registry>    JFrog Docker registry prefix (e.g. artifact.aerospike.io/container)"
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
    echo "  --run-insecure, -I                    Run setup cluster without auth or TLS (no argument)."
    echo "  --cleanup|-C                          Clean up the cluster and exit"
    echo "  --help, -h                            Show this help message"
    echo "  --log-level, -L <level>               Set AVS logging level (default: ${DEFAULT_LOG_LEVEL})"
    echo
    echo "Shell completion:"
    echo "  Bash: source completions/avs-aks.bash"
    echo "  Fish: source completions/avs-aks.fish"
    exit 1
}

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --chart-location|-l)
            CHART_LOCATION="$2"
            shift 2
            ;;
        --cluster-name|-c)
            CLUSTER_NAME_OVERRIDE="$2"
            shift 2
            ;;
        --image-tag|-g)
            IMAGE_TAG="$2"
            shift 2
            ;;
        --jfrog-user|-u)
            JFROG_USER="$2"
            shift 2
            ;;
        --jfrog-token|-t)
            JFROG_TOKEN="$2"
            shift 2
            ;;
        --jfrog-helm-repo|-H)
            JFROG_HELM_REPO="$2"
            shift 2
            ;;
        --jfrog-docker-repo|-D)
            JFROG_DOCKER_REPO="$2"
            shift 2
            ;;
        --chart-version|-v)
            CHART_VERSION="$2"
            shift 2
            ;;
        --machine-type|-m)
            MACHINE_TYPE="$2"
            shift 2
            ;;
        --standalone-machine-type|-S)
            STANDALONE_MACHINE_TYPE="$2"
            shift 2
            ;;
        --query-machine-type|-Q)
            QUERY_MACHINE_TYPE="$2"
            shift 2
            ;;
        --index-machine-type|-X)
            INDEX_MACHINE_TYPE="$2"
            shift 2
            ;;
        --num-avs-nodes|-a)
            NUM_AVS_NODES="$2"
            shift 2
            ;;
        --num-standalone-nodes|-d)
            NUM_STANDALONE_NODES="$2"
            NODE_TYPES=1
            shift 2
            ;;
        --num-query-nodes|-q)
            NUM_QUERY_NODES="$2"
            NODE_TYPES=1
            shift 2
            ;;
        --num-index-nodes|-i)
            NUM_INDEX_NODES="$2"
            NODE_TYPES=1
            shift 2
            ;;
        --num-aerospike-nodes|-s)
            NUM_AEROSPIKE_NODES="$2"
            shift 2
            ;;
        --run-insecure|-I)
            RUN_INSECURE=1
            shift
            ;;
        --cleanup|-C)
            CLEANUP=1
            shift
            ;;
        --help|-h)
            usage
            ;;
        --log-level|-L)
            LOG_LEVEL="$2"
            shift 2
            ;;
        *)
            echo "Unknown parameter passed: $1"
            usage
            ;;
    esac
done

# Function to check if all required dependencies are installed
check_dependencies() {
    local deps=("az" "kubectl" "helm" "openssl" "keytool" "curl" "jq")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        echo "Error: Missing dependencies: ${missing[*]}"
        echo "Install with: sudo apt-get update && sudo apt-get install -y azure-cli kubectl helm openssl default-jdk curl jq"
        echo "For cloud-specific tools:"
        echo "Azure CLI: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
        echo "kubectl: https://kubernetes.io/docs/tasks/tools/"
        echo "Helm: https://helm.sh/docs/intro/install/"
        exit 1
    fi

    # Quick version checks
    echo "Versions:"
    az version --output tsv --query '"azure-cli"' 2>/dev/null || echo "Azure CLI: unknown"
    kubectl version --client --short 2>/dev/null || echo "kubectl: unknown"
    helm version --short 2>/dev/null || echo "Helm: unknown"
}

# Function to print environment variables for verification
print_env() {
    echo "Environment Variables:"
    echo "export CLUSTER_NAME=$CLUSTER_NAME"
    echo "export NODE_POOL_NAME_AEROSPIKE=$NODE_POOL_NAME_AEROSPIKE"
    echo "export NODE_POOL_NAME_AVS=$NODE_POOL_NAME_AVS"
    echo "CHART_LOCATION       = ${CHART_LOCATION:-'(not specified)'}"
    echo "CLUSTER_NAME_OVERRIDE= ${CLUSTER_NAME_OVERRIDE:-'(not specified)'}"
    echo "IMAGE_TAG            = ${IMAGE_TAG:-'(not specified)'}"
    echo "JFROG_USER           = ${JFROG_USER:-'(not specified)'}"
    echo "JFROG_TOKEN          = ${JFROG_TOKEN:-'(not specified)'}"
    echo "MACHINE_TYPE         = ${MACHINE_TYPE:-$DEFAULT_MACHINE_TYPE}"
    echo "STANDALONE_MACHINE_TYPE = ${STANDALONE_MACHINE_TYPE:-$DEFAULT_STANDALONE_MACHINE_TYPE}"
    echo "QUERY_MACHINE_TYPE     = ${QUERY_MACHINE_TYPE:-$DEFAULT_QUERY_MACHINE_TYPE}"
    echo "INDEX_MACHINE_TYPE     = ${INDEX_MACHINE_TYPE:-$DEFAULT_INDEX_MACHINE_TYPE}"
    echo "NUM_AVS_NODES        = ${NUM_AVS_NODES:-$DEFAULT_NUM_AVS_NODES}"
    echo "NUM_QUERY_NODES      = ${NUM_QUERY_NODES:-$DEFAULT_NUM_QUERY_NODES}"
    echo "NUM_INDEX_NODES      = ${NUM_INDEX_NODES:-$DEFAULT_NUM_INDEX_NODES}"
    echo "NUM_STANDALONE_NODES = ${NUM_STANDALONE_NODES:-$DEFAULT_NUM_STANDALONE_NODES}"
    echo "NUM_AEROSPIKE_NODES  = ${NUM_AEROSPIKE_NODES:-$DEFAULT_NUM_AEROSPIKE_NODES}"
    echo "RUN_INSECURE         = ${RUN_INSECURE:-0}"
    echo "LOG_LEVEL            = ${LOG_LEVEL:-$DEFAULT_LOG_LEVEL}"
}

# Function to set environment variables
set_env_variables() {
    # Use provided cluster name or fallback to the default
    if [ -n "$CLUSTER_NAME_OVERRIDE" ]; then
        export CLUSTER_NAME="${USERNAME}-${CLUSTER_NAME_OVERRIDE}"
    else
        export CLUSTER_NAME="${USERNAME}-${DEFAULT_CLUSTER_NAME_SUFFIX}"
    fi

    export NODE_POOL_NAME_AEROSPIKE="aerospike-pool"
    export NODE_POOL_NAME_AVS="avs-pool"
    export LOCATION="eastus"
    export FEATURES_CONF="$WORKSPACE/features.conf"
    export BUILD_DIR="$WORKSPACE/generated"
    export REVERSE_DNS_AVS="does.not.exist"
    export MACHINE_TYPE="${MACHINE_TYPE:-${DEFAULT_MACHINE_TYPE}}"
    export STANDALONE_MACHINE_TYPE="${STANDALONE_MACHINE_TYPE:-${DEFAULT_STANDALONE_MACHINE_TYPE}}"
    export QUERY_MACHINE_TYPE="${QUERY_MACHINE_TYPE:-${DEFAULT_QUERY_MACHINE_TYPE}}"
    export INDEX_MACHINE_TYPE="${INDEX_MACHINE_TYPE:-${DEFAULT_INDEX_MACHINE_TYPE}}"
    export NUM_AVS_NODES="${NUM_AVS_NODES:-${DEFAULT_NUM_AVS_NODES}}"
    export NUM_QUERY_NODES="${NUM_QUERY_NODES:-${DEFAULT_NUM_QUERY_NODES}}"
    export NUM_INDEX_NODES="${NUM_INDEX_NODES:-${DEFAULT_NUM_INDEX_NODES}}"
    export NUM_STANDALONE_NODES="${NUM_STANDALONE_NODES:-${DEFAULT_NUM_STANDALONE_NODES}}"
    export NUM_AEROSPIKE_NODES="${NUM_AEROSPIKE_NODES:-${DEFAULT_NUM_AEROSPIKE_NODES}}"
    export LOG_LEVEL="${LOG_LEVEL:-${DEFAULT_LOG_LEVEL}}"

    # Create resource group name
    export RESOURCE_GROUP="${CLUSTER_NAME}-rg"

    if [[ $((NUM_STANDALONE_NODES + NUM_QUERY_NODES + NUM_INDEX_NODES)) -gt $NUM_AVS_NODES ]]; then
        NUM_AVS_NODES=$((NUM_STANDALONE_NODES + NUM_QUERY_NODES + NUM_INDEX_NODES))
        echo "NUM_AVS_NODES adjusted to: $NUM_AVS_NODES (the sum of standalone, query, and index nodes)"
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
    # cp -r $WORKSPACE/certs $BUILD_DIR/certs
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
    -subj "/C=UK/ST=London/L=London/O=abs/OU=Client/CN=avs.aerospike.com" \

    SVC_NAME="avs-app-aerospike-vector-search.aerospike.svc.cluster.local" COMMON_NAME="svc.aerospike.com" openssl req \
    -new \
    -nodes \
    -config "$WORKSPACE/ssl/openssl_svc.conf" \
    -extensions v3_req \
    -out "$BUILD_DIR/input/svc.aerospike.com.req" \
    -keyout "$BUILD_DIR/output/svc.aerospike.com.key" \
    -subj "/C=UK/ST=London/L=London/O=abs/OU=Client/CN=svc.aerospike.com" \

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
    -set_serial 110 \

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
    -set_serial 210 \

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
    -set_serial 310 \

    echo "Verify Certificate signed by root"
    openssl verify \
    -verbose \
    -CAfile "$BUILD_DIR/output/ca.aerospike.com.pem" \
    "$BUILD_DIR/output/asd.aerospike.com.pem"

    openssl verify \
    -verbose\
    -CAfile "$BUILD_DIR/output/ca.aerospike.com.pem" \
    "$BUILD_DIR/output/asd.aerospike.com.pem"

    openssl verify \
    -verbose\
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

# Function to create AKS cluster
create_aks_cluster() {
    if ! az aks show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" &> /dev/null; then
        echo "Cluster $CLUSTER_NAME does not exist. Creating..."
    else
        echo "Error: Cluster $CLUSTER_NAME already exists. Please use a new cluster name or delete the existing cluster."
        return
    fi
    
    validate_inputs

    # Create resource group
    echo "Creating resource group..."
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

    echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting AKS cluster creation..."
    az aks create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$CLUSTER_NAME" \
        --node-count 1 \
        --enable-cluster-autoscaler \
        --min-count 1 \
        --max-count 5 \
        --node-vm-size "$MACHINE_TYPE"

    # Create Aerospike node pool
    create_node_pool "$NODE_POOL_NAME_AEROSPIKE" "$NUM_AEROSPIKE_NODES" "default-rack"

    # Create AVS node pools
    if [ "$NUM_STANDALONE_NODES" -gt 0 ]; then
        create_node_pool "avs-standalone-pool" "$NUM_STANDALONE_NODES" "standalone-indexer-nodes"
    fi
    
    if [ "$NUM_QUERY_NODES" -gt 0 ]; then
        create_node_pool "avs-query-pool" "$NUM_QUERY_NODES" "query-nodes"
    fi
    
    if [ "$NUM_INDEX_NODES" -gt 0 ]; then
        create_node_pool "avs-index-pool" "$NUM_INDEX_NODES" "indexer-nodes"
    fi

    # Create mixed nodes pool if needed
    local mixed_nodes=$((NUM_AVS_NODES - NUM_STANDALONE_NODES - NUM_QUERY_NODES - NUM_INDEX_NODES))
    if [ "$mixed_nodes" -gt 0 ]; then
        create_node_pool "avs-mixed-pool" "$mixed_nodes" "default-nodes"
    fi

    # Get credentials
    az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME"
}

create_namespaces() {
    kubectl create namespace aerospike || true
    kubectl create namespace avs || true
}

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
    kubectl apply -f https://raw.githubusercontent.com/aerospike/aerospike-kubernetes-operator/master/config/samples/storage/gce_ssd_storage_class.yaml

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

# Function to setup AVS node pool and namespace
setup_avs() {
    kubectl create namespace avs || true 

    echo "Setting secrets for AVS cluster..."
    kubectl --namespace avs create secret generic auth-secret --from-literal=password='admin123'
    kubectl --namespace avs create secret generic aerospike-tls \
        --from-file="$BUILD_DIR/certs"
    kubectl --namespace avs create secret generic aerospike-secret \
        --from-file="$BUILD_DIR/secrets"

}


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

  # Set logging level
  helm_set_args+=(--set aerospikeVectorSearchConfiglogging.levels.root="$LOG_LEVEL")

  helm repo add aerospike-helm "$JFROG_HELM_REPO" --force-update "${helm_repo_args[@]}"
  helm repo update

  helm install avs-app aerospike-helm/aerospike-vector-search \
    --namespace avs --version "$CHART_VERSION" \
    --set imagePullSecrets[0].name=jfrog-secret \
    --set initContainer.image.repository="$JFROG_DOCKER_REPO/avs-init-container" \
    --set initContainer.image.tag="$CHART_VERSION" \
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

create_node_pool() {
    local pool_name=$1
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

    echo "Creating $pool_name pool with machine type $machine_type..."
    
    az aks nodepool add \
        --resource-group "$RESOURCE_GROUP" \
        --cluster-name "$CLUSTER_NAME" \
        --name "${pool_name//-/}" \
        --node-count "$node_count" \
        --node-vm-size "$machine_type" \
        --enable-cluster-autoscaler \
        --min-count "$node_count" \
        --max-count $((node_count * 2))

    echo "Labeling $pool_name nodes..."
    local label_value
    if [[ "$node_role" == "default-rack" ]]; then
        label_value="default-rack"
    else
        label_value="avs"
    fi

    # Wait for nodes to be ready before labeling
    echo "Waiting for nodes to be ready..."
    sleep 30  # Give some time for nodes to register

    kubectl get nodes -l agentpool=${pool_name//-/} -o name | \
        xargs -I '{}' kubectl label '{}' \
            aerospike.io/node-pool=$label_value \
            aerospike.io/role-label=$node_role --overwrite
}

validate_inputs() {
    local errors=0
    
    # Check if Azure CLI is installed
    if ! command -v az &> /dev/null; then
        echo "Error: Azure CLI (az) is not installed"
        errors=$((errors + 1))
    fi

    # Check if logged into Azure
    if ! az account show &> /dev/null; then
        echo "Error: Not logged into Azure. Please run 'az login' first"
        errors=$((errors + 1))
    fi

    if [[ "$NUM_AVS_NODES" -lt $((NUM_STANDALONE_NODES + NUM_QUERY_NODES + NUM_INDEX_NODES)) ]]; then
        echo "Error: Total of standalone ($NUM_STANDALONE_NODES), query ($NUM_QUERY_NODES), and index ($NUM_INDEX_NODES) nodes exceeds NUM_AVS_NODES ($NUM_AVS_NODES)"
        errors=$((errors + 1))
    fi

    if [[ "$errors" -gt 0 ]]; then
        echo "Found $errors error(s). Exiting."
        exit 1
    fi
}

cleanup() {
    echo "Cleaning up resources..."
    
    # Delete the entire resource group
    echo "Deleting resource group $RESOURCE_GROUP..."
    az group delete --name "$RESOURCE_GROUP" --yes --no-wait
}

#This script runs in this order.
main() {
    check_dependencies
    set_env_variables
    print_env
    
    if [[ "${CLEANUP}" == 1 ]]; then
        cleanup
        exit 0
    fi
    
    reset_build
    create_aks_cluster
    create_namespaces
    if [[ "${RUN_INSECURE}" != 1 ]]; then
        generate_certs
    fi
    setup_aerospike
    setup_avs
    deploy_avs_helm_chart
    setup_monitoring
    print_final_instructions
}

# Add this function for error handling
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
    fi
    
    exit $exit_code
}

main