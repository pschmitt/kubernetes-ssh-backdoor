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
-d, --kubeconfig-dir DIR         Kubeconfig directory on bastion (default: .kube/config.d)
-f, --kubeconfig-name NAME       Kubeconfig filename on bastion (default: config-<cluster-name>)
-c, --cluster-name NAME          Cluster name in kubeconfig (default: auto-detect from cluster-info)
-p, --remote-port PORT           Remote port for tunnel (default: computed from cluster name via T9)
-o, --output DIR                 Output directory for manifests (default: stdout)
-a, --apply                      Apply manifests directly with kubectl
--debug                          Enable debug mode (sets -x in container scripts)
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

### Debug mode for troubleshooting
```bash
./build.sh \
  --host bastion.example.com \
  --identity ~/.ssh/id_ed25519 \
  --debug \
  --apply
```

## Cluster Name Detection

The cluster name is used to identify the cluster in the generated kubeconfig. The build script will:

1. Use the value from `--cluster-name` if provided
2. Otherwise, try to fetch it from the `cluster-info` ConfigMap in the `kube-system` namespace
3. If not available, fall back to the current kubectl context name
4. At runtime in the publish container, it will try the same detection logic

This ensures unique and meaningful cluster names in your kubeconfig files.

## Kubeconfig File Naming

By default, kubeconfig files are pushed to `~/.kube/config.d/config-<cluster-name>` on the bastion host.

For example, if your cluster name is `wiit-edge-002`, the file will be:
```
~/.kube/config.d/config-wiit-edge-002
```

You can customize this with:
- `--kubeconfig-dir` to change the directory (e.g., `.kube/clusters`)
- `--kubeconfig-name` to set a specific filename (e.g., `production`)

## Architecture

The deployment consists of:

1. **initContainer (publish)**: Runs once at pod startup to generate and upload the kubeconfig and kubectl wrapper to the bastion host
2. **container (tunnel)**: Maintains the reverse SSH tunnel using a reconnection loop

The tunnel uses a simple `while true` loop with `ssh -N` for reliability. If the connection drops, it automatically reconnects after a 5-second delay.

The tunnel exposes the Kubernetes API server on the bastion host at `127.0.0.1:<REMOTE_PORT>`.

### Automatic Port Selection

By default, the remote port is computed from the cluster name using T9 (phone keypad) encoding to create a unique, memorable port for each cluster:

- **wiit-edge-002** → 9448 (94483343 truncated to fit valid port range)
- **production** → 7764 (7763828466 truncated)
- **staging** → 7824

The algorithm:
1. Converts cluster name to numbers using T9 encoding (abc=2, def=3, etc.)
2. Truncates from the right if the number is too large (>65535)
3. Ensures the port is >= 1024

This creates deterministic, collision-resistant ports that are easy to remember. You can always override with `--remote-port` if needed.

**Note**: Ports below 1024 require privileged access on most systems, so all computed ports are >= 1024.

### kubectl Wrapper

The publish initContainer creates a convenient kubectl wrapper script at `~/bin/kubectl-<cluster-name>` on your bastion host.

**Example usage:**
```bash
# If your cluster is named "wiit-edge-002"
kubectl-wiit-edge-002 get nodes
kubectl-wiit-edge-002 get pods -A

# The wrapper automatically uses the correct kubeconfig
# Equivalent to: kubectl --kubeconfig ~/.kube/config.d/config-wiit-edge-002 get nodes
```

Add `~/bin` to your PATH to use these wrappers conveniently:
```bash
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

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
