#!/usr/bin/env bash
# Example usage of backdoor.sh
# This file is for reference only - customize it for your environment

# Set your variables
BASTION_SSH_HOST="bastion.example.com"
SSH_KEY_PATH="$HOME/.ssh/id_ed25519"
NAMESPACE="backdoor"
CLUSTER_NAME="production"
BASTION_LISTEN_PORT="6443"
BASTION_SSH_USER="tunnel"

# Build and apply (host key will be auto-fetched)
./backdoor.sh \
  --host "$BASTION_SSH_HOST" \
  --identity "$SSH_KEY_PATH" \
  --namespace "$NAMESPACE" \
  --cluster-name "$CLUSTER_NAME" \
  --port "$BASTION_LISTEN_PORT" \
  --user "$BASTION_SSH_USER" \
  --apply

# Or just generate to review first
# ./backdoor.sh \
#   --host "$BASTION_SSH_HOST" \
#   --identity "$SSH_KEY_PATH" \
#   --namespace "$NAMESPACE" \
#   --cluster-name "$CLUSTER_NAME" \
#   --port "$BASTION_LISTEN_PORT" \
#   --user "$BASTION_SSH_USER" \
#   --output ./output

# For security, you can manually provide the host key:
# HOST_KEY=$(ssh-keyscan -t ed25519 "$BASTION_SSH_HOST" 2>/dev/null)
# if [ -z "$HOST_KEY" ]
# then
#   echo "Error: Could not fetch host key from $BASTION_SSH_HOST"
#   exit 1
# fi
# ./backdoor.sh \
#   --host "$BASTION_SSH_HOST" \
#   --identity "$SSH_KEY_PATH" \
#   --host-key "$HOST_KEY" \
#   --namespace "$NAMESPACE" \
#   --cluster-name "$CLUSTER_NAME" \
#   --port "$BASTION_LISTEN_PORT" \
#   --user "$BASTION_SSH_USER" \
#   --apply
