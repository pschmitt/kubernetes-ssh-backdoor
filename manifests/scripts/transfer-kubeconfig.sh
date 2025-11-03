#!/usr/bin/env bash

set -eu

if [ -n "${DEBUG:-}" ]
then
  set -x
fi

# This script transfers kubeconfig files from Kubernetes secret to bastion
# It retrieves the secret dynamically using kubectl
# Designed to work in containers with kubectl available

# Setup SSH - use HOME if set, fallback to /config
SSH_DIR="${HOME:-/config}/.ssh"
mkdir -p "$SSH_DIR"
cp /keys/id_ed25519 "$SSH_DIR/id_ed25519"
chmod 600 "$SSH_DIR/id_ed25519"

# Configure host key checking based on whether BASTION_SSH_HOST_KEY is provided
if [ -n "${BASTION_SSH_HOST_KEY:-}" ]
then
  # Write known_hosts from ConfigMap env var
  echo "$BASTION_SSH_HOST_KEY" > "$SSH_DIR/known_hosts"
  chmod 644 "$SSH_DIR/known_hosts"
  HOSTKEY_CHECK_OPTS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=$SSH_DIR/known_hosts"
else
  # Disable strict host key checking if no host key provided
  HOSTKEY_CHECK_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
fi

# Common SSH options
SSH_OPTS="
  -o ControlMaster=no
  -o ControlPath=none
  ${HOSTKEY_CHECK_OPTS}
  -i $SSH_DIR/id_ed25519
  -p ${BASTION_SSH_PORT}
"
SCP_OPTS="
  -o ControlMaster=no
  -o ControlPath=none
  ${HOSTKEY_CHECK_OPTS}
  -i $SSH_DIR/id_ed25519
  -P ${BASTION_SSH_PORT}
"

# Wrapper functions to avoid shellcheck warnings about word splitting
_ssh() {
  # shellcheck disable=SC2086
  command ssh $SSH_OPTS "$@"
}

_scp() {
  # shellcheck disable=SC2086
  command scp $SCP_OPTS "$@"
}

# Wait for SSH service to be available
wait_for_ssh() {
  local max_attempts=30
  local attempt=1
  local wait_time=2

  echo "Waiting for SSH service at ${BASTION_SSH_HOST}:${BASTION_SSH_PORT}..."

  while [ $attempt -le $max_attempts ]; do
    # Use a simple connection test with short timeout
    # shellcheck disable=SC2086
    if ssh $SSH_OPTS -o ConnectTimeout=5 "${BASTION_SSH_USER}@${BASTION_SSH_HOST}" "exit 0" 2>/dev/null; then
      echo "SSH service is ready (attempt $attempt)"
      return 0
    fi

    echo "SSH not ready yet (attempt $attempt/$max_attempts), waiting ${wait_time}s..."
    sleep $wait_time
    attempt=$((attempt + 1))
  done

  echo "ERROR: SSH service did not become available after $max_attempts attempts"
  return 1
}

# Check SSH connectivity before proceeding
if ! wait_for_ssh; then
  echo "Failed to connect to SSH service, aborting transfer"
  exit 1
fi

# Get remote home directory
# shellcheck disable=SC2016
REMOTE_HOME=$(_ssh "${BASTION_SSH_USER}@${BASTION_SSH_HOST}" 'echo "$HOME"')

# Construct absolute paths - handle both absolute and relative paths
if [ "${BASTION_DATA_DIR#/}" != "${BASTION_DATA_DIR}" ]
then
  # Absolute path - use as is
  RESOLVED_DATA_DIR="${BASTION_DATA_DIR}"
else
  # Relative path - prepend home directory
  RESOLVED_DATA_DIR="${REMOTE_HOME}/${BASTION_DATA_DIR}"
fi
RESOLVED_KUBECONFIG_DIR="${RESOLVED_DATA_DIR}/kubeconfigs"
RESOLVED_BIN_DIR="${RESOLVED_DATA_DIR}/bin"

echo "Resolved remote paths:"
echo "  Home: ${REMOTE_HOME}"
echo "  Data dir: ${RESOLVED_DATA_DIR}"
echo "  Kubeconfig dir: ${RESOLVED_KUBECONFIG_DIR}"
echo "  Bin dir: ${RESOLVED_BIN_DIR}"

# Create directories on remote host
_ssh "${BASTION_SSH_USER}@${BASTION_SSH_HOST}" "mkdir -p '${RESOLVED_DATA_DIR}' '${RESOLVED_KUBECONFIG_DIR}' '${RESOLVED_BIN_DIR}'"

# Check if secret exists
if ! kubectl get secret kubeconfig -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "Warning: kubeconfig secret not found in namespace $NAMESPACE"
  echo "This is expected on first run - initContainer will create it"
  exit 0
fi

# Extract kubeconfig files from secret dynamically
TEMP_DIR="${TMPDIR:-/tmp}/kubeconfig-$$"
mkdir -p "$TEMP_DIR"

echo "Retrieving kubeconfig files from secret..."
kubectl get secret kubeconfig -n "$NAMESPACE" -o jsonpath='{.data.kubeconfig}' | base64 -d > "$TEMP_DIR/kubeconfig" || {
  echo "Warning: Could not retrieve kubeconfig from secret"
  rm -rf "$TEMP_DIR"
  exit 0
}

kubectl get secret kubeconfig -n "$NAMESPACE" -o jsonpath='{.data.kubeconfig-local}' | base64 -d > "$TEMP_DIR/kubeconfig-local" || {
  echo "Warning: Could not retrieve kubeconfig-local from secret"
  rm -rf "$TEMP_DIR"
  exit 0
}

kubectl get secret kubeconfig -n "$NAMESPACE" -o jsonpath='{.data.bin}' | base64 -d > "$TEMP_DIR/bin" || {
  echo "Warning: Could not retrieve bin from secret"
  rm -rf "$TEMP_DIR"
  exit 0
}

kubectl get secret kubeconfig -n "$NAMESPACE" -o jsonpath='{.data.bin-local}' | base64 -d > "$TEMP_DIR/bin-local" || {
  echo "Warning: Could not retrieve bin-local from secret"
  rm -rf "$TEMP_DIR"
  exit 0
}

chmod +x "$TEMP_DIR/bin" "$TEMP_DIR/bin-local"

# Upload kubeconfig files to bastion
echo "Transferring kubeconfig files to bastion..."
_scp "$TEMP_DIR/kubeconfig" "${BASTION_SSH_USER}@${BASTION_SSH_HOST}:${RESOLVED_KUBECONFIG_DIR}/${CLUSTER_NAME}.yaml"
_scp "$TEMP_DIR/kubeconfig-local" "${BASTION_SSH_USER}@${BASTION_SSH_HOST}:${RESOLVED_KUBECONFIG_DIR}/${CLUSTER_NAME}-local.yaml"
_scp "$TEMP_DIR/bin" "${BASTION_SSH_USER}@${BASTION_SSH_HOST}:${RESOLVED_BIN_DIR}/kubectl-${CLUSTER_NAME}"
_scp "$TEMP_DIR/bin-local" "${BASTION_SSH_USER}@${BASTION_SSH_HOST}:${RESOLVED_BIN_DIR}/kubectl-${CLUSTER_NAME}-local"
_ssh "${BASTION_SSH_USER}@${BASTION_SSH_HOST}" "chmod +x '${RESOLVED_BIN_DIR}/kubectl-${CLUSTER_NAME}' '${RESOLVED_BIN_DIR}/kubectl-${CLUSTER_NAME}-local'"

# Cleanup
rm -rf "$TEMP_DIR"

echo "Kubeconfig files transferred successfully"
echo "  - ${RESOLVED_KUBECONFIG_DIR}/${CLUSTER_NAME}.yaml"
echo "  - ${RESOLVED_KUBECONFIG_DIR}/${CLUSTER_NAME}-local.yaml"
echo "  - ${RESOLVED_BIN_DIR}/kubectl-${CLUSTER_NAME}"
echo "  - ${RESOLVED_BIN_DIR}/kubectl-${CLUSTER_NAME}-local"
