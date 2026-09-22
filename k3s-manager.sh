#!/usr/bin/env bash
#
# k3s-manager.sh — install, join, manage, and fail over a k3s cluster.
#
# Works on any systemd or OpenRC Linux distro (Debian/Ubuntu, RHEL/CentOS/Rocky/Alma,
# Fedora, openSUSE/SLES, Arch, Alpine). Detects the package manager and installs the
# right prerequisites before handing off to the official k3s installer.
#
# Run "k3s-manager.sh help" for full usage.
#

set -euo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------------------------------
# Constants / paths
# ------------------------------------------------------------------------------------

CONFIG_DIR="/etc/k3s-manager"
CONFIG_FILE="${CONFIG_DIR}/config.env"
LOG_FILE="/var/log/k3s-manager.log"
SNAPSHOT_DIR="/var/lib/k3s-manager/snapshots"
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"

WATCHDOG_SCRIPT="/usr/local/bin/k3s-manager-watchdog.sh"
WATCHDOG_SERVICE="/etc/systemd/system/k3s-manager-watchdog.service"
WATCHDOG_TIMER="/etc/systemd/system/k3s-manager-watchdog.timer"

SNAPSHOT_SYNC_SERVICE="/etc/systemd/system/k3s-manager-snapsync.service"
SNAPSHOT_SYNC_TIMER="/etc/systemd/system/k3s-manager-snapsync.timer"

# ------------------------------------------------------------------------------------
# Basic helpers
# ------------------------------------------------------------------------------------

log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

err() {
    echo "ERROR: $*" >&2
    exit 1
}

have() {
    command -v "$1" >/dev/null 2>&1
}

need_root() {
    [[ $EUID -eq 0 ]] || err "This command must be run as root (use sudo)."
}

ensure_config_dir() {
    mkdir -p "$CONFIG_DIR"
}

save_config() {
    ensure_config_dir
    env | grep -E '^K3SMGR_' > "$CONFIG_FILE" 2>/dev/null || true
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] && . "$CONFIG_FILE" || true
}

write_role_config() {
    local role="$1"

    ensure_config_dir

    cat > "${CONFIG_FILE}.tmp" <<EOF
K3SMGR_ROLE=${role}
EOF

    mv -f "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

default_ip() {
    ip -4 route get 1.1.1.1 2>/dev/null |
        awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' ||
        hostname -I | awk '{print $1}'
}

# ------------------------------------------------------------------------------------
# OS / distro detection
# ------------------------------------------------------------------------------------

detect_os() {
    [[ -f /etc/os-release ]] ||
        err "Cannot detect OS: /etc/os-release is missing."

    . /etc/os-release

    OS_ID="${ID,,}"

    # ID_LIKE is optional on Debian/Raspberry Pi OS/etc.
    OS_LIKE="${ID_LIKE:-}"
    OS_LIKE="${OS_LIKE,,}"

    if have apt-get; then
        PKG=apt
    elif have dnf; then
        PKG=dnf
    elif have yum; then
        PKG=yum
    elif have zypper; then
        PKG=zypper
    elif have pacman; then
        PKG=pacman
    elif have apk; then
        PKG=apk
    else
        err "No supported package manager found (looked for apt/dnf/yum/zypper/pacman/apk)."
    fi

    if have systemctl && systemctl --version >/dev/null 2>&1; then
        INIT=systemd
    elif have rc-service; then
        INIT=openrc
    else
        err "k3s requires systemd or OpenRC; neither was found."
    fi

    log "Detected distro=${OS_ID} package-manager=${PKG} init=${INIT}"
}

# ------------------------------------------------------------------------------------
# Prerequisites
# ------------------------------------------------------------------------------------

install_prereqs() {
    need_root

    log "Installing prerequisites for ${PKG}..."

    case "$PKG" in
        apt)
            export DEBIAN_FRONTEND=noninteractive

            apt-get update -y

            apt-get install -y \
                curl \
                ca-certificates \
                open-iscsi \
                nfs-common \
                apparmor \
                apparmor-utils \
                socat \
                conntrack || true
            ;;

        dnf)
            dnf install -y \
                curl \
                iscsi-initiator-utils \
                nfs-utils \
                socat \
                conntrack-tools || true

            systemctl enable --now iscsid 2>/dev/null || true
            ;;

        yum)
            yum install -y \
                curl \
                iscsi-initiator-utils \
                nfs-utils \
                socat \
                conntrack-tools || true

            systemctl enable --now iscsid 2>/dev/null || true
            ;;

        zypper)
            zypper --non-interactive install \
                curl \
                open-iscsi \
                nfs-client \
                socat \
                conntrack-tools || true

            systemctl enable --now iscsid 2>/dev/null || true
            ;;

        pacman)
            pacman -Sy --noconfirm \
                curl \
                open-iscsi \
                nfs-utils \
                socat \
                conntrack-tools || true

            systemctl enable --now iscsid 2>/dev/null || true
            ;;

        apk)
            apk add --no-cache \
                curl \
                open-iscsi \
                nfs-utils \
                socat \
                conntrack-tools || true

            rc-update add iscsid default 2>/dev/null || true
            rc-service iscsid start 2>/dev/null || true
            ;;
    esac
}

# ------------------------------------------------------------------------------------
# kubectl helper
# ------------------------------------------------------------------------------------

kctl() {
    [[ -f "$KUBECONFIG_PATH" ]] ||
        err "No kubeconfig at $KUBECONFIG_PATH — run this on a master node."

    KUBECONFIG="$KUBECONFIG_PATH" k3s kubectl "$@"
}

# ------------------------------------------------------------------------------------
# Installation
# ------------------------------------------------------------------------------------

usage_install() {
    cat <<'EOF'
Usage:
  k3s-manager.sh install master [--ha] [--worker] [--token TOKEN]
  k3s-manager.sh install join-master --server https://MASTER_IP:6443 --token TOKEN [--worker]
  k3s-manager.sh install worker --server https://MASTER_IP:6443 --token TOKEN

  --ha       start this master with embedded etcd, ready for other masters to join (cluster-init)
  --worker   also schedule normal workloads on this master (master doubles as a worker)
  --token    set/use a specific cluster token instead of the auto-generated one
EOF
}

cmd_install() {
    need_root
    detect_os
    install_prereqs

    local subrole="${1:-}"
    shift || true

    local ha=false
    local worker=false
    local server=""
    local token=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ha)
                ha=true
                shift
                ;;

            --worker)
                worker=true
                shift
                ;;

            --server)
                [[ $# -ge 2 ]] || err "--server requires a value"
                server="$2"
                shift 2
                ;;

            --token)
                [[ $# -ge 2 ]] || err "--token requires a value"
                token="$2"
                shift 2
                ;;

            *)
                err "Unknown option: $1"
                ;;
        esac
    done

    case "$subrole" in

        master)
            local exec_args="server"

            $ha && exec_args="$exec_args --cluster-init"

            [[ -n "$token" ]] &&
                exec_args="$exec_args --token $token"

            log "Installing k3s server (master${ha:+, HA cluster-init})..."

            curl -sfL https://get.k3s.io |
                INSTALL_K3S_EXEC="$exec_args" sh -

            # FIX: create directory BEFORE writing config
            write_role_config "master"

            $worker && untaint_self

            if [[ "$INIT" == "systemd" ]]; then
                systemctl enable k3s 2>/dev/null || true
            else
                rc-update add k3s default 2>/dev/null || true
            fi

            log "Master installed."
            log "Node token: $(cat /var/lib/rancher/k3s/server/node-token 2>/dev/null || echo 'n/a')"
            log "Kubeconfig: $KUBECONFIG_PATH"
            ;;

        join-master)
            [[ -n "$server" && -n "$token" ]] ||
                err "join-master requires --server and --token"

            log "Joining as additional HA master, connecting to $server ..."

            curl -sfL https://get.k3s.io |
                INSTALL_K3S_EXEC="server --server $server --token $token" sh -

            # FIX: create directory BEFORE writing config
            write_role_config "master"

            $worker && untaint_self

            if [[ "$INIT" == "systemd" ]]; then
                systemctl enable k3s 2>/dev/null || true
            else
                rc-update add k3s default 2>/dev/null || true
            fi

            log "Joined etcd cluster as master."
            ;;

        worker)
            [[ -n "$server" && -n "$token" ]] ||
                err "worker install requires --server and --token"

            log "Installing k3s agent (worker), joining $server ..."

            curl -sfL https://get.k3s.io |
                K3S_URL="$server" K3S_TOKEN="$token" sh -

            # FIX: create directory BEFORE writing config
            write_role_config "worker"

            if [[ "$INIT" == "systemd" ]]; then
                systemctl enable k3s-agent 2>/dev/null || true
            else
                rc-update add k3s-agent default 2>/dev/null || true
            fi

            log "Worker joined the cluster."
            ;;

        *)
            usage_install
            err "Specify install target: master | join-master | worker"
            ;;
    esac
}

# ------------------------------------------------------------------------------------
# Master workload scheduling
# ------------------------------------------------------------------------------------

untaint_self() {
    local node
    node="$(hostname)"

    sleep 5

    KUBECONFIG="$KUBECONFIG_PATH" k3s kubectl taint nodes "$node" \
        node-role.kubernetes.io/master- \
        node-role.kubernetes.io/control-plane- \
        --overwrite 2>/dev/null || true

    log "Removed scheduling taint from $node — this master will also run workloads."
}

# ------------------------------------------------------------------------------------
# Boot-on-startup control
# ------------------------------------------------------------------------------------

cmd_enable_boot() {
    need_root

    local svc="k3s"

    [[ -f "$CONFIG_FILE" ]] && . "$CONFIG_FILE"

    [[ "${K3SMGR_ROLE:-}" == "worker" ]] &&
        svc="k3s-agent"

    if [[ "$INIT" == "systemd" ]]; then
        systemctl enable "$svc" 2>/dev/null &&
            log "$svc enabled on boot (systemd)." ||
            true
    else
        rc-update add "$svc" default 2>/dev/null &&
            log "$svc enabled on boot (OpenRC)." ||
            true
    fi
}

cmd_disable_boot() {
    need_root

    local svc="k3s"

    [[ -f "$CONFIG_FILE" ]] && . "$CONFIG_FILE"

    [[ "${K3SMGR_ROLE:-}" == "worker" ]] &&
        svc="k3s-agent"

    if [[ "$INIT" == "systemd" ]]; then
        systemctl disable "$svc" 2>/dev/null &&
            log "$svc disabled on boot (systemd)." ||
            true
    else
        rc-update del "$svc" default 2>/dev/null &&
            log "$svc disabled on boot (OpenRC)." ||
            true
    fi
}

# ------------------------------------------------------------------------------------
# Status
# ------------------------------------------------------------------------------------

cmd_status() {
    if [[ -f "$KUBECONFIG_PATH" ]]; then
        echo "--- Cluster nodes ---"
        kctl get nodes -o wide

        echo
        echo "--- k3s service ---"

        if [[ "$INIT" == "systemd" ]]; then
            systemctl status k3s --no-pager 2>/dev/null || true
        else
            rc-service k3s status 2>/dev/null || true
        fi
    else
        echo "--- k3s-agent service (worker node) ---"

        if [[ "$INIT" == "systemd" ]]; then
            systemctl status k3s-agent --no-pager 2>/dev/null || true
        else
            rc-service k3s-agent status 2>/dev/null || true
        fi
    fi
}

cmd_token() {
    need_root

    [[ -f /var/lib/rancher/k3s/server/node-token ]] ||
        err "No node token here — this isn't a master."

    echo "Server URL: https://$(default_ip):6443"
    echo "Token:      $(cat /var/lib/rancher/k3s/server/node-token)"
}

cmd_list_nodes() {
    kctl get nodes -o wide
}

# ------------------------------------------------------------------------------------
# Add / remove nodes
# ------------------------------------------------------------------------------------

usage_add_node() {
    cat <<'EOF'
Usage:
  k3s-manager.sh add-node worker [--ssh user@host]
  k3s-manager.sh add-node master [--ssh user@host]

Without --ssh, prints the exact command to run on the new machine.
With --ssh, remotely runs it over SSH (target needs curl and sudo).
EOF
}

cmd_add_node() {
    need_root

    local kind="${1:-}"
    shift || true

    local ssh_target=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ssh)
                [[ $# -ge 2 ]] || err "--ssh requires a target"
                ssh_target="$2"
                shift 2
                ;;

            *)
                err "Unknown option: $1"
                ;;
        esac
    done

    [[ -f /var/lib/rancher/k3s/server/node-token ]] ||
        err "Run add-node from a master node."

    local server="https://$(default_ip):6443"
    local token
    token="$(cat /var/lib/rancher/k3s/server/node-token)"

    local cmd=""

    case "$kind" in
        worker)
            cmd="curl -sfL https://raw.githubusercontent.com/YOUR_ORG/k3s-manager/main/k3s-manager.sh -o /tmp/k3s-manager.sh 2>/dev/null; bash /tmp/k3s-manager.sh install worker --server $server --token $token || (curl -sfL https://get.k3s.io | K3S_URL=$server K3S_TOKEN=$token sh -)"
            ;;

        master)
            cmd="curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC=\"server --server $server --token $token\" sh -"
            ;;

        *)
            usage_add_node
            err "Specify node type: worker | master"
            ;;
    esac

    if [[ -n "$ssh_target" ]]; then
        log "Provisioning $kind node over SSH ($ssh_target)..."

        ssh \
            -o StrictHostKeyChecking=accept-new \
            "$ssh_target" \
            "sudo bash -c '$cmd'"

        log "Remote $kind node install triggered."
    else
        echo "Run this on the new node:"
        echo
        echo "  $cmd"
        echo
    fi
}

cmd_remove_node() {
    need_root

    local node="${1:-}"
    local purge=false
    local ssh_target=""

    shift || true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --purge)
                purge=true
                shift
                ;;

            --ssh)
                [[ $# -ge 2 ]] || err "--ssh requires a target"
                ssh_target="$2"
                shift 2
                ;;

            *)
                err "Unknown option: $1"
                ;;
        esac
    done

    [[ -n "$node" ]] ||
        err "Usage: remove-node NODE_NAME [--purge] [--ssh user@host]"

    log "Draining $node ..."

    kctl drain "$node" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --force \
        --timeout=120s || true

    kctl delete node "$node" || true

    log "$node removed from the cluster."

    if $purge && [[ -n "$ssh_target" ]]; then
        log "Uninstalling k3s on $node via SSH ..."

        ssh \
            -o StrictHostKeyChecking=accept-new \
            "$ssh_target" \
            "sudo /usr/local/bin/k3s-uninstall.sh 2>/dev/null || sudo /usr/local/bin/k3s-agent-uninstall.sh 2>/dev/null || true"
    fi
}

# ------------------------------------------------------------------------------------
# Uninstall
# ------------------------------------------------------------------------------------

cmd_uninstall() {
    need_root

    if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
        /usr/local/bin/k3s-uninstall.sh

    elif [[ -x /usr/local/bin/k3s-agent-uninstall.sh ]]; then
        /usr/local/bin/k3s-agent-uninstall.sh

    else
        err "No k3s uninstall script found on this node."
    fi

    rm -rf "$CONFIG_DIR"

    log "k3s uninstalled from this node."
}

# ------------------------------------------------------------------------------------
# Automatic failover
# ------------------------------------------------------------------------------------

usage_watchdog() {
    cat <<'EOF'
Usage:
  k3s-manager.sh watchdog-install --master IP --standby-ssh-key /path/to/key \
      [--check-interval 15] [--fail-threshold 8]

Run on the STANDBY WORKER you want auto-promoted if the master disappears.

Requires passwordless SSH (root or sudo) from this node to the master
for snapshot syncing.
EOF
}

cmd_watchdog_install() {
    need_root

    local master=""
    local key=""
    local interval=15
    local threshold=8

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --master)
                [[ $# -ge 2 ]] || err "--master requires a value"
                master="$2"
                shift 2
                ;;

            --standby-ssh-key)
                [[ $# -ge 2 ]] || err "--standby-ssh-key requires a value"
                key="$2"
                shift 2
                ;;

            --check-interval)
                [[ $# -ge 2 ]] || err "--check-interval requires a value"
                interval="$2"
                shift 2
                ;;

            --fail-threshold)
                [[ $# -ge 2 ]] || err "--fail-threshold requires a value"
                threshold="$2"
                shift 2
                ;;

            *)
                err "Unknown option: $1"
                ;;
        esac
    done

    [[ -n "$master" && -n "$key" ]] ||
        {
            usage_watchdog
            err "Missing --master or --standby-ssh-key"
        }

    mkdir -p "$SNAPSHOT_DIR" "$CONFIG_DIR"

    cat > "$CONFIG_FILE" <<EOF
K3SMGR_ROLE=worker
K3SMGR_MASTER_IP=$master
K3SMGR_SSH_KEY=$key
K3SMGR_FAIL_THRESHOLD=$threshold
EOF

    cat > "$WATCHDOG_SCRIPT" <<'WDEOF'
#!/usr/bin/env bash

set -euo pipefail

CONFIG_FILE="/etc/k3s-manager/config.env"
STATE_FILE="/var/lib/k3s-manager/fail_count"
SNAPSHOT_DIR="/var/lib/k3s-manager/snapshots"

[[ -f "$CONFIG_FILE" ]] || exit 0

. "$CONFIG_FILE"

mkdir -p "$SNAPSHOT_DIR" "$(dirname "$STATE_FILE")"

fail_count=0

[[ -f "$STATE_FILE" ]] &&
    fail_count=$(cat "$STATE_FILE")

if curl -sk --max-time 5 \
    "https://${K3SMGR_MASTER_IP}:6443/healthz" |
    grep -q ok
then
    echo 0 > "$STATE_FILE"

    rsync -az \
        -e "ssh -i ${K3SMGR_SSH_KEY} -o StrictHostKeyChecking=accept-new" \
        "root@${K3SMGR_MASTER_IP}:/var/lib/rancher/k3s/server/db/snapshots/" \
        "$SNAPSHOT_DIR/" 2>/dev/null || true

    exit 0
fi

fail_count=$((fail_count + 1))

echo "$fail_count" > "$STATE_FILE"

logger -t k3s-manager-watchdog \
    "Master ${K3SMGR_MASTER_IP} unreachable (${fail_count}/${K3SMGR_FAIL_THRESHOLD})"

if [[ "$fail_count" -ge "${K3SMGR_FAIL_THRESHOLD}" ]]; then

    logger -t k3s-manager-watchdog \
        "Threshold reached — promoting this node to master using latest snapshot."

    latest="$(ls -t "$SNAPSHOT_DIR" 2>/dev/null | head -n1 || true)"

    systemctl stop k3s-agent 2>/dev/null ||
        rc-service k3s-agent stop 2>/dev/null ||
        true

    if [[ -n "$latest" ]]; then

        curl -sfL https://get.k3s.io |
            INSTALL_K3S_EXEC="server --cluster-reset --cluster-reset-restore-path=${SNAPSHOT_DIR}/${latest}" \
            sh -

    else

        logger -t k3s-manager-watchdog \
            "No snapshot available — starting a fresh single-node master instead."

        curl -sfL https://get.k3s.io |
            INSTALL_K3S_EXEC="server --cluster-init" \
            sh -
    fi

    # Make absolutely sure the directory exists before writing.
    mkdir -p "$(dirname "$CONFIG_FILE")"

    echo "K3SMGR_ROLE=master" > "$CONFIG_FILE"

    systemctl disable k3s-manager-watchdog.timer 2>/dev/null || true

    logger -t k3s-manager-watchdog \
        "Promotion complete. This node is now the master."
fi
WDEOF

    chmod +x "$WATCHDOG_SCRIPT"

    cat > "$SNAPSHOT_SYNC_SERVICE" <<EOF
[Unit]
Description=k3s-manager watchdog check / snapshot sync

[Service]
Type=oneshot
ExecStart=$WATCHDOG_SCRIPT
EOF

    cp "$SNAPSHOT_SYNC_SERVICE" "$WATCHDOG_SERVICE"

    cat > "$WATCHDOG_TIMER" <<EOF
[Unit]
Description=Run k3s-manager watchdog every ${interval}s

[Timer]
OnBootSec=30
OnUnitActiveSec=${interval}s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload

    systemctl enable --now k3s-manager-watchdog.timer

    log "Failover watchdog installed. Checking master every ${interval}s, promoting after ${threshold} consecutive failures (~$((interval * threshold))s)."
}

cmd_watchdog_uninstall() {
    need_root

    systemctl disable --now k3s-manager-watchdog.timer 2>/dev/null || true

    rm -f \
        "$WATCHDOG_TIMER" \
        "$WATCHDOG_SERVICE" \
        "$WATCHDOG_SCRIPT"

    systemctl daemon-reload 2>/dev/null || true

    log "Watchdog removed."
}

cmd_promote() {
    need_root

    [[ -x "$WATCHDOG_SCRIPT" ]] ||
        err "Watchdog script is not installed."

    bash "$WATCHDOG_SCRIPT" || true
}

# ------------------------------------------------------------------------------------
# Rancher GUI
# ------------------------------------------------------------------------------------

cmd_install_rancher() {
    need_root

    [[ -f "$KUBECONFIG_PATH" ]] ||
        err "Run this on a master node (no kubeconfig found here)."

    export KUBECONFIG="$KUBECONFIG_PATH"

    local hostname_arg=""
    local bootstrap_pass=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hostname)
                [[ $# -ge 2 ]] || err "--hostname requires a value"
                hostname_arg="$2"
                shift 2
                ;;

            --password)
                [[ $# -ge 2 ]] || err "--password requires a value"
                bootstrap_pass="$2"
                shift 2
                ;;

            *)
                err "Unknown option: $1"
                ;;
        esac
    done

    [[ -n "$bootstrap_pass" ]] ||
        bootstrap_pass="$(
            head -c16 /dev/urandom |
                base64 |
                tr -dc 'a-zA-Z0-9' |
                head -c16
        )"

    if ! have helm; then
        log "Installing Helm..."

        curl -fsSL \
            https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 |
            bash
    fi

    helm repo add jetstack \
        https://charts.jetstack.io \
        --force-update

    helm repo add rancher-stable \
        https://releases.rancher.com/server-charts/stable \
        --force-update

    helm repo update

    k3s kubectl create namespace cert-manager \
        --dry-run=client \
        -o yaml |
        k3s kubectl apply -f -

    helm upgrade -i cert-manager \
        jetstack/cert-manager \
        -n cert-manager \
        --set installCRDs=true \
        --wait

    k3s kubectl create namespace cattle-system \
        --dry-run=client \
        -o yaml |
        k3s kubectl apply -f -

    local node_ip
    node_ip="$(default_ip)"

    local rancher_host
    rancher_host="${hostname_arg:-${node_ip}.sslip.io}"

    helm upgrade -i rancher \
        rancher-stable/rancher \
        -n cattle-system \
        --set hostname="$rancher_host" \
        --set bootstrapPassword="$bootstrap_pass" \
        --set replicas=1 \
        --wait

    k3s kubectl -n cattle-system patch svc rancher \
        -p '{"spec": {"type": "NodePort"}}' ||
        true

    local nodeport

    nodeport="$(
        k3s kubectl \
            -n cattle-system \
            get svc rancher \
            -o jsonpath='{.spec.ports[0].nodePort}' \
            2>/dev/null ||
            echo '?'
    )"

    log "Rancher installed."

    echo
    echo "Rancher GUI:        https://${rancher_host}"
    echo "Direct node access: https://${node_ip}:${nodeport}"
    echo "Bootstrap password: ${bootstrap_pass}"
    echo

    echo "Note: sslip.io hostnames auto-resolve to the embedded IP,"
    echo "so HTTPS works out of the box with a self-signed cert."
    echo "The browser will warn once."

    echo "For a real domain, pass --hostname yourdomain.com"
    echo "and point DNS at ${node_ip}."
}

cmd_uninstall_rancher() {
    need_root

    export KUBECONFIG="$KUBECONFIG_PATH"

    helm uninstall rancher \
        -n cattle-system \
        2>/dev/null ||
        true

    helm uninstall cert-manager \
        -n cert-manager \
        2>/dev/null ||
        true

    log "Rancher removed."
}

# ------------------------------------------------------------------------------------
# CLI
# ------------------------------------------------------------------------------------

usage() {
    cat <<'EOF'
k3s-manager.sh — cross-distro k3s install & cluster management

  install master [--ha] [--worker] [--token T]
      Install this node as master (optionally HA + workload-schedulable)

  install join-master --server URL --token T [--worker]
      Join as an additional HA master

  install worker --server URL --token T
      Install this node as a worker

  enable-boot / disable-boot
      Toggle k3s starting on boot

  status
      Show node list (master) or service status (worker)

  token
      Print this master's join URL + token

  list-nodes
      List all cluster nodes

  add-node worker|master [--ssh user@host]
      Print or remotely run the join command for a new node

  remove-node NODE_NAME [--purge] [--ssh user@host]
      Drain, delete, and optionally uninstall a node

  watchdog-install --master IP --standby-ssh-key KEY [--check-interval S] [--fail-threshold N]
      Auto-promote THIS worker to master if the master dies

  watchdog-uninstall
      Remove the failover watchdog

  promote
      Manually trigger promotion now

  install-rancher [--hostname host] [--password pass]
      Deploy the Rancher management GUI on this cluster

  uninstall-rancher
      Remove Rancher

  uninstall
      Remove k3s from this node entirely

Examples:

  # Node 1 (first master, HA-ready, also runs workloads)
  sudo ./k3s-manager.sh install master --ha --worker

  # Node 2 & 3 (additional masters, for real 3-node HA)
  sudo ./k3s-manager.sh install join-master \
      --server https://NODE1_IP:6443 \
      --token TOKEN

  # Worker nodes
  sudo ./k3s-manager.sh install worker \
      --server https://NODE1_IP:6443 \
      --token TOKEN

  # On a designated standby worker, enable DR auto-promotion
  sudo ./k3s-manager.sh watchdog-install \
      --master NODE1_IP \
      --standby-ssh-key /root/.ssh/id_rsa

  # Rancher GUI
  sudo ./k3s-manager.sh install-rancher

EOF
}

main() {
    local cmd="${1:-}"

    shift || true

    case "$cmd" in
        install)
            cmd_install "$@"
            ;;

        enable-boot)
            cmd_enable_boot
            ;;

        disable-boot)
            cmd_disable_boot
            ;;

        status)
            cmd_status
            ;;

        token)
            cmd_token
            ;;

        list-nodes)
            cmd_list_nodes
            ;;

        add-node)
            cmd_add_node "$@"
            ;;

        remove-node)
            cmd_remove_node "$@"
            ;;

        watchdog-install)
            cmd_watchdog_install "$@"
            ;;

        watchdog-uninstall)
            cmd_watchdog_uninstall
            ;;

        promote)
            cmd_promote
            ;;

        install-rancher)
            cmd_install_rancher "$@"
            ;;

        uninstall-rancher)
            cmd_uninstall_rancher
            ;;

        uninstall)
            cmd_uninstall
            ;;

        help|--help|-h|"")
            usage
            ;;

        *)
            usage
            err "Unknown command: $cmd"
            ;;
    esac
}

main "$@"
