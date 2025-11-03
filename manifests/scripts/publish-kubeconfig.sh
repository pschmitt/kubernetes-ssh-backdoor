#!/usr/bin/env bash

set -euo pipefail

if [ -n "${DEBUG:-}" ]
then
  set -x
fi

# Setup SSH
mkdir -p /root/.ssh
cp /keys/id_ed25519 /root/.ssh/id_ed25519
chmod 600 /root/.ssh/id_ed25519

# Configure host key checking based on whether BASTION_SSH_HOST_KEY is provided
if [ -n "${BASTION_SSH_HOST_KEY:-}" ]
then
  # Write known_hosts from ConfigMap env var
  echo "$BASTION_SSH_HOST_KEY" > /root/.ssh/known_hosts
  chmod 644 /root/.ssh/known_hosts
  HOSTKEY_CHECK_OPTS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/.ssh/known_hosts"
else
  # Disable strict host key checking if no host key provided
  HOSTKEY_CHECK_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
fi

# Common SSH options
SSH_OPTS="
  -o ControlMaster=no
  -o ControlPath=none
  ${HOSTKEY_CHECK_OPTS}
  -i /root/.ssh/id_ed25519
  -p ${BASTION_SSH_PORT}
"
SCP_OPTS="
  -o ControlMaster=no
  -o ControlPath=none
  ${HOSTKEY_CHECK_OPTS}
  -i /root/.ssh/id_ed25519
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

# Auto-detect cluster name if not provided
if [ -z "${CLUSTER_NAME}" ] || [ "${CLUSTER_NAME}" = "" ]
then
  # Try cluster-info ConfigMap first
  CLUSTER_NAME=$(kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.name}' 2>/dev/null || true)

  if [ -z "${CLUSTER_NAME}" ]
  then
    # Fallback to generating from namespace and timestamp
    CLUSTER_NAME="${NAMESPACE}-$(date +%s)"
    echo "Generated cluster name: ${CLUSTER_NAME}"
  else
    echo "Detected cluster name: ${CLUSTER_NAME}"
  fi
fi

# Create service account token with configurable duration
TOKEN="$(kubectl -n "$NAMESPACE" create token breakglass-admin --duration "$TOKEN_LIFETIME")"
CA_B64="$(base64 -w0 /var/run/secrets/kubernetes.io/serviceaccount/ca.crt)"

# Determine the public host for the kubeconfig
KUBECONFIG_SERVER_HOST="${BASTION_SSH_PUBLIC_HOST:-${BASTION_SSH_HOST}}"

# Create kubeconfig with public host (uses bastion's hostname)
KUBECONFIG_PUBLIC_TMP=${TMPDIR:-/tmp}/kubeconfig-public.yaml
cat > "$KUBECONFIG_PUBLIC_TMP" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: ${CLUSTER_NAME}-backdoor
  cluster:
    certificate-authority-data: ${CA_B64}
    server: https://${KUBECONFIG_SERVER_HOST}:${REMOTE_PORT}
    tls-server-name: kubernetes.default.svc
users:
- name: breakglass-admin-${CLUSTER_NAME}
  user:
    token: ${TOKEN}
contexts:
- name: ${CLUSTER_NAME}-backdoor
  context:
    cluster: ${CLUSTER_NAME}-backdoor
    user: breakglass-admin-${CLUSTER_NAME}
current-context: ${CLUSTER_NAME}-backdoor
EOF

# Create kubeconfig with localhost (uses 127.0.0.1)
KUBECONFIG_LOCAL_TMP=${TMPDIR:-/tmp}/kubeconfig-local.yaml
cat > "$KUBECONFIG_LOCAL_TMP" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: ${CLUSTER_NAME}-backdoor
  cluster:
    certificate-authority-data: ${CA_B64}
    server: https://127.0.0.1:${REMOTE_PORT}
    tls-server-name: kubernetes.default.svc
users:
- name: breakglass-admin-${CLUSTER_NAME}
  user:
    token: ${TOKEN}
contexts:
- name: ${CLUSTER_NAME}-backdoor
  context:
    cluster: ${CLUSTER_NAME}-backdoor
    user: breakglass-admin-${CLUSTER_NAME}
current-context: ${CLUSTER_NAME}-backdoor
EOF

# Resolve remote paths to absolute paths in a single SSH call
# SC2016: The mix of single/double quotes is intentional - $HOME expands remotely, ${BASTION_KUBECONFIG_DIR} locally
# shellcheck disable=SC2016
IFS=' ' read -r REMOTE_HOME RESOLVED_KUBECONFIG_DIR < <(_ssh "${BASTION_SSH_USER}@${BASTION_SSH_HOST}" \
    'echo "$HOME" && mkdir -p '"'${BASTION_KUBECONFIG_DIR}'"' "$HOME/bin" && readlink -f '"'${BASTION_KUBECONFIG_DIR}'")

RESOLVED_BIN_DIR="${REMOTE_HOME}/bin"

echo "Resolved remote paths:"
echo "  Home: ${REMOTE_HOME}"
echo "  Kubeconfig dir: ${RESOLVED_KUBECONFIG_DIR}"
echo "  Bin dir: ${RESOLVED_BIN_DIR}"

# Create kubectl wrapper script with resolved path
KUBECTL_WRAPPER="${TMPDIR:-/tmp}/kubectl-${CLUSTER_NAME}"
cat > "$KUBECTL_WRAPPER" <<WRAPPER_EOF
#!/usr/bin/env bash
exec kubectl --kubeconfig="${RESOLVED_KUBECONFIG_DIR}/${CLUSTER_NAME}.yaml" "\$@"
WRAPPER_EOF

chmod +x "$KUBECTL_WRAPPER"

# Upload public kubeconfig (uses public hostname)
_scp "$KUBECONFIG_PUBLIC_TMP" "${BASTION_SSH_USER}@${BASTION_SSH_HOST}:${RESOLVED_KUBECONFIG_DIR}/${CLUSTER_NAME}.yaml"

# Upload local kubeconfig (uses localhost)
_scp "$KUBECONFIG_LOCAL_TMP" "${BASTION_SSH_USER}@${BASTION_SSH_HOST}:${RESOLVED_KUBECONFIG_DIR}/${CLUSTER_NAME}-local.yaml"

# Upload kubectl wrapper and make it executable
_scp "$KUBECTL_WRAPPER" "${BASTION_SSH_USER}@${BASTION_SSH_HOST}:${RESOLVED_BIN_DIR}/kubectl-${CLUSTER_NAME}"
_ssh "${BASTION_SSH_USER}@${BASTION_SSH_HOST}" 'chmod +x '"'${RESOLVED_BIN_DIR}/kubectl-${CLUSTER_NAME}'"

echo "Kubeconfigs and kubectl wrapper published successfully"
echo "  - ${RESOLVED_KUBECONFIG_DIR}/${CLUSTER_NAME}.yaml (uses ${KUBECONFIG_SERVER_HOST}:${REMOTE_PORT})"
echo "  - ${RESOLVED_KUBECONFIG_DIR}/${CLUSTER_NAME}-local.yaml (uses 127.0.0.1:${REMOTE_PORT})"
echo "Use: kubectl-${CLUSTER_NAME} get nodes"

# Update kubeconfig secret with both versions
echo "Updating kubeconfig secret..."

kubectl create secret generic kubeconfig \
  -n "$NAMESPACE" \
  --type=Opaque \
  --from-file=kubeconfig="$KUBECONFIG_PUBLIC_TMP" \
  --from-file=kubeconfig-local="$KUBECONFIG_LOCAL_TMP" \
  --from-file=bin="$KUBECTL_WRAPPER" \
  --dry-run=client -o yaml | \
  kubectl apply -f -

echo "Secret updated successfully"
