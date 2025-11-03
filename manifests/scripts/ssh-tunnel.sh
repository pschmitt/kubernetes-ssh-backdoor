#!/usr/bin/env sh
set -eu
if [ -n "${DEBUG:-}" ]
then
  set -x
fi

# Setup SSH directory and keys
mkdir -p /config/.ssh
cp /keys/id_ed25519 /config/.ssh/id_ed25519
chmod 600 /config/.ssh/id_ed25519

# Configure host key checking based on whether BASTION_SSH_HOST_KEY is provided
if [ -n "${BASTION_SSH_HOST_KEY:-}" ]
then
  # Write known_hosts from ConfigMap env var
  echo "$BASTION_SSH_HOST_KEY" > /config/.ssh/known_hosts
  chmod 644 /config/.ssh/known_hosts
  HOSTKEY_CHECK_OPTS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=/config/.ssh/known_hosts"
else
  # Disable strict host key checking if no host key provided
  HOSTKEY_CHECK_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
fi

# Common SSH options for tunnel
SSH_TUNNEL_OPTS="
  -o ControlMaster=no
  -o ControlPath=none
  -o ServerAliveInterval=10
  -o ServerAliveCountMax=3
  ${HOSTKEY_CHECK_OPTS}
  -o ExitOnForwardFailure=yes
  -i /config/.ssh/id_ed25519
  -p ${BASTION_SSH_PORT}
"

# SSH tunnel loop with automatic reconnection
while true
do
  echo "Starting SSH tunnel to ${BASTION_SSH_HOST}:${BASTION_SSH_PORT}..."
  # shellcheck disable=SC2086
  ssh -N $SSH_TUNNEL_OPTS \
    -R "${REMOTE_LISTEN_ADDR}:${REMOTE_PORT}:kubernetes.default.svc:443" \
    "${BASTION_SSH_USER}@${BASTION_SSH_HOST}"

  EXIT_CODE=$?
  echo "SSH tunnel disconnected with exit code ${EXIT_CODE}"

  # Wait before reconnecting
  echo "Waiting 5 seconds before reconnecting..."
  sleep 5
done
