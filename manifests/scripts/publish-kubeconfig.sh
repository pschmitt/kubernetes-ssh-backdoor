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

# Write known_hosts from ConfigMap env var
echo "$BASTION_SSH_HOST_KEY" > /root/.ssh/known_hosts
chmod 644 /root/.ssh/known_hosts

# Common SSH options
SSH_OPTS="
  -o ControlMaster=no
  -o ControlPath=none
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile=/root/.ssh/known_hosts
  -i /root/.ssh/id_ed25519
  -p ${BASTION_SSH_PORT}
"
SCP_OPTS="
  -o ControlMaster=no
  -o ControlPath=none
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile=/root/.ssh/known_hosts
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
TOKEN="$(kubectl -n "${NAMESPACE}" create token breakglass-admin --duration ${TOKEN_LIFETIME})"
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

# Create directories on bastion and resolve the full path
ssh $SSH_OPTS "${BASTION_SSH_USER}@${BASTION_SSH_HOST}" \
    "mkdir -p ${BASTION_KUBECONFIG_DIR} ~/bin"

# Resolve the full path on the remote host
RESOLVED_KUBECONFIG_DIR=$(ssh $SSH_OPTS "${BASTION_SSH_USER}@${BASTION_SSH_HOST}" \
    "readlink -f ${BASTION_KUBECONFIG_DIR}")

echo "Resolved kubeconfig directory on bastion: ${RESOLVED_KUBECONFIG_DIR}"

# Create kubectl wrapper script with resolved path
KUBECTL_WRAPPER="${TMPDIR:-/tmp}/kubectl-${CLUSTER_NAME}"
cat > "$KUBECTL_WRAPPER" <<WRAPPER_EOF
#!/usr/bin/env bash
exec kubectl --kubeconfig="${RESOLVED_KUBECONFIG_DIR}/${CLUSTER_NAME}.yaml" "\$@"
WRAPPER_EOF

chmod +x "$KUBECTL_WRAPPER"

# Upload public kubeconfig (uses public hostname)
scp $SCP_OPTS "$KUBECONFIG_PUBLIC_TMP" "${BASTION_SSH_USER}@${BASTION_SSH_HOST}:${BASTION_KUBECONFIG_DIR}/.${CLUSTER_NAME}.yaml.tmp"

# Upload local kubeconfig (uses localhost)
scp $SCP_OPTS "$KUBECONFIG_LOCAL_TMP" "${BASTION_SSH_USER}@${BASTION_SSH_HOST}:${BASTION_KUBECONFIG_DIR}/.${CLUSTER_NAME}-local.yaml.tmp"

# Upload kubectl wrapper
scp $SCP_OPTS "$KUBECTL_WRAPPER" "${BASTION_SSH_USER}@${BASTION_SSH_HOST}:~/bin/kubectl-${CLUSTER_NAME}"

# Atomically move kubeconfigs into place
ssh $SSH_OPTS "${BASTION_SSH_USER}@${BASTION_SSH_HOST}" \
    "mv '${BASTION_KUBECONFIG_DIR}/.${CLUSTER_NAME}.yaml.tmp' '${BASTION_KUBECONFIG_DIR}/${CLUSTER_NAME}.yaml' && \
     mv '${BASTION_KUBECONFIG_DIR}/.${CLUSTER_NAME}-local.yaml.tmp' '${BASTION_KUBECONFIG_DIR}/${CLUSTER_NAME}-local.yaml' && \
     chmod +x ~/bin/'kubectl-${CLUSTER_NAME}'"

echo "Kubeconfigs and kubectl wrapper published successfully"
echo "  - ${BASTION_KUBECONFIG_DIR}/${CLUSTER_NAME}.yaml (uses ${KUBECONFIG_SERVER_HOST}:${REMOTE_PORT})"
echo "  - ${BASTION_KUBECONFIG_DIR}/${CLUSTER_NAME}-local.yaml (uses 127.0.0.1:${REMOTE_PORT})"
echo "Use: kubectl-${CLUSTER_NAME} get nodes"

# Update kubeconfig secret with both versions
echo "Updating kubeconfig secret..."

KUBECONFIG_PUBLIC_B64=$(base64 -w0 "$KUBECONFIG_PUBLIC_TMP")
KUBECONFIG_LOCAL_B64=$(base64 -w0 "$KUBECONFIG_LOCAL_TMP")
KUBECTL_WRAPPER_B64=$(base64 -w0 "$KUBECTL_WRAPPER")

kubectl patch secret kubeconfig -n "${NAMESPACE}" \
  --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/data/kubeconfig\",\"value\":\"${KUBECONFIG_PUBLIC_B64}\"},{\"op\":\"replace\",\"path\":\"/data/kubeconfig-local\",\"value\":\"${KUBECONFIG_LOCAL_B64}\"},{\"op\":\"replace\",\"path\":\"/data/bin\",\"value\":\"${KUBECTL_WRAPPER_B64}\"}]"

echo "Secret updated successfully"
