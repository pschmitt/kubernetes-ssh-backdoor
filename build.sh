#!/usr/bin/env bash

set -euo pipefail

# Default values
NAMESPACE="ssh-tunnel"
BASTION_HOST=""
BASTION_PORT="22"
BASTION_USER="tunnel"
BASTION_KUBECONFIG_DIR="kubeconfigs"
BASTION_KUBECONFIG_NAME=""
CLUSTER_NAME=""
REMOTE_PORT="6443"
SSH_KEY_PATH=""
HOST_PUBLIC_KEY=""
OUTPUT_DIR=""
APPLY=false
DEBUG=false

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Build Kubernetes manifests for SSH tunnel using Kustomize.

OPTIONS:
  -h, --host BASTION_HOST          Destination bastion host (required)
  -P, --port BASTION_PORT          SSH port on bastion host (default: 22)
  -i, --identity SSH_KEY_PATH      Path to SSH private key (required)
  -k, --host-key HOST_PUBLIC_KEY   SSH host public key (default: auto-fetch with ssh-keyscan)
  -n, --namespace NAMESPACE        Kubernetes namespace (default: ssh-tunnel)
  -u, --user BASTION_USER          SSH user on bastion (default: tunnel)
  -d, --kubeconfig-dir DIR         Kubeconfig directory on bastion (default: .kube/config.d)
  -f, --kubeconfig-name NAME       Kubeconfig filename on bastion (default: config-<cluster-name>)
  -c, --cluster-name NAME          Cluster name in kubeconfig (default: auto-detect from cluster-info)
  -p, --remote-port PORT           Remote port for tunnel (default: 6443)
  -o, --output DIR                 Output directory for manifests (default: stdout)
  -a, --apply                      Apply manifests directly with kubectl
  --debug                          Enable debug mode (sets -x in container scripts)
  --help                           Show this help message

EXAMPLES:
  # Generate manifests to stdout (host key auto-fetched)
  $0 --host bastion.example.com -i ~/.ssh/id_ed25519

  # Generate manifests to directory
  $0 --host bastion.example.com -i ~/.ssh/id_ed25519 -o ./output

  # Apply directly
  $0 --host bastion.example.com -i ~/.ssh/id_ed25519 --apply

  # Provide host key manually for security
  $0 --host bastion.example.com -i ~/.ssh/id_ed25519 -k "\$(ssh-keyscan bastion.example.com 2>/dev/null | grep ed25519)" --apply

EOF
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]
do
  case $1 in
    -h|--host)
      BASTION_HOST="$2"
      shift 2
      ;;
    -P|--port)
      BASTION_PORT="$2"
      shift 2
      ;;
    -i|--identity)
      SSH_KEY_PATH="$2"
      shift 2
      ;;
    -k|--host-key)
      HOST_PUBLIC_KEY="$2"
      shift 2
      ;;
    -n|--namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    -u|--user)
      BASTION_USER="$2"
      shift 2
      ;;
    -d|--kubeconfig-dir)
      BASTION_KUBECONFIG_DIR="$2"
      shift 2
      ;;
    -f|--kubeconfig-name)
      BASTION_KUBECONFIG_NAME="$2"
      shift 2
      ;;
    -c|--cluster-name)
      CLUSTER_NAME="$2"
      shift 2
      ;;
    -p|--remote-port)
      REMOTE_PORT="$2"
      shift 2
      ;;
    -o|--output)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -a|--apply)
      APPLY=true
      shift
      ;;
    --debug)
      DEBUG=true
      shift
      ;;
    --help)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Use --help for usage information" >&2
      exit 1
      ;;
  esac
done

# Validate required parameters
if [[ -z "$BASTION_HOST" ]]
then
  echo "Error: --host is required" >&2
  exit 1
fi

if [[ -z "$SSH_KEY_PATH" ]]
then
  echo "Error: --identity is required" >&2
  exit 1
fi

if [[ ! -f "$SSH_KEY_PATH" ]]
then
  echo "Error: SSH key file not found: $SSH_KEY_PATH" >&2
  exit 1
fi

# Auto-fetch host key if not provided
if [[ -z "$HOST_PUBLIC_KEY" ]]
then
  echo "Fetching SSH host key for $BASTION_HOST:$BASTION_PORT..." >&2
  HOST_PUBLIC_KEY=$(ssh-keyscan -p "$BASTION_PORT" -t ed25519 "$BASTION_HOST" 2>/dev/null | grep -v "^#")

  if [[ -z "$HOST_PUBLIC_KEY" ]]
  then
    echo "Error: Failed to fetch host key from $BASTION_HOST:$BASTION_PORT" >&2
    echo "You can manually provide it with: --host-key 'HOSTNAME ssh-ed25519 AAAA...'" >&2
    exit 1
  fi

  echo "Successfully fetched host key" >&2
fi

# Auto-detect cluster name if not provided
if [[ -z "$CLUSTER_NAME" ]]
then
  echo "Auto-detecting cluster name..." >&2
  
  # Try to get cluster name from cluster-info ConfigMap
  CLUSTER_NAME=$(kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.name}' 2>/dev/null || true)
  
  if [[ -z "$CLUSTER_NAME" ]]
  then
    # Fallback to context name
    CLUSTER_NAME=$(kubectl config current-context 2>/dev/null || echo "kubernetes")
    echo "Using current context as cluster name: $CLUSTER_NAME" >&2
  else
    echo "Detected cluster name from cluster-info: $CLUSTER_NAME" >&2
  fi
fi

# Create temporary kustomization
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Copy manifests to temp directory
cp -r "$SCRIPT_DIR/manifests" "$TEMP_DIR/"

# Copy SSH key to temp location
cp "$SSH_KEY_PATH" "$TEMP_DIR/id_ed25519"
chmod 600 "$TEMP_DIR/id_ed25519"

# Create kustomization.yaml with values
cat > "$TEMP_DIR/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: $NAMESPACE

resources:
  - manifests/namespace-ssh-tunnel.yaml
  - manifests/serviceaccount-breakglass-admin.yaml
  - manifests/clusterrolebinding-breakglass-admin.yaml
  - manifests/deployment-tunnel.yaml

configMapGenerator:
  - name: tunnel-config
    literals:
      - BASTION_HOST=$BASTION_HOST
      - BASTION_PORT=$BASTION_PORT
      - BASTION_USER=$BASTION_USER
      - BASTION_KUBECONFIG_DIR=$BASTION_KUBECONFIG_DIR
      - BASTION_KUBECONFIG_NAME=$BASTION_KUBECONFIG_NAME
      - CLUSTER_NAME=$CLUSTER_NAME
      - REMOTE_PORT=$REMOTE_PORT
      - known_hosts=$HOST_PUBLIC_KEY
      - DEBUG=$DEBUG

secretGenerator:
  - name: ssh-key
    files:
      - id_ed25519=id_ed25519

generatorOptions:
  disableNameSuffixHash: true

patches:
  - target:
      kind: Namespace
      name: ssh-tunnel
    patch: |-
      - op: replace
        path: /metadata/name
        value: $NAMESPACE
EOF

# Build with kustomize
if [[ "$APPLY" == "true" ]]
then
  kubectl apply -k "$TEMP_DIR"
elif [[ -n "$OUTPUT_DIR" ]]
then
  mkdir -p "$OUTPUT_DIR"
  kubectl kustomize "$TEMP_DIR" > "$OUTPUT_DIR/manifest.yaml"
  echo "Manifests written to $OUTPUT_DIR/manifest.yaml" >&2
else
  kubectl kustomize "$TEMP_DIR"
fi
