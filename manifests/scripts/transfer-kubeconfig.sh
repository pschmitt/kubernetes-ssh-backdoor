#!/usr/bin/env sh

set -eu

if [ -n "${DEBUG:-}" ]
then
  set -x
fi

# This script only transfers kubeconfig files from /kubeconfig volume to bastion
# It does NOT create new tokens or interact with Kubernetes
# Designed to work in the ssh container which doesn't have kubectl

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

# Check if kubeconfig files exist in the mounted volume
if [ ! -f /kubeconfig/kubeconfig ] || [ ! -f /kubeconfig/kubeconfig-local ] || [ ! -f /kubeconfig/bin ]; then
  echo "Warning: Kubeconfig files not found in /kubeconfig volume"
  echo "This is expected on first run - initContainer will create them"
  exit 0
fi

# Upload kubeconfig files from the mounted secret volume
echo "Transferring kubeconfig files to bastion..."
_scp /kubeconfig/kubeconfig "${BASTION_SSH_USER}@${BASTION_SSH_HOST}:${RESOLVED_KUBECONFIG_DIR}/${CLUSTER_NAME}.yaml"
_scp /kubeconfig/kubeconfig-local "${BASTION_SSH_USER}@${BASTION_SSH_HOST}:${RESOLVED_KUBECONFIG_DIR}/${CLUSTER_NAME}-local.yaml"
_scp /kubeconfig/bin "${BASTION_SSH_USER}@${BASTION_SSH_HOST}:${RESOLVED_BIN_DIR}/kubectl-${CLUSTER_NAME}"
_ssh "${BASTION_SSH_USER}@${BASTION_SSH_HOST}" "chmod +x '${RESOLVED_BIN_DIR}/kubectl-${CLUSTER_NAME}'"

echo "Kubeconfig files transferred successfully"
echo "  - ${RESOLVED_KUBECONFIG_DIR}/${CLUSTER_NAME}.yaml"
echo "  - ${RESOLVED_KUBECONFIG_DIR}/${CLUSTER_NAME}-local.yaml"
echo "  - ${RESOLVED_BIN_DIR}/kubectl-${CLUSTER_NAME}"
