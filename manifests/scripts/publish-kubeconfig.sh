#!/bin/sh
set -eu
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
TOKEN="$(kubectl -n "${NAMESPACE}" create token breakglass-admin --duration "${TOKEN_LIFETIME}")"
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

# Resolve the bastion kubeconfig directory to absolute path if it starts with ~
case "${BASTION_KUBECONFIG_DIR}" in
  ~*)
    # Expand ~ to the actual home directory on the remote host
    BASTION_KUBECONFIG_DIR_ABS=$(ssh $SSH_OPTS "${BASTION_SSH_USER}@${BASTION_SSH_HOST}" \
        "echo ${BASTION_KUBECONFIG_DIR}")
    ;;
  *)
    BASTION_KUBECONFIG_DIR_ABS="${BASTION_KUBECONFIG_DIR}"
    ;;
esac

# Create directories on bastion and resolve the full path
ssh $SSH_OPTS "${BASTION_SSH_USER}@${BASTION_SSH_HOST}" \
    "mkdir -p ${BASTION_KUBECONFIG_DIR_ABS} ~/bin"

# Resolve the full path on the remote host
RESOLVED_KUBECONFIG_DIR=$(ssh $SSH_OPTS "${BASTION_SSH_USER}@${BASTION_SSH_HOST}" \
    "readlink -f ${BASTION_KUBECONFIG_DIR_ABS}")

echo "Resolved kubeconfig directory on bastion: ${RESOLVED_KUBECONFIG_DIR}"

# Create kubectl wrapper script with resolved path
KUBECTL_WRAPPER="${TMPDIR:-/tmp}/kubectl-${CLUSTER_NAME}"
cat > "$KUBECTL_WRAPPER" <<WRAPPER_EOF
#!/usr/bin/env bash
exec kubectl --kubeconfig="${RESOLVED_KUBECONFIG_DIR}/${CLUSTER_NAME}.yaml" "\$@"
WRAPPER_EOF

chmod +x "$KUBECTL_WRAPPER"

# Upload public kubeconfig (uses public hostname)
scp $SCP_OPTS "$KUBECONFIG_PUBLIC_TMP" "${BASTION_SSH_USER}@${BASTION_SSH_HOST}:${BASTION_KUBECONFIG_DIR_ABS}/.${CLUSTER_NAME}.yaml.tmp"

# Upload local kubeconfig (uses localhost)
scp $SCP_OPTS "$KUBECONFIG_LOCAL_TMP" "${BASTION_SSH_USER}@${BASTION_SSH_HOST}:${BASTION_KUBECONFIG_DIR_ABS}/.${CLUSTER_NAME}-local.yaml.tmp"

# Upload kubectl wrapper
scp $SCP_OPTS "$KUBECTL_WRAPPER" "${BASTION_SSH_USER}@${BASTION_SSH_HOST}:${BASTION_KUBECONFIG_DIR_ABS}/.kubectl-${CLUSTER_NAME}.tmp"

# Atomically move kubeconfigs into place
ssh $SSH_OPTS "${BASTION_SSH_USER}@${BASTION_SSH_HOST}" \
    "mv '${BASTION_KUBECONFIG_DIR_ABS}/.${CLUSTER_NAME}.yaml.tmp' '${BASTION_KUBECONFIG_DIR_ABS}/${CLUSTER_NAME}.yaml' && \
     mv '${BASTION_KUBECONFIG_DIR_ABS}/.${CLUSTER_NAME}-local.yaml.tmp' '${BASTION_KUBECONFIG_DIR_ABS}/${CLUSTER_NAME}-local.yaml' && \
     mv '${BASTION_KUBECONFIG_DIR_ABS}/.kubectl-${CLUSTER_NAME}.tmp' ~/bin/'kubectl-${CLUSTER_NAME}' && \
     chmod +x ~/bin/'kubectl-${CLUSTER_NAME}'"

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
