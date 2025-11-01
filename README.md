# Kubernetes SSH Backdoor

This project sets up an SSH reverse tunnel from a Kubernetes cluster to a bastion host, allowing remote access to the cluster's API server.

## Prerequisites

- `kubectl` with Kustomize support (kubectl 1.14+)
- SSH key pair for authentication
- Access to the bastion host's SSH public key

## Quick Start

### Generate and Apply Manifests

```bash
# Build and apply directly to cluster (host key auto-fetched)
./build.sh \
  --host bastion.example.com \
  --identity ~/.ssh/id_ed25519 \
  --apply

# Or generate manifests to review first
./build.sh \
  --host bastion.example.com \
  --identity ~/.ssh/id_ed25519 \
  --output ./output

# Then apply manually
kubectl apply -f output/manifest.yaml

# For security, you can manually provide the host key
HOST_KEY=$(ssh-keyscan bastion.example.com 2>/dev/null | grep ed25519)
./build.sh \
  --host bastion.example.com \
  --identity ~/.ssh/id_ed25519 \
  --host-key "$HOST_KEY" \
  --apply
```

## Build Script Options

```
-h, --host BASTION_HOST          Destination bastion host (required)
-P, --port BASTION_PORT          SSH port on bastion host (default: 22)
-i, --identity SSH_KEY_PATH      Path to SSH private key (required)
-k, --host-key HOST_PUBLIC_KEY   SSH host public key (default: auto-fetch with ssh-keyscan)
-n, --namespace NAMESPACE        Kubernetes namespace (default: ssh-tunnel)
-u, --user BASTION_USER          SSH user on bastion (default: tunnel)
-d, --kubeconfig-dir DIR         Kubeconfig directory on bastion (default: $HOME/.kube)
-f, --kubeconfig-name NAME       Kubeconfig filename on bastion (default: config)
-c, --cluster-name NAME          Cluster name in kubeconfig (default: kubernetes)
-p, --remote-port PORT           Remote port for tunnel (default: 6443)
-o, --output DIR                 Output directory for manifests (default: stdout)
-a, --apply                      Apply manifests directly with kubectl
```

## Examples

### Custom namespace and cluster name
```bash
./build.sh \
  --host bastion.example.com \
  --identity ~/.ssh/tunnel_key \
  --namespace my-tunnel \
  --cluster-name production \
  --port 16443 \
  --apply
```

### Different SSH user and kubeconfig location
```bash
./build.sh \
  --host bastion.example.com \
  --identity ~/.ssh/id_ed25519 \
  --user myuser \
  --kubeconfig-dir "/home/myuser/kube-configs" \
  --kubeconfig-name "prod-cluster.yaml" \
  --apply
```

### Non-standard SSH port
```bash
./build.sh \
  --host bastion.example.com \
  --port 2222 \
  --identity ~/.ssh/id_ed25519 \
  --apply
```

## Architecture

The deployment consists of two containers:

1. **tunnel**: Maintains the reverse SSH tunnel using `autossh`
2. **publish**: Generates and uploads the kubeconfig to the bastion host

The tunnel exposes the Kubernetes API server on the bastion host at `127.0.0.1:<REMOTE_PORT>`.

## Manual Deployment (without build.sh)

If you prefer to manage secrets manually:

1. Edit the manifest files in `manifests/` directory
2. Apply with `kubectl apply -k .`

## Cleanup

```bash
kubectl delete namespace ssh-tunnel
# Or if using custom namespace:
kubectl delete namespace <your-namespace>
```
