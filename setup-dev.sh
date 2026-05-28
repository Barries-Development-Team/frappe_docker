#!/bin/bash
# =============================================================
# Bullwheel Dev Environment Setup
# Clones the Barrie's frappe_docker fork, configures it
# for devcontainer development, and runs the Frappe installer.
#
# Usage: bash setup-dev.sh
# =============================================================

set -e  # exit on any error

# ── Colors for output ────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

trap 'echo -e "${RED}[ERROR]${NC} Setup failed at line $LINENO. Check the output above for details." >&2' ERR

# ── Prerequisite checks ──────────────────────────────────────
info "Checking prerequisites..."

command -v git    &>/dev/null || error "git is not installed."
command -v docker &>/dev/null || error "Docker is not installed."
command -v code   &>/dev/null || warn "VS Code CLI ('code') not found. You will need to open the folder manually."

# Warn if running from Windows filesystem (common WSL mistake)
if echo "$PWD" | grep -q "^/mnt/"; then
    error "You are on the Windows filesystem ($PWD). Please run this script from your WSL home directory (e.g. ~/projects) to avoid Docker bind mount issues."
fi

# ── Clone fork ───────────────────────────────────────────────
REPO_URL="https://github.com/Barries-Development-Team/frappe_docker.git"
CLONE_DIR="frappe_docker"

if [ -d "$CLONE_DIR" ]; then
    warn "Directory '$CLONE_DIR' already exists. Skipping clone."
    cd "$CLONE_DIR"
else
    info "Cloning fork from $REPO_URL..."
    git clone "$REPO_URL"
    cd "$CLONE_DIR"
fi

# ── Add upstream remote ──────────────────────────────────────
if git remote | grep -q "^upstream$"; then
    warn "Upstream remote already exists. Skipping."
else
    info "Adding upstream remote..."
    git remote add upstream https://github.com/frappe/frappe_docker.git
fi

info "Remotes configured:"
git remote -v

# ── Checkout develop branch ──────────────────────────────────
info "Checking out develop branch..."
git checkout develop

# ── Copy devcontainer config ─────────────────────────────────
if [ -d ".devcontainer" ]; then
    warn ".devcontainer already exists. Skipping copy."
else
    info "Copying devcontainer configuration..."
    cp -R devcontainer-example .devcontainer
fi

if [ -d "development/.vscode" ]; then
    warn "development/.vscode already exists. Skipping copy."
else
    info "Copying VS Code devcontainer settings..."
    cp -R development/vscode-example development/.vscode
fi

# ── Start devcontainer via Docker Compose ────────────────────
# Match the project name VS Code Dev Containers uses so both share
# the same containers and volumes instead of creating duplicates.
DC_PROJECT="$(basename "$PWD")_devcontainer"
DC="docker compose --project-name $DC_PROJECT -f .devcontainer/docker-compose.yml"

info "Starting devcontainer services..."
$DC up -d || error "Failed to start devcontainer services. Check that Docker is running and ports 8000-8005 are available."

# Wait for the frappe container to be running and healthy
info "Waiting for frappe container to be ready..."
FRAPPE_CONTAINER=""
ATTEMPTS=0
MAX_ATTEMPTS=30

while [ -z "$FRAPPE_CONTAINER" ]; do
    FRAPPE_CONTAINER=$($DC ps -q frappe 2>/dev/null || true)
    ATTEMPTS=$((ATTEMPTS + 1))
    if [ $ATTEMPTS -ge $MAX_ATTEMPTS ]; then
        error "Timed out waiting for frappe container to start."
    fi
    [ -z "$FRAPPE_CONTAINER" ] && sleep 2
done

info "Frappe container is up: $FRAPPE_CONTAINER"

# Wait for MariaDB to be healthy before running the installer
info "Waiting for MariaDB to be ready..."
ATTEMPTS=0
until $DC exec -T mariadb mariadb-admin ping -h localhost -u root -p123 --silent </dev/null 2>/dev/null; do
    ATTEMPTS=$((ATTEMPTS + 1))
    if [ $ATTEMPTS -ge $MAX_ATTEMPTS ]; then
        error "Timed out waiting for MariaDB to be ready."
    fi
    sleep 2
done
info "MariaDB is ready."

# ── Run Frappe installer ──────────────────────────────────────
info "Running Frappe installer (this will take several minutes)..."
$DC exec -T frappe python installer.py </dev/null || error "Frappe installer failed. Check the output above for details."

# ── Open VS Code ─────────────────────────────────────────────
echo ""
info "Setup complete! Opening VS Code..."
echo -e "${YELLOW}  → When VS Code opens, run: Dev Containers: Reopen in Container${NC}"
echo ""

if command -v code &>/dev/null; then
    code .
else
    warn "Open VS Code manually in: $(pwd)"
fi
