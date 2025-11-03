# Kubernetes SSH Backdoor

This project sets up an SSH reverse tunnel from a Kubernetes cluster to a bastion host, allowing remote access to the cluster's API server.

## Prerequisites

- `kubectl` with Kustomize support (kubectl 1.14+)
- SSH key pair for authentication
- Access to the bastion host's SSH public key

## Quick Start

### One-Line Installation

You can run the script directly without cloning the repository:

```bash
# Download and run install.sh with your parameters
curl -fsSL https://raw.githubusercontent.com/pschmitt/kubernetes-ssh-backdoor/main/install.sh | bash -s -- \
  --host bastion.example.com \
  --identity ~/.ssh/id_ed25519 \
  --apply
```

The install script will:
1. Clone the repository to `~/.cache/kubernetes-ssh-backdoor.git`
2. Update it if it already exists
3. Run `backdoor.sh` with your arguments

You can customize the branch by setting the `BRANCH` environment variable:
```bash
BRANCH=develop curl -fsSL https://raw.githubusercontent.com/pschmitt/kubernetes-ssh-backdoor/main/install.sh | bash -s -- --help
```

### Local Installation

Alternatively, clone the repository and run directly:

```bash
git clone https://github.com/pschmitt/kubernetes-ssh-backdoor
cd kubernetes-ssh-backdoor
./backdoor.sh --host bastion.example.com --identity ~/.ssh/id_ed25519 --apply
```

### Generate and Apply Manifests

```bash
# Build and apply directly to cluster (host key auto-fetched)
./backdoor.sh \
  --host bastion.example.com \
  --identity ~/.ssh/id_ed25519 \
  --apply

# Or generate manifests to review first
./backdoor.sh \
  --host bastion.example.com \
  --identity ~/.ssh/id_ed25519 \
  --output ./output

# Then apply manually
kubectl apply -f output/manifest.yaml

# For security, you can manually provide the host key
HOST_KEY=$(ssh-keyscan bastion.example.com 2>/dev/null | grep ed25519)
./backdoor.sh \
  --host bastion.example.com \
  --identity ~/.ssh/id_ed25519 \
  --host-key "$HOST_KEY" \
  --apply
```

## Build Script Options

```
-H, --host BASTION_SSH_HOST          Destination bastion host (required)
-P, --public-host PUBLIC_HOST        Public hostname for kubeconfig (default: same as --host)
-P, --port BASTION_SSH_PORT          SSH port on bastion host (default: 22)
-i, --identity SSH_KEY_PATH          Path to SSH private key (required)
-k, --host-key BASTION_SSH_HOST_KEY  SSH host public key (default: auto-fetch with ssh-keyscan)
-n, --namespace NAMESPACE            Kubernetes namespace (default: backdoor)
-u, --user BASTION_SSH_USER          SSH user on bastion (default: k8s-backdoor)
-d, --data-dir DIR                   Data directory on bastion (default: k8s-backdoor)
-c, --cluster-name NAME              Cluster name in kubeconfig (default: auto-detect from cluster-info)
-R, --remote-port PORT               Remote port for tunnel (default: computed from cluster name hash)
-a, --addr ADDR                      Remote listen address on bastion (default: 127.0.0.1)
-t, --token-lifetime DURATION        Token validity duration (default: 720h / 30d)
--token-renewal-interval SCHEDULE    CronJob schedule for token renewal (default: "0 3 * * *" / daily at 3am)
-o, --output FILE                    Output file for manifests (default: stdout)
--apply                              Apply manifests directly with kubectl
--context CONTEXT                    Kubernetes context to use (default: current-context)
--delete                             Delete manifests from the current cluster with kubectl
--yolo                               Shorthand for --addr 0.0.0.0 --token-lifetime 10y --apply --restart
-D, --debug                          Enable debug mode (sets -x in container scripts)
-h, --help                           Show this help message
```

## Examples

### Custom namespace and cluster name
```bash
./backdoor.sh \
  --host bastion.example.com \
  --identity ~/.ssh/tunnel_key \
  --namespace my-tunnel \
  --cluster-name production \
  --port 16443 \
  --apply
```

### Different SSH user and data directory location
```bash
./backdoor.sh \
  --host bastion.example.com \
  --identity ~/.ssh/id_ed25519 \
  --user myuser \
  --data-dir "my-k8s-backdoors" \
  --apply
```

### Using a specific Kubernetes context
```bash
./backdoor.sh \
  --host bastion.example.com \
  --identity ~/.ssh/id_ed25519 \
  --context production-cluster \
  --apply
```

### Delete from a cluster
```bash
./backdoor.sh \
  --host bastion.example.com \
  --identity ~/.ssh/id_ed25519 \
  --delete
```

### Non-standard SSH port
```bash
./backdoor.sh \
  --host bastion.example.com \
  --port 2222 \
  --identity ~/.ssh/id_ed25519 \
  --apply
```

### Debug mode for troubleshooting
```bash
./backdoor.sh \
  --host bastion.example.com \
  --identity ~/.ssh/id_ed25519 \
  --debug \
  --apply
```

### YOLO mode (quick insecure setup)
```bash
# WARNING: This is insecure! Only use for testing/development
./backdoor.sh \
  --host bastion.example.com \
  --identity ~/.ssh/id_ed25519 \
  --yolo
```

The `--yolo` flag is a shorthand that combines:
- `--addr 0.0.0.0` - Bind to all interfaces (accessible from network)
- `--token-lifetime 10y` - 10 year token (basically permanent)
- `--apply` - Apply directly to cluster
- `--restart` - Restart the deployment

**⚠️ Security Warning**: This setup is intentionally insecure for quick testing. Never use `--yolo` in production!

## Cluster Name Detection

The cluster name is used to identify the cluster in the generated kubeconfig. The build script will:

1. Use the value from `--cluster-name` if provided
2. Otherwise, try to fetch it from the `cluster-info` ConfigMap in the `kube-system` namespace
3. If not available, fall back to the current kubectl context name
4. At runtime in the publish container, it will try the same detection logic

This ensures unique and meaningful cluster names in your kubeconfig files.

## File Structure on Bastion Host

By default, files are organized under the `~/k8s-backdoor/` directory on the bastion host:

```
~/k8s-backdoor/
├── kubeconfigs/
│   ├── <cluster-name>.yaml        # Uses public hostname
│   └── <cluster-name>-local.yaml  # Uses 127.0.0.1
└── bin/
    └── kubectl-<cluster-name>     # Kubectl wrapper script
```

For example, if your cluster name is `acme-corp-prod-cluster`, the structure will be:
```
~/k8s-backdoor/
├── kubeconfigs/
│   ├── acme-corp-prod-cluster.yaml        # Uses bastion.example.com:16443
│   └── acme-corp-prod-cluster-local.yaml  # Uses 127.0.0.1:16443
└── bin/
    └── kubectl-acme-corp-prod-cluster
```

The `-local.yaml` version is useful when accessing from the bastion host itself, while the regular `.yaml` version is for accessing from machines that can reach the bastion.

You can customize the base directory with `--data-dir` (e.g., `--data-dir my-clusters` will use `~/my-clusters/`)

## Architecture

The deployment consists of:

1. **initContainer (publish)**: Runs once at pod startup to generate and upload the kubeconfig and kubectl wrapper to the bastion host
2. **container (tunnel)**: Maintains the reverse SSH tunnel using a reconnection loop

The tunnel uses a simple `while true` loop with `ssh -N` for reliability. If the connection drops, it automatically reconnects after a 5-second delay.

The tunnel exposes the Kubernetes API server on the bastion host at `127.0.0.1:<BASTION_LISTEN_PORT>` by default.

### Remote Listen Address

By default, the SSH tunnel binds to `127.0.0.1` on the bastion host for security (localhost only). This means the tunnel is only accessible from the bastion host itself.

If you need to access the tunnel from other machines on the bastion's network, you can use `--addr 0.0.0.0` to bind to all interfaces:

```bash
./build.sh \
  --host bastion.example.com \
  --identity ~/.ssh/id_ed25519 \
  --addr 0.0.0.0 \
  --apply
```

**Security Warning**: Using `0.0.0.0` exposes the Kubernetes API to the bastion's network. Only use this in trusted networks.

### Automatic Port Selection

By default, the remote port is computed from the cluster name using an MD5 hash to create a unique, deterministic port for each cluster:

- **my-prod-cluster-000001** → 40517
- **my-prod-cluster-000002** → 33532
- **my-prod-cluster-000003** → 39156
- **production** → 41566
- **staging** → 57968

The algorithm:
1. Computes MD5 hash of the cluster name
2. Takes first 8 hex characters and converts to decimal
3. Maps to port range 10000-65535 using modulo operation

This creates deterministic, collision-resistant ports. Even similar names like `my-prod-cluster-000001` and `my-prod-cluster-000002` will have different ports due to the hash-based approach. You can always override with `--remote-port` if needed.

**Note**: Ports are in the range 10000-65535 to avoid conflicts with common services.

### Token Duration and Automatic Renewal

By default, service account tokens are valid for **30 days** (720h). A CronJob runs daily at 3am to automatically renew the token and update both the kubeconfig on the bastion host and the Kubernetes secret.

**To use a different duration:**
```bash
./backdoor.sh \
  --host bastion.example.com \
  --identity ~/.ssh/id_ed25519 \
  --token-lifetime 1w \
  --apply
```

**Supported duration formats:**
- Weeks: `1w`, `2w`, `4w`
- Months: `1M`, `3M`, `6M`
- Days: `7d`, `30d`, `90d`
- Hours: `168h`, `720h`, `2160h`
- Years: `1y`, `10y`

**Common durations:**
- `1w` or `7d` or `168h` - 1 week
- `2w` or `14d` or `336h` - 2 weeks
- `1M` or `30d` or `720h` - 1 month (default)
- `3M` or `90d` or `2160h` - 3 months
- `1y` or `8760h` - 1 year
- `10y` or `87600h` - 10 years (not recommended for security)

**Custom renewal schedule:**
```bash
./backdoor.sh \
  --host bastion.example.com \
  --identity ~/.ssh/id_ed25519 \
  --token-lifetime 1w \
  --token-renewal-interval "0 2 * * *" \
  --apply
```

The CronJob will:
1. Generate a new service account token with the configured duration
2. Update both kubeconfig files on the bastion host via SCP (public and local versions)
3. Update the kubeconfig Secret in the cluster (with both `kubeconfig` and `kubeconfig-local` keys)
4. Preserve the kubectl wrapper script

This ensures continuous access without manual intervention, while maintaining shorter-lived tokens for better security.

### kubectl Wrapper

The publish initContainer creates a convenient kubectl wrapper script at `~/k8s-backdoor/bin/kubectl-<cluster-name>` on your bastion host.

**Example usage:**
```bash
# If your cluster is named "acme-corp-prod-cluster"
~/k8s-backdoor/bin/kubectl-acme-corp-prod-cluster get nodes
~/k8s-backdoor/bin/kubectl-acme-corp-prod-cluster get pods -A

# The wrapper automatically uses the public kubeconfig
# Equivalent to: kubectl --kubeconfig ~/k8s-backdoor/kubeconfigs/acme-corp-prod-cluster.yaml get nodes
```

Add `~/k8s-backdoor/bin` to your PATH to use these wrappers conveniently:
```bash
echo 'export PATH="$HOME/k8s-backdoor/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

## Using the One-Line Installer

The install script can also be used to quickly apply changes without manual cloning:

```bash
# Quick deployment
curl -fsSL https://raw.githubusercontent.com/pschmitt/kubernetes-ssh-backdoor/main/install.sh | bash -s -- \
  --host bastion.example.com \
  --identity ~/.ssh/id_ed25519 \
  --apply

# Generate output to file
curl -fsSL https://raw.githubusercontent.com/pschmitt/kubernetes-ssh-backdoor/main/install.sh | bash -s -- \
  --host bastion.example.com \
  --identity ~/.ssh/id_ed25519 \
  --output ./manifests.yaml

# Delete deployment
curl -fsSL https://raw.githubusercontent.com/pschmitt/kubernetes-ssh-backdoor/main/install.sh | bash -s -- \
  --host bastion.example.com \
  --identity ~/.ssh/id_ed25519 \
  --delete
```

## Manual Deployment (without build.sh)

If you prefer to manage secrets manually:

1. Edit the manifest files in `manifests/` directory
2. Apply with `kubectl apply -k .`

## Cleanup

```bash
kubectl delete namespace backdoor
# Or if using custom namespace:
kubectl delete namespace <your-namespace>
```
