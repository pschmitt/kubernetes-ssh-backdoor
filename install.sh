#!/usr/bin/env bash

set -euo pipefail

# Configuration
REPO_URL="${REPO_URL:-https://github.com/pschmitt/kubernetes-ssh-backdoor}"
INSTALL_DIR="${INSTALL_DIR:-${HOME}/.cache/kubernetes-ssh-backdoor.git}"
BRANCH="${BRANCH:-main}"

# Color codes
BOLD_YELLOW='\033[1;33m'
BOLD_GREEN='\033[1;32m'
BOLD_BLUE='\033[1;34m'
BOLD_RED='\033[1;31m'
RESET='\033[0m'

echo_info() {
  echo -e "${BOLD_BLUE}INF${RESET} $*" >&2
}

echo_success() {
  echo -e "${BOLD_GREEN}OK${RESET} $*" >&2
}

echo_error() {
  echo -e "${BOLD_RED}ERR${RESET} $*" >&2
}

# Check for required tools
if ! command -v git >/dev/null 2>&1
then
  echo_error "git is not installed. Please install git and try again."
  exit 1
fi

# Clone or update the repository
if [[ -d "$INSTALL_DIR" ]]
then
  echo_info "Repository already exists at ${BOLD_YELLOW}${INSTALL_DIR}${RESET}, updating..."
  cd "$INSTALL_DIR"
  git fetch origin >/dev/null 2>&1
  git checkout "$BRANCH" >/dev/null 2>&1
  git reset --hard "origin/$BRANCH" >/dev/null 2>&1
  echo_success "Repository updated to ${BOLD_YELLOW}${BRANCH}${RESET}"
else
  echo_info "Cloning repository to ${BOLD_YELLOW}${INSTALL_DIR}${RESET}..."
  git clone --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR" >/dev/null 2>&1
  echo_success "Repository cloned successfully"
fi

# Run backdoor.sh with all passed arguments
echo_info "Running backdoor.sh with arguments: ${BOLD_YELLOW}$*${RESET}"
cd "$INSTALL_DIR"
exec ./backdoor.sh "$@"
