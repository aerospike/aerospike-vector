#!/bin/bash

# This script sets up a GKE cluster with configurations for Aerospike and AVS node pools.
# It handles the creation of the GKE cluster, the use of AKO (Aerospike Kubernetes Operator) to deploy an Aerospike cluster,
# deploys the AVS cluster, and the deployment of necessary operators, configurations, node pools, and monitoring.

#!/usr/bin/env bash
set -eo pipefail
if [ -n "$DEBUG" ]; then set -x; fi
trap 'echo "Error: $? at line $LINENO" >&2' ERR

WORKSPACE="$(pwd)"
PROJECT_ID="$(gcloud config get-value project)"
# Prepend the current username to the cluster name
USERNAME=$(whoami)
CHART_VERSION="0.8.0"
REVERSE_DNS_AVS=""
SET_NODEPORT=0

# Default values
DEFAULT_CLUSTER_NAME_SUFFIX="avs"
DEFAULT_MACHINE_TYPE="n2d-standard-4"
DEFAULT_NUM_AVS_NODES=3
DEFAULT_NUM_QUERY_NODES=2
DEFAULT_NUM_INDEX_NODES=1
DEFAULT_NUM_AEROSPIKE_NODES=1
JFROG_DOCKER_REPO="artifact.aerospike.io/container"
JFROG_HELM_REPO="https://artifact.aerospike.io/helm"

usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --chart-location, -l <path>           If specified, uses a local directory for AVS Helm chart (default: official repo)"
    echo "  --cluster-name, -c <name>             Override the default cluster name"
    echo "  --jfrog-user, -u <name>               JFrog username for pulling unpublished images"
    echo "  --jfrog-token, -t <token>             JFrog token for pulling unpublished images"
    echo "  --jfrog-helm-repo, -H <repo_url>      JFrog Helm repository URL (e.g. https://.../helm/<repo>)"
    echo "  --jfrog-docker-repo, -D <registry>    JFrog Docker registry prefix (e.g. artifact.aerospike.io/container)"
    echo "  --chart-version, -v <ver>             Helm chart version (default: ${CHART_VERSION})"
    echo "  --machine-type, -m <type>             Specify the machine type (default: ${DEFAULT_MACHINE_TYPE})"
    echo "  --num-avs-nodes, -a <num>             Specify the number of AVS nodes (default: ${DEFAULT_NUM_AVS_NODES})"
    echo "  --num-query-nodes, -q <num>           Specify the number of AVS query nodes (default: ${DEFAULT_NUM_QUERY_NODES})"
    echo "  --num-index-nodes, -i <num>           Specify the number of AVS index nodes (default: ${DEFAULT_NUM_INDEX_NODES})"
    echo "  --num-aerospike-nodes, -s <num>       Specify the number of Aerospike nodes (default: ${DEFAULT_NUM_AEROSPIKE_NODES})"
    echo "  --run-insecure, -I                    Run setup cluster without auth or TLS (no argument)."
    echo "  --set-nodeport, -n                    Expose AVS to external network using NodePort service"
    echo "  --help, -h                            Show this help message"
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
        --num-avs-nodes|-a)
            NUM_AVS_NODES="$2"
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
        --set-nodeport|-n)
            SET_NODEPORT=1
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "Unknown parameter passed: $1"
            usage
            ;;
    esac
done


if [ -n "$NODE_TYPES" ]
then
    if ((RUN_INSECURE != 1 && NODE_TYPES == 1)); then
        echo "Error: This script has a limitation that it cannot currently use both node types and secure mode. For secure deployments please do not set num-query-nodes nor num-index-nodes."
        exit 1
    fi

    echo "setting number of nodes equal to query + index nodes"
    # Causes the the bug when set replica set is 3 but the node-pool is of size 2
#    NUM_AVS_NODES=$((NUM_QUERY_NODES + NUM_INDEX_NODES))
fi



# Function to print environment variables for verification
print_env() {
    echo "Environment Variables:"
    echo "export PROJECT_ID=$PROJECT_ID"
    echo "export CLUSTER_NAME=$CLUSTER_NAME"
    echo "export NODE_POOL_NAME_AEROSPIKE=$NODE_POOL_NAME_AEROSPIKE"
    echo "export NODE_POOL_NAME_AVS=$NODE_POOL_NAME_AVS"
    echo "CHART_LOCATION       = ${CHART_LOCATION:-'(not specified)'}"
    echo "CLUSTER_NAME_OVERRIDE= ${CLUSTER_NAME_OVERRIDE:-'(not specified)'}"
    echo "JFROG_USER           = ${JFROG_USER:-'(not specified)'}"
    echo "JFROG_TOKEN          = ${JFROG_TOKEN:-'(not specified)'}"
    echo "MACHINE_TYPE         = ${MACHINE_TYPE:-$DEFAULT_MACHINE_TYPE}"
    echo "NUM_AVS_NODES        = ${NUM_AVS_NODES:-$DEFAULT_NUM_AVS_NODES}"
    echo "NUM_QUERY_NODES      = ${NUM_QUERY_NODES:-$DEFAULT_NUM_QUERY_NODES}"
    echo "NUM_INDEX_NODES      = ${NUM_INDEX_NODES:-$DEFAULT_NUM_INDEX_NODES}"
    echo "NUM_AEROSPIKE_NODES  = ${NUM_AEROSPIKE_NODES:-$DEFAULT_NUM_AEROSPIKE_NODES}"
    echo "RUN_INSECURE         = ${RUN_INSECURE:-0}"
    echo "SET_NODEPORT         = ${SET_NODEPORT:-0}"
}

# Function to set environment variables
set_env_variables() {
    # Use provided cluster name or fallback to the default
    if [ -n "$CLUSTER_NAME_OVERRIDE" ]; then
        export CLUSTER_NAME="${USERNAME}-${CLUSTER_NAME_OVERRIDE}"
    else
        export CLUSTER_NAME="${USERNAME}-${PROJECT_ID}-${DEFAULT_CLUSTER_NAME_SUFFIX}"
    fi

    export NODE_POOL_NAME_AEROSPIKE="aerospike-pool"
    export NODE_POOL_NAME_AVS="avs-pool"
    export ZONE="us-central1-c"
    export FEATURES_CONF="$WORKSPACE/features.conf"
    export BUILD_DIR="$WORKSPACE/generated"
    export REVERSE_DNS_AVS="does.not.exist"
    export MACHINE_TYPE="${MACHINE_TYPE:-${DEFAULT_MACHINE_TYPE}}"
    export NUM_AVS_NODES="${NUM_AVS_NODES:-${DEFAULT_NUM_AVS_NODES}}"
    export NUM_QUERY_NODES="${NUM_QUERY_NODES:-${DEFAULT_NUM_QUERY_NODES}}"
    export NUM_INDEX_NODES="${NUM_INDEX_NODES:-${DEFAULT_NUM_INDEX_NODES}}"
    export NUM_AEROSPIKE_NODES="${NUM_AEROSPIKE_NODES:-${DEFAULT_NUM_AEROSPIKE_NODES}}"
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

# Function to create GKE cluster
create_gke_cluster() {
    if ! gcloud container clusters describe "$CLUSTER_NAME" --zone "$ZONE" &> /dev/null; then
        echo "Cluster $CLUSTER_NAME does not exist. Creating..."
    else
        # currently erroring early if cluster already exists. If you would like to recreate remove this block
        echo "Error: Cluster $CLUSTER_NAME already exists. Please use a new cluster name or delete the existing cluster."
        return
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting GKE cluster creation..."
    gcloud container clusters create "$CLUSTER_NAME" \
        --project "$PROJECT_ID" \
        --zone "$ZONE" \
        --num-nodes 1 \
        --disk-type "pd-standard" \
        --disk-size "100";

    echo "Creating Aerospike node pool..."
    gcloud container node-pools create "$NODE_POOL_NAME_AEROSPIKE" \
        --cluster "$CLUSTER_NAME" \
        --project "$PROJECT_ID" \
        --zone "$ZONE" \
        --num-nodes "$NUM_AEROSPIKE_NODES" \
        --local-ssd-count 2 \
        --disk-type "pd-standard" \
        --disk-size "100" \
        --machine-type "$MACHINE_TYPE";

    echo "Labeling Aerospike nodes..."
    kubectl get nodes -l cloud.google.com/gke-nodepool="$NODE_POOL_NAME_AEROSPIKE" -o name | \
        xargs -I {} kubectl label {} aerospike.io/node-pool=default-rack --overwrite

    echo "Adding AVS node pool..."
    gcloud container node-pools create "$NODE_POOL_NAME_AVS" \
        --cluster "$CLUSTER_NAME" \
        --project "$PROJECT_ID" \
        --zone "$ZONE" \
        --num-nodes "$NUM_AVS_NODES" \
        --disk-type "pd-standard" \
        --disk-size "100" \
        --machine-type "$MACHINE_TYPE";


}

create_namespaces() {
    kubectl create namespace aerospike || true
    kubectl create namespace avs || true
}

setup_aerospike() {
    echo "Setting up namespaces..."

    kubectl create namespace aerospike || true  # Idempotent namespace creation

    echo "Deploying Aerospike Kubernetes Operator (AKO)..."

    if ! kubectl get ns olm &> /dev/null; then
        echo "Installing OLM..."
        curl -sL https://github.com/operator-framework/operator-lifecycle-manager/releases/download/v0.25.0/install.sh | bash -s v0.25.0
    else
        echo "OLM is already installed in olm namespace. Skipping installation."
    fi

    # Check if the subscription already exists
    if ! kubectl get subscription my-aerospike-kubernetes-operator --namespace operators &> /dev/null; then
        echo "Installing AKO subscription..."
        kubectl create -f https://operatorhub.io/install/aerospike-kubernetes-operator.yaml
    else
        echo "AKO subscription already exists. Skipping installation."
    fi


    echo "Waiting for AKO to be ready..."
    while true; do
        if kubectl --namespace operators get deployment/aerospike-operator-controller-manager &> /dev/null; then
            echo "AKO is ready."
            kubectl --namespace operators wait \
            --for=condition=available --timeout=180s deployment/aerospike-operator-controller-manager
            break
        else
            echo "AKO setup is still in progress..."
            sleep 10
        fi
    done

    echo "Granting permissions to the target namespace..."
    kubectl --namespace aerospike create serviceaccount aerospike-operator-controller-manager
    kubectl create clusterrolebinding aerospike-cluster \
        --clusterrole=aerospike-cluster --serviceaccount=aerospike:aerospike-operator-controller-manager

    echo "Setting secrets for Aerospike cluster..."
    kubectl --namespace aerospike create secret generic aerospike-secret --from-file="$BUILD_DIR/secrets"
    kubectl --namespace aerospike create secret generic auth-secret --from-literal=password='admin123'
    kubectl --namespace aerospike create secret generic aerospike-tls \
        --from-file="$BUILD_DIR/certs"

    echo "Adding storage class..."
    kubectl apply -f https://raw.githubusercontent.com/aerospike/aerospike-kubernetes-operator/master/config/samples/storage/gce_ssd_storage_class.yaml

    echo "Deploying Aerospike cluster..."
    kubectl apply -f $BUILD_DIR/manifests/aerospike-cr.yaml
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

# Function to optionally deploy Istio
deploy_istio() {
    echo "Deploying Istio"
    helm repo add istio https://istio-release.storage.googleapis.com/charts
    helm repo update

    helm install istio-base istio/base --namespace istio-system --set defaultRevision=default --create-namespace --wait
    helm install istiod istio/istiod --namespace istio-system --create-namespace --wait
    helm install istio-ingress istio/gateway \
     --values ./manifests/istio/istio-ingressgateway-values.yaml \
     --namespace istio-ingress \
     --create-namespace \
     --wait

    kubectl apply -f manifests/istio/gateway.yaml
    kubectl apply -f manifests/istio/avs-virtual-service.yaml
}

get_reverse_dns() {
    INGRESS_IP=$(kubectl get svc istio-ingress -n istio-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    REVERSE_DNS_AVS=$(dig +short -x $INGRESS_IP)
    echo "Reverse DNS: $REVERSE_DNS_AVS"
}

label_avs_nodes() {
  echo "Labeling AVS nodes..."

  local index_to_be_labeled=$NUM_INDEX_NODES
  local query_to_be_labeled=$NUM_QUERY_NODES
  local nodes
  nodes=$(kubectl get nodes -l cloud.google.com/gke-nodepool="$NODE_POOL_NAME_AVS" -o name)
  for node in $nodes; do
    echo "Labeling AVS node $node"
    kubectl label "$node" aerospike.io/node-pool=avs --overwrite
    if (( index_to_be_labeled > 0 )); then
      echo "Labeling AVS node $node as index-update-nodes"
      kubectl label "$node" aerospike.io/role-label=index-update-nodes --overwrite
      index_to_be_labeled="$((index_to_be_labeled - 1))"
    elif (( query_to_be_labeled > 0 )); then
      echo "Labeling AVS node $node as query"
      kubectl label "$node" aerospike.io/role-label=query-nodes --overwrite
      query_to_be_labeled="$((query_to_be_labeled - 1))"
    else
      echo "Labeling AVS node $node as default"
      kubectl label "$node" aerospike.io/role-label=default-nodes --overwrite
    fi 
  done

}

deploy_avs_helm_chart() {
  local helm_set_args=()
  local helm_repo_args=()
  local nodeport_args=()

  if [[ -n "$JFROG_USER" && -n "$JFROG_TOKEN" ]]; then
    kubectl create secret docker-registry jfrog-secret \
      --docker-server=aerospike.jfrog.io \
      --docker-username="$JFROG_USER" \
      --docker-password="$JFROG_TOKEN" \
      --docker-email="$JFROG_USER" \
      --namespace=avs\
      --dry-run=client -o yaml | kubectl apply -f -
    helm_set_args=("--set jfrog.user=$JFROG_USER" "--set jfrog.token=$JFROG_TOKEN")
    helm_repo_args=("--username $JFROG_USER" "--password $JFROG_TOKEN")
  fi

  if [[ "${SET_NODEPORT}" == 1 ]]; then
    nodeport_args=('--set-json' 'service={"enabled":true,"type":"NodePort","ports":[{"name":"svc-5000","port":5000,"targetPort":5000,"nodePort":30036}]}')
  fi
  
  helm repo add aerospike-helm "$JFROG_HELM_REPO" --force-update "${helm_repo_args[@]}"
  helm repo update

  helm install avs-app aerospike-helm/aerospike-vector-search \
    --namespace avs --version "$CHART_VERSION" \
    --set imagePullSecrets[0].name=jfrog-secret \
    --set initContainer.image.repository="$JFROG_DOCKER_REPO/avs-init-container" \
    --set initContainer.image.tag="$CHART_VERSION" \
     "${nodeport_args[@]}" \
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

    if [[ "${SET_NODEPORT}" == 0 ]]; then
      echo Your new deployment is available at $REVERSE_DNS_AVS.
    fi

    echo Check your deployment using our command line tool asvec available at https://github.com/aerospike/asvec.

    if [[ "${RUN_INSECURE}" != 1 ]]; then
        echo "connect with asvec using cert "
        cat $BUILD_DIR/certs/ca.aerospike.com.pem
        echo Use the asvec tool to change your password with 
        echo asvec -h  $REVERSE_DNS_AVS:5000  --tls-cafile path/to/tls/file  -U admin -P admin  user new-password --name admin --new-password your-new-password
    fi

    if [[ "${RUN_INSECURE}" == 1 ]] && [[ "${SET_NODEPORT}" == 1 ]]; then
      echo asvec nodes ls --seeds "$(
        kubectl get nodes \
          --selector=aerospike.io/node-pool=avs \
          --output=jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}'
      ):$(
        kubectl get svc avs-app-aerospike-vector-search \
          --namespace avs \
          --output=jsonpath='{.spec.ports[0].nodePort}'
      )"
    fi

    echo "Setup Complete!"
    
}
#This script runs in this order.
main() {
    set_env_variables
    print_env
    reset_build
    create_gke_cluster
    create_namespaces
    if [[ "${SET_NODEPORT}" == 0 ]]; then
      deploy_istio
      get_reverse_dns
    fi
    if [[ "${RUN_INSECURE}" != 1 ]]; then
        generate_certs
    fi
    setup_aerospike
    setup_avs
    label_avs_nodes
    deploy_avs_helm_chart
    setup_monitoring
    print_final_instructions
}

main