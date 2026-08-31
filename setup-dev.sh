#!/bin/bash
# =============================================================
# Bullwheel Dev Environment Setup  (VS Code-owned container creation)
#
# Clones the Barrie's frappe_docker fork, configures the devcontainer,
# and wires the Frappe installer into the container's postCreate lifecycle.
#
# Unlike the previous version, this script does NOT start the containers or
# run the installer itself. It hands container creation to VS Code so that
# the create-time step (which installs the extensions listed in
# devcontainer.json) actually runs. The installer is executed by VS Code as
# part of postCreateCommand, inside the freshly-created container.
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

command -v git     &>/dev/null || error "git is not installed."
command -v docker  &>/dev/null || error "Docker is not installed."
command -v python3 &>/dev/null || error "python3 is not installed (needed to patch devcontainer.json)."
command -v code    &>/dev/null || warn "VS Code CLI ('code') not found. You will need to open the folder manually."

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
    warn ".devcontainer already exists. Skipping copy (bootstrap + postCreate are refreshed below)."
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

# ── Write the in-container bootstrap script ──────────────────
# This runs INSIDE the dev container via postCreateCommand, AFTER VS Code has
# created the container and installed the extensions from devcontainer.json.
# It waits for MariaDB, installs pre-commit, and runs the Frappe installer.
# (Re)written on every run so the logic stays in sync.
info "Writing .devcontainer/bootstrap.sh..."
cat > .devcontainer/bootstrap.sh <<'BOOTSTRAP'
#!/bin/bash
# Runs inside the Frappe dev container at postCreate time.
set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[bootstrap]${NC} $1"; }
warn() { echo -e "${YELLOW}[bootstrap]${NC} $1"; }

cd /workspace/development

# Wait for the MariaDB compose service to accept TCP connections.
# (From inside the frappe container the DB host is the service name "mariadb".)
log "Waiting for MariaDB to accept connections..."
ATTEMPTS=0
until (echo > /dev/tcp/mariadb/3306) 2>/dev/null; do
    ATTEMPTS=$((ATTEMPTS + 1))
    if [ "$ATTEMPTS" -ge 30 ]; then
        echo "[bootstrap] Timed out waiting for MariaDB." >&2
        exit 1
    fi
    sleep 2
done
log "MariaDB is reachable."

# Dev tooling (uv ships in the frappe/bench image).
log "Installing pre-commit..."
uv tool install pre-commit || warn "pre-commit install reported an issue (it may already be installed)."

# Create the bench + site only if it doesn't exist yet. installer.py is
# non-interactive (reads apps-example.json, site development.localhost,
# admin/admin). The bench lives on the bind-mounted workspace, so on a
# container rebuild it is already present and we skip re-running.
if [ -d "frappe-bench" ]; then
    log "frappe-bench already exists; skipping installer."
    log "To rebuild it: remove the frappe-bench folder, then run 'python installer.py'."
else
    log "Running Frappe installer (clones frappe + erpnext and builds the bench; several minutes)..."
    python installer.py
fi

log "Bootstrap complete. Start the bench with: cd frappe-bench && bench start"
BOOTSTRAP
chmod +x .devcontainer/bootstrap.sh

# ── Point postCreateCommand at the bootstrap script ──────────
# Patch only this one field so the rest of devcontainer.json (extension list,
# settings) continues to come straight from devcontainer-example. Idempotent:
# re-running converges to the same value.
info "Wiring postCreateCommand -> bootstrap.sh in .devcontainer/devcontainer.json..."
python3 - <<'PYEOF'
import json
path = ".devcontainer/devcontainer.json"
with open(path) as f:
    cfg = json.load(f)
target = "bash /workspace/.devcontainer/bootstrap.sh"
if cfg.get("postCreateCommand") != target:
    cfg["postCreateCommand"] = target
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    print("  postCreateCommand updated.")
else:
    print("  postCreateCommand already set.")
PYEOF

# ── Hand off to VS Code (it creates the container + installs extensions) ─
echo ""
info "Setup complete!"
echo -e "${YELLOW}  → When VS Code opens, run: Dev Containers: Reopen in Container${NC}"
echo -e "${YELLOW}    VS Code will build the container, install the extensions, and run${NC}"
echo -e "${YELLOW}    the installer automatically. Watch the 'postCreate' progress/log.${NC}"
echo -e "${YELLOW}    (Use 'Reopen in Container', NOT 'Attach to Running Container'.)${NC}"
echo ""

if command -v code &>/dev/null; then
    code .
else
    warn "Open VS Code manually in: $(pwd)"
fi
