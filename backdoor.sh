#!/usr/bin/env bash

set -euo pipefail

# Color codes
BOLD_YELLOW='\033[1;33m'
BOLD_GREEN='\033[1;32m'
BOLD_BLUE='\033[1;34m'
RESET='\033[0m'

# Helper functions
echo_info() {
  echo -e "${BOLD_BLUE}INF${RESET} $1" >&2
}

echo_success() {
  echo -e "${BOLD_GREEN}OK${RESET} $1" >&2
}

# Default values
NAMESPACE="backdoor"
BASTION_SSH_HOST=""
BASTION_SSH_PUBLIC_HOST=""
BASTION_SSH_PORT="22"
BASTION_SSH_USER="k8s-backdoor"
BASTION_KUBECONFIG_DIR="kubeconfigs"
BASTION_KUBECONFIG_NAME=""
CLUSTER_NAME=""
REMOTE_PORT="16443"
REMOTE_LISTEN_ADDR="127.0.0.1"
SSH_KEY_PATH=""
BASTION_SSH_HOST_KEY=""
OUTPUT_FILE=""
APPLY=""
DELETE=""
RESTART=""
DEBUG=""
KUBE_CONTEXT=""

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Build Kubernetes manifests for SSH tunnel using Kustomize.

OPTIONS:
  -h, --host BASTION_SSH_HOST          Destination bastion host (required)
  -H, --public-host PUBLIC_HOST        Public hostname for kubeconfig (default: same as --host)
  -P, --port BASTION_SSH_PORT          SSH port on bastion host (default: 22)
  -i, --identity SSH_KEY_PATH          Path to SSH private key (required)
  -k, --host-key BASTION_SSH_HOST_KEY  SSH host public key (default: auto-fetch with ssh-keyscan)
  -n, --namespace NAMESPACE            Kubernetes namespace (default: backdoor)
  -u, --user BASTION_SSH_USER          SSH user on bastion (default: k8s-backdoor)
  -d, --kubeconfig-dir DIR             Kubeconfig directory on bastion (default: .kube/config.d)
  -f, --kubeconfig-name NAME           Kubeconfig filename on bastion (default: config-<cluster-name>)
  -c, --cluster-name NAME              Cluster name in kubeconfig (default: auto-detect from cluster-info)
  -p, --remote-port PORT               Remote port for tunnel (default: computed from cluster name via T9)
  -a, --addr ADDR                      Remote listen address on bastion (default: 127.0.0.1)
  -o, --output FILE                    Output file for manifests (default: stdout)
  --apply                              Apply manifests directly with kubectl
  --context CONTEXT                    Kubernetes context to use (default: current-context)
  --delete                             Delete manifests from the current cluster with kubectl
  --debug                              Enable debug mode (sets -x in container scripts)
  --help                               Show this help message

EXAMPLES:
  # Generate manifests to stdout (host key auto-fetched)
  $0 --host bastion.example.com -i ~/.ssh/id_ed25519

  # Generate manifests to directory
  $0 --host bastion.example.com -i ~/.ssh/id_ed25519 -o ./output

  # Apply directly
  $0 --host bastion.example.com -i ~/.ssh/id_ed25519 --apply

  # Delete from cluster
  $0 --host bastion.example.com -i ~/.ssh/id_ed25519 --delete

  # Provide host key manually for security
  $0 --host bastion.example.com -i ~/.ssh/id_ed25519 -k "\$(ssh-keyscan bastion.example.com 2>/dev/null | grep ed25519)" --apply

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]
do
  case $1 in
    -h|--host)
      BASTION_SSH_HOST="$2"
      shift 2
      ;;
    -H|--public-host)
      BASTION_SSH_PUBLIC_HOST="$2"
      shift 2
      ;;
    -P|--port)
      BASTION_SSH_PORT="$2"
      shift 2
      ;;
    -i|--identity)
      SSH_KEY_PATH="$2"
      shift 2
      ;;
    -k|--host-key)
      BASTION_SSH_HOST_KEY="$2"
      shift 2
      ;;
    -n|--namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    -u|--user)
      BASTION_SSH_USER="$2"
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
    -a|--addr)
      REMOTE_LISTEN_ADDR="$2"
      shift 2
      ;;
    -o|--output)
      if [[ $2 != "-" ]]
      then
        OUTPUT_FILE="$2"
      fi
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    --context)
      KUBE_CONTEXT="$2"
      shift 2
      ;;
    --delete)
      DELETE=1
      shift
      ;;
    --restart)
      RESTART=1
      shift
      ;;
    --debug)
      DEBUG=1
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Use --help for usage information" >&2
      exit 1
      ;;
  esac
done

# Validate required parameters
if [[ -z "$BASTION_SSH_HOST" ]]
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
if [[ -z "$BASTION_SSH_HOST_KEY" ]]
then
  echo_info "Fetching SSH host key for ${BOLD_YELLOW}${BASTION_SSH_HOST}:${BASTION_SSH_PORT}${RESET}..."
  BASTION_SSH_HOST_KEY=$(ssh-keyscan -p "$BASTION_SSH_PORT" -t ed25519 "$BASTION_SSH_HOST" 2>/dev/null | grep -v "^#")

  if [[ -z "$BASTION_SSH_HOST_KEY" ]]
  then
    echo "Error: Failed to fetch host key from $BASTION_SSH_HOST:$BASTION_SSH_PORT" >&2
    echo "You can manually provide it with: --host-key 'HOSTNAME ssh-ed25519 AAAA...'" >&2
    exit 1
  fi

  echo_success "Successfully fetched host key"
fi

# Build kubectl command with optional context
KUBECTL_CMD="kubectl"
if [[ -n "$KUBE_CONTEXT" ]]
then
  KUBECTL_CMD="kubectl --context=$KUBE_CONTEXT"
fi

# Get current context for logging
CURRENT_CONTEXT=$($KUBECTL_CMD config current-context 2>/dev/null || echo "unknown")

# Auto-detect cluster name if not provided
if [[ -z "$CLUSTER_NAME" ]]
then
  echo_info "Auto-detecting cluster name..."

  # Try to get cluster name from cluster-info ConfigMap
  CLUSTER_NAME=$($KUBECTL_CMD get configmap -n kube-system cluster-info -o jsonpath='{.data.name}' 2>/dev/null || true)

  if [[ -z "$CLUSTER_NAME" ]]
  then
    # Fallback to context name
    CLUSTER_NAME=${KUBE_CONTEXT:-$($KUBECTL_CMD config current-context 2>/dev/null || echo "kubernetes")}
    echo_info "Using current context as cluster name: ${BOLD_YELLOW}${CLUSTER_NAME}${RESET}"
  else
    echo_info "Detected cluster name from cluster-info: ${BOLD_YELLOW}${CLUSTER_NAME}${RESET}"
  fi
fi

# Compute remote port from cluster name if not explicitly provided
if [[ "$REMOTE_PORT" == "16443" ]] && [[ -n "$CLUSTER_NAME" ]]
then
  # T9 conversion function (like old phone keypads)
  t9_convert() {
    local input="${1,,}"  # Convert to lowercase
    local output=""
    local char

    for ((i=0; i<${#input}; i++))
    do
      char="${input:$i:1}"
      case "$char" in
        [abc]) output+="2" ;;
        [def]) output+="3" ;;
        [ghi]) output+="4" ;;
        [jkl]) output+="5" ;;
        [mno]) output+="6" ;;
        [pqrs]) output+="7" ;;
        [tuv]) output+="8" ;;
        [wxyz]) output+="9" ;;
        *) ;; # Ignore non-alphabetic characters
      esac
    done

    echo "$output"
  }

  # Convert cluster name to T9 number
  t9_val=$(t9_convert "$CLUSTER_NAME")

  # Ensure it's within valid port range (1024-65535)
  while [[ ${#t9_val} -gt 5 ]] || [[ $t9_val -gt 65535 ]]
  do
    # Remove last digit if too large
    t9_val="${t9_val%?}"
  done

  # Ensure it's at least 1024
  if [[ $t9_val -lt 1024 ]]
  then
    # Prepend "1" to make it >= 1024
    t9_val="1${t9_val}"
  fi

  # Final check
  if [[ $t9_val -ge 1024 ]] && [[ $t9_val -le 65535 ]]
  then
    REMOTE_PORT="$t9_val"
    echo_info "Computed remote port from cluster name: ${BOLD_YELLOW}${REMOTE_PORT}${RESET}"
  else
    echo_info "Could not compute valid port from cluster name, using default: ${BOLD_YELLOW}${REMOTE_PORT}${RESET}"
  fi
fi

# Log configuration summary
echo_info "Kubernetes Context     ${BOLD_YELLOW}${CURRENT_CONTEXT}${RESET}"
echo_info "Cluster Name           ${BOLD_YELLOW}${CLUSTER_NAME}${RESET}"
echo_info "Namespace              ${BOLD_YELLOW}${NAMESPACE}${RESET}"
echo_info "Bastion Host           ${BOLD_YELLOW}${BASTION_SSH_HOST}:${BASTION_SSH_PORT}${RESET}"
echo_info "Bastion User           ${BOLD_YELLOW}${BASTION_SSH_USER}${RESET}"
echo_info "Remote Port            ${BOLD_YELLOW}${REMOTE_PORT}${RESET}"
echo_info "Remote Listen Addr     ${BOLD_YELLOW}${REMOTE_LISTEN_ADDR}${RESET}"
echo_info "Kubeconfig Directory   ${BOLD_YELLOW}${BASTION_KUBECONFIG_DIR}${RESET}"
if [[ -n "$BASTION_KUBECONFIG_NAME" ]]
then
  echo_info "Kubeconfig Name        ${BOLD_YELLOW}${BASTION_KUBECONFIG_NAME}${RESET}"
else
  echo_info "Kubeconfig Name        ${BOLD_YELLOW}config-${CLUSTER_NAME}${RESET} (auto-generated)"
fi
echo_info "SSH Host Key           ${BOLD_YELLOW}${BASTION_SSH_HOST_KEY}${RESET}"


# Create temporary kustomization
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Copy manifests to temp directory
cp -r "$SCRIPT_DIR/manifests" "$TEMP_DIR/"

# Copy SSH key to temp location
cp "$SSH_KEY_PATH" "$TEMP_DIR/id_ed25519"
chmod 600 "$TEMP_DIR/id_ed25519"

# Export variables for envsubst
export BASTION_KUBECONFIG_DIR
export BASTION_KUBECONFIG_NAME
export BASTION_SSH_HOST
export BASTION_SSH_HOST_KEY
export BASTION_SSH_PORT
export BASTION_SSH_PUBLIC_HOST
export BASTION_SSH_USER
export CLUSTER_NAME
export DEBUG
export NAMESPACE
export REMOTE_PORT
export REMOTE_LISTEN_ADDR

# Template kustomization.yaml with envsubst
envsubst < "$SCRIPT_DIR/kustomization.yaml" > "$TEMP_DIR/kustomization.yaml"

# Build with kustomize
if [[ -n "$APPLY" ]]
then
  echo_info "Applying manifests to cluster..."
  $KUBECTL_CMD apply -k "$TEMP_DIR"
  echo_success "Manifests applied successfully"
  if [[ -n "$RESTART" ]]
  then
    echo_info "Restarting backdoor pods in namespace ${BOLD_YELLOW}${NAMESPACE}${RESET}..."
    $KUBECTL_CMD -n "$NAMESPACE" rollout restart deployment
  fi
elif [[ -n "$DELETE" ]]
then
  echo "Deleting manifests from cluster..." >&2
  $KUBECTL_CMD delete -k "$TEMP_DIR"
  echo_success "Manifests deleted successfully"
elif [[ -n "$OUTPUT_FILE" ]]
then
  mkdir -p "$(dirname "$OUTPUT_FILE")"
  kubectl kustomize "$TEMP_DIR" > "$OUTPUT_FILE"
  echo_success "Manifests written to ${BOLD_YELLOW}${OUTPUT_FILE}${RESET}"
else
  kubectl kustomize "$TEMP_DIR"
fi
