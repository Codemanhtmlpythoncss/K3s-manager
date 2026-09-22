#!/usr/bin/env bash
#
# k3s-manager
#
# Cross-distro K3s cluster management.
#
# Supports:
#   - Debian / Ubuntu / Raspberry Pi OS
#   - RHEL / CentOS / Rocky / Alma / Fedora
#   - openSUSE / SLES
#   - Arch
#   - Alpine
#
# Features:
#   - Single master
#   - HA masters with embedded etcd
#   - Workers
#   - Explicit network-interface selection
#   - en0 / eth0 join information
#   - Node management
#   - Automatic failover watchdog
#   - Rancher installation
#   - Boot management
#
# Example:
#   sudo k3s-manager install master --interface eth0 --worker
#
#   sudo k3s-manager install worker \
#       --server https://192.168.1.123:6443 \
#       --token TOKEN \
#       --interface eth0
#

set -euo pipefail
IFS=$'\n\t'

# ==============================================================================
# PATHS
# ==============================================================================

CONFIG_DIR="/etc/k3s-manager"
CONFIG_FILE="${CONFIG_DIR}/config.env"

LOG_FILE="/var/log/k3s-manager.log"

SNAPSHOT_DIR="/var/lib/k3s-manager/snapshots"

KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"

WATCHDOG_SCRIPT="/usr/local/bin/k3s-manager-watchdog.sh"
WATCHDOG_SERVICE="/etc/systemd/system/k3s-manager-watchdog.service"
WATCHDOG_TIMER="/etc/systemd/system/k3s-manager-watchdog.timer"

# ==============================================================================
# LOGGING / HELPERS
# ==============================================================================

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
    [[ $EUID -eq 0 ]] ||
        err "This command must be run as root. Use sudo."
}

ensure_config_dir() {
    mkdir -p "$CONFIG_DIR"
}

# ==============================================================================
# CONFIGURATION
# ==============================================================================

save_config() {
    ensure_config_dir

    cat > "${CONFIG_FILE}.tmp" <<EOF
K3SMGR_ROLE=${K3SMGR_ROLE:-}
K3SMGR_INTERFACE=${K3SMGR_INTERFACE:-}
K3SMGR_NODE_IP=${K3SMGR_NODE_IP:-}
K3SMGR_SERVER_URL=${K3SMGR_SERVER_URL:-}
EOF

    mv -f "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        . "$CONFIG_FILE"
    fi
}

write_role_config() {
    local role="$1"
    local interface="${2:-}"
    local node_ip="${3:-}"
    local server_url="${4:-}"

    ensure_config_dir

    cat > "${CONFIG_FILE}.tmp" <<EOF
K3SMGR_ROLE=${role}
K3SMGR_INTERFACE=${interface}
K3SMGR_NODE_IP=${node_ip}
K3SMGR_SERVER_URL=${server_url}
EOF

    chmod 600 "${CONFIG_FILE}.tmp"
    mv -f "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

# ==============================================================================
# OS DETECTION
# ==============================================================================

detect_os() {
    [[ -f /etc/os-release ]] ||
        err "/etc/os-release does not exist."

    # shellcheck disable=SC1091
    . /etc/os-release

    OS_ID="${ID,,}"

    # ID_LIKE is optional.
    OS_LIKE="${ID_LIKE:-}"
    OS_LIKE="${OS_LIKE,,}"

    if have apt-get; then
        PKG="apt"
    elif have dnf; then
        PKG="dnf"
    elif have yum; then
        PKG="yum"
    elif have zypper; then
        PKG="zypper"
    elif have pacman; then
        PKG="pacman"
    elif have apk; then
        PKG="apk"
    else
        err "No supported package manager found."
    fi

    if have systemctl && systemctl --version >/dev/null 2>&1; then
        INIT="systemd"
    elif have rc-service; then
        INIT="openrc"
    else
        err "K3s requires systemd or OpenRC."
    fi

    log "Detected distro=${OS_ID} package-manager=${PKG} init=${INIT}"
}

# ==============================================================================
# NETWORKING
# ==============================================================================

interface_exists() {
    ip link show "$1" >/dev/null 2>&1
}

interface_ipv4() {
    local iface="$1"

    ip -4 addr show dev "$iface" 2>/dev/null |
        awk '/inet / {
            split($2,a,"/");
            print a[1];
            exit
        }'
}

default_ip() {
    ip -4 route get 1.1.1.1 2>/dev/null |
        awk '{
            for(i=1;i<=NF;i++)
                if($i=="src")
                    print $(i+1)
        }' |
        head -n1
}

get_interface_ip() {
    local iface="$1"
    local ipaddr

    ipaddr="$(interface_ipv4 "$iface" || true)"

    [[ -n "$ipaddr" ]] ||
        err "Interface '$iface' has no IPv4 address."

    echo "$ipaddr"
}

get_best_ip() {
    local ipaddr

    ipaddr="$(default_ip || true)"

    if [[ -n "$ipaddr" ]]; then
        echo "$ipaddr"
        return
    fi

    hostname -I 2>/dev/null |
        awk '{print $1}'
}

network_info() {
    echo "=== NETWORK INTERFACES ==="
    echo

    printf "%-12s %-18s %-10s\n" "INTERFACE" "IPv4" "STATE"
    printf "%-12s %-18s %-10s\n" "---------" "----" "-----"

    local iface
    for iface in en0 eth0 wlan0 wlan1; do
        if interface_exists "$iface"; then
            local ipaddr
            local state

            ipaddr="$(interface_ipv4 "$iface" || true)"
            state="$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo unknown)"

            printf "%-12s %-18s %-10s\n" \
                "$iface" \
                "${ipaddr:-none}" \
                "$state"
        fi
    done

    echo
    echo "=== DEFAULT ROUTE ==="
    ip -4 route show default 2>/dev/null || true

    echo
    echo "=== ROUTED IP ==="
    echo "$(get_best_ip)"
}

# ==============================================================================
# K3S NETWORK ARGUMENTS
# ==============================================================================

build_network_args() {
    local iface="${1:-}"

    NETWORK_ARGS=()

    if [[ -n "$iface" ]]; then
        interface_exists "$iface" ||
            err "Network interface '$iface' does not exist."

        local ipaddr
        ipaddr="$(get_interface_ip "$iface")"

        NETWORK_ARGS+=(
            "--node-ip"
            "$ipaddr"
            "--advertise-address"
            "$ipaddr"
            "--flannel-iface"
            "$iface"
        )

        log "K3s network interface: $iface"
        log "K3s node IP: $ipaddr"
    fi
}

# ==============================================================================
# PREREQUISITES
# ==============================================================================

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
                conntrack
            ;;

        dnf)
            dnf install -y \
                curl \
                iscsi-initiator-utils \
                nfs-utils \
                socat \
                conntrack-tools

            systemctl enable --now iscsid 2>/dev/null || true
            ;;

        yum)
            yum install -y \
                curl \
                iscsi-initiator-utils \
                nfs-utils \
                socat \
                conntrack-tools

            systemctl enable --now iscsid 2>/dev/null || true
            ;;

        zypper)
            zypper --non-interactive install \
                curl \
                open-iscsi \
                nfs-client \
                socat \
                conntrack-tools

            systemctl enable --now iscsid 2>/dev/null || true
            ;;

        pacman)
            pacman -Sy --noconfirm \
                curl \
                open-iscsi \
                nfs-utils \
                socat \
                conntrack-tools

            systemctl enable --now iscsid 2>/dev/null || true
            ;;

        apk)
            apk add --no-cache \
                curl \
                open-iscsi \
                nfs-utils \
                socat \
                conntrack-tools

            rc-update add iscsid default 2>/dev/null || true
            rc-service iscsid start 2>/dev/null || true
            ;;

    esac
}

# ==============================================================================
# KUBECTL
# ==============================================================================

kctl() {
    [[ -f "$KUBECONFIG_PATH" ]] ||
        err "No kubeconfig found at $KUBECONFIG_PATH."

    KUBECONFIG="$KUBECONFIG_PATH" k3s kubectl "$@"
}

# ==============================================================================
# INSTALL
# ==============================================================================

usage_install() {
    cat <<'EOF'

INSTALL COMMANDS

Master:

  k3s-manager install master [OPTIONS]

Options:

  --ha
      Enable embedded-etcd cluster initialization.

  --worker
      Allow workloads to run on this master.

  --interface eth0
      Force K3s to use eth0 for node networking.

  --token TOKEN
      Use a specific cluster token.

Worker:

  k3s-manager install worker \
      --server https://MASTER:6443 \
      --token TOKEN \
      [--interface eth0]

Additional HA master:

  k3s-manager install join-master \
      --server https://MASTER:6443 \
      --token TOKEN \
      [--interface eth0]

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
    local iface=""

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

            --interface)
                [[ $# -ge 2 ]] ||
                    err "--interface requires an interface name."

                iface="$2"
                shift 2
                ;;

            --server)
                [[ $# -ge 2 ]] ||
                    err "--server requires a URL."

                server="$2"
                shift 2
                ;;

            --token)
                [[ $# -ge 2 ]] ||
                    err "--token requires a token."

                token="$2"
                shift 2
                ;;

            *)
                err "Unknown option: $1"
                ;;

        esac

    done

    if [[ -n "$iface" ]]; then
        interface_exists "$iface" ||
            err "Interface '$iface' does not exist."

        get_interface_ip "$iface" >/dev/null
    fi

    build_network_args "$iface"

    case "$subrole" in

        master)

            local -a exec_args
            exec_args=("server")

            if $ha; then
                exec_args+=("--cluster-init")
            fi

            if [[ -n "$token" ]]; then
                exec_args+=("--token" "$token")
            fi

            if [[ ${#NETWORK_ARGS[@]} -gt 0 ]]; then
                exec_args+=("${NETWORK_ARGS[@]}")
            fi

            log "Installing K3s master..."

            curl -sfL https://get.k3s.io |
                INSTALL_K3S_EXEC="${exec_args[*]}" sh -

            local master_ip
            if [[ -n "$iface" ]]; then
                master_ip="$(get_interface_ip "$iface")"
            else
                master_ip="$(get_best_ip)"
            fi

            write_role_config \
                "master" \
                "$iface" \
                "$master_ip" \
                "https://${master_ip}:6443"

            if $worker; then
                untaint_self
            fi

            if [[ "$INIT" == "systemd" ]]; then
                systemctl enable k3s
            else
                rc-update add k3s default 2>/dev/null || true
            fi

            log "Master installed successfully."
            log "Master IP: ${master_ip}"
            log "K3s API: https://${master_ip}:6443"

            ;;

        join-master)

            [[ -n "$server" ]] ||
                err "join-master requires --server."

            [[ -n "$token" ]] ||
                err "join-master requires --token."

            local -a join_args
            join_args=("server" "--server" "$server" "--token" "$token")

            if [[ ${#NETWORK_ARGS[@]} -gt 0 ]]; then
                join_args+=("${NETWORK_ARGS[@]}")
            fi

            log "Joining HA master to ${server}..."

            curl -sfL https://get.k3s.io |
                INSTALL_K3S_EXEC="${join_args[*]}" sh -

            local node_ip
            if [[ -n "$iface" ]]; then
                node_ip="$(get_interface_ip "$iface")"
            else
                node_ip="$(get_best_ip)"
            fi

            write_role_config \
                "master" \
                "$iface" \
                "$node_ip" \
                "$server"

            if $worker; then
                untaint_self
            fi

            if [[ "$INIT" == "systemd" ]]; then
                systemctl enable k3s
            else
                rc-update add k3s default 2>/dev/null || true
            fi

            log "HA master joined successfully."

            ;;

        worker)

            [[ -n "$server" ]] ||
                err "worker requires --server."

            [[ -n "$token" ]] ||
                err "worker requires --token."

            local -a worker_args
            worker_args=("agent")

            if [[ ${#NETWORK_ARGS[@]} -gt 0 ]]; then
                worker_args+=("${NETWORK_ARGS[@]}")
            fi

            log "Installing K3s worker..."

            curl -sfL https://get.k3s.io |
                K3S_URL="$server" \
                K3S_TOKEN="$token" \
                INSTALL_K3S_EXEC="${worker_args[*]}" \
                sh -

            local worker_ip
            if [[ -n "$iface" ]]; then
                worker_ip="$(get_interface_ip "$iface")"
            else
                worker_ip="$(get_best_ip)"
            fi

            write_role_config \
                "worker" \
                "$iface" \
                "$worker_ip" \
                "$server"

            if [[ "$INIT" == "systemd" ]]; then
                systemctl enable k3s-agent
            else
                rc-update add k3s-agent default 2>/dev/null || true
            fi

            log "Worker joined successfully."

            ;;

        *)
            usage_install
            err "Specify master, join-master, or worker."

            ;;

    esac
}

# ==============================================================================
# MASTER WORKLOADS
# ==============================================================================

untaint_self() {
    local node

    node="$(hostname)"

    sleep 5

    KUBECONFIG="$KUBECONFIG_PATH" \
        k3s kubectl taint nodes "$node" \
        node-role.kubernetes.io/master- \
        node-role.kubernetes.io/control-plane- \
        --overwrite 2>/dev/null || true

    log "Removed scheduling taints from ${node}."
}

# ==============================================================================
# JOIN INFORMATION
# ==============================================================================

cmd_token() {
    need_root

    [[ -f /var/lib/rancher/k3s/server/node-token ]] ||
        err "No K3s server token found."

    local token
    token="$(cat /var/lib/rancher/k3s/server/node-token)"

    echo
    echo "=============================================="
    echo "             K3S JOIN INFORMATION"
    echo "=============================================="
    echo

    local iface
    local ipaddr

    for iface in en0 eth0 wlan0 wlan1; do

        if interface_exists "$iface"; then

            ipaddr="$(interface_ipv4 "$iface" || true)"

            if [[ -n "$ipaddr" ]]; then
                echo "$iface:"
                echo "  Server URL: https://${ipaddr}:6443"
                echo
            fi

        fi

    done

    echo "Token:"
    echo "  ${token}"
    echo

    echo "----------------------------------------------"
    echo "WORKER JOIN"
    echo "----------------------------------------------"
    echo
    echo "sudo k3s-manager install worker \\"
    echo "  --server https://<MASTER-IP>:6443 \\"
    echo "  --token <TOKEN> \\"
    echo "  --interface eth0"
    echo

    echo "----------------------------------------------"
    echo "HA MASTER JOIN"
    echo "----------------------------------------------"
    echo
    echo "sudo k3s-manager install join-master \\"
    echo "  --server https://<MASTER-IP>:6443 \\"
    echo "  --token <TOKEN> \\"
    echo "  --interface eth0"
    echo
}

# ==============================================================================
# NETWORK INFO
# ==============================================================================

cmd_network_info() {
    network_info
}

# ==============================================================================
# BOOT
# ==============================================================================

cmd_enable_boot() {
    need_root
    detect_os
    load_config

    local service="k3s"

    [[ "${K3SMGR_ROLE:-}" == "worker" ]] &&
        service="k3s-agent"

    if [[ "$INIT" == "systemd" ]]; then
        systemctl enable "$service"
        log "${service} enabled at boot."
    else
        rc-update add "$service" default 2>/dev/null || true
        log "${service} enabled at boot."
    fi
}

cmd_disable_boot() {
    need_root
    detect_os
    load_config

    local service="k3s"

    [[ "${K3SMGR_ROLE:-}" == "worker" ]] &&
        service="k3s-agent"

    if [[ "$INIT" == "systemd" ]]; then
        systemctl disable "$service"
        log "${service} disabled at boot."
    else
        rc-update del "$service" default 2>/dev/null || true
        log "${service} disabled at boot."
    fi
}

# ==============================================================================
# STATUS
# ==============================================================================

cmd_status() {
    detect_os
    load_config

    echo
    echo "=============================================="
    echo "               K3S STATUS"
    echo "=============================================="
    echo

    echo "Role:       ${K3SMGR_ROLE:-unknown}"
    echo "Interface:  ${K3SMGR_INTERFACE:-automatic}"
    echo "Node IP:    ${K3SMGR_NODE_IP:-unknown}"
    echo

    if [[ -f "$KUBECONFIG_PATH" ]]; then

        echo "=== CLUSTER NODES ==="
        kctl get nodes -o wide || true

        echo
        echo "=== K3S SERVICE ==="

        if [[ "$INIT" == "systemd" ]]; then
            systemctl status k3s --no-pager || true
        else
            rc-service k3s status || true
        fi

    else

        echo "=== WORKER SERVICE ==="

        if [[ "$INIT" == "systemd" ]]; then
            systemctl status k3s-agent --no-pager || true
        else
            rc-service k3s-agent status || true
        fi

    fi
}

# ==============================================================================
# LIST NODES
# ==============================================================================

cmd_list_nodes() {
    kctl get nodes -o wide
}

# ==============================================================================
# ADD NODE
# ==============================================================================

cmd_add_node() {
    need_root

    local kind="${1:-}"
    shift || true

    local ssh_target=""
    local iface="eth0"

    while [[ $# -gt 0 ]]; do

        case "$1" in

            --ssh)
                [[ $# -ge 2 ]] ||
                    err "--ssh requires a target."

                ssh_target="$2"
                shift 2
                ;;

            --interface)
                [[ $# -ge 2 ]] ||
                    err "--interface requires an interface."

                iface="$2"
                shift 2
                ;;

            *)
                err "Unknown option: $1"
                ;;

        esac

    done

    [[ -f /var/lib/rancher/k3s/server/node-token ]] ||
        err "This command must be run on a master."

    local master_ip

    master_ip="$(get_best_ip)"

    local token

    token="$(cat /var/lib/rancher/k3s/server/node-token)"

    local server="https://${master_ip}:6443"

    case "$kind" in

        worker)

            local cmd

            cmd="sudo k3s-manager install worker --server ${server} --token '${token}' --interface ${iface}"

            ;;

        master)

            cmd="sudo k3s-manager install join-master --server ${server} --token '${token}' --interface ${iface}"

            ;;

        *)

            err "Specify worker or master."

            ;;

    esac

    if [[ -n "$ssh_target" ]]; then

        log "Running remote installation on ${ssh_target}..."

        ssh \
            -o StrictHostKeyChecking=accept-new \
            "$ssh_target" \
            "$cmd"

    else

        echo
        echo "$cmd"
        echo

    fi
}

# ==============================================================================
# REMOVE NODE
# ==============================================================================

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
                [[ $# -ge 2 ]] ||
                    err "--ssh requires a target."

                ssh_target="$2"
                shift 2
                ;;

            *)
                err "Unknown option: $1"
                ;;

        esac

    done

    [[ -n "$node" ]] ||
        err "Usage: remove-node NODE [--purge] [--ssh user@host]"

    log "Draining ${node}..."

    kctl drain "$node" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --force \
        --timeout=120s || true

    kctl delete node "$node" || true

    log "${node} removed from cluster."

    if $purge && [[ -n "$ssh_target" ]]; then

        ssh \
            -o StrictHostKeyChecking=accept-new \
            "$ssh_target" \
            "sudo /usr/local/bin/k3s-uninstall.sh 2>/dev/null || sudo /usr/local/bin/k3s-agent-uninstall.sh 2>/dev/null || true"

    fi
}

# ==============================================================================
# WATCHDOG
# ==============================================================================

cmd_watchdog_install() {
    need_root

    local master=""
    local key=""
    local interval=15
    local threshold=8

    while [[ $# -gt 0 ]]; do

        case "$1" in

            --master)
                master="$2"
                shift 2
                ;;

            --standby-ssh-key)
                key="$2"
                shift 2
                ;;

            --check-interval)
                interval="$2"
                shift 2
                ;;

            --fail-threshold)
                threshold="$2"
                shift 2
                ;;

            *)
                err "Unknown option: $1"
                ;;

        esac

    done

    [[ -n "$master" ]] ||
        err "--master is required."

    [[ -n "$key" ]] ||
        err "--standby-ssh-key is required."

    mkdir -p "$SNAPSHOT_DIR" "$CONFIG_DIR"

    cat > "$CONFIG_FILE" <<EOF
K3SMGR_ROLE=worker
K3SMGR_MASTER_IP=${master}
K3SMGR_SSH_KEY=${key}
K3SMGR_FAIL_THRESHOLD=${threshold}
EOF

    chmod 600 "$CONFIG_FILE"

    cat > "$WATCHDOG_SCRIPT" <<'EOF'
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
    fail_count="$(cat "$STATE_FILE")"

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
        "Promoting this node to master."

    latest="$(ls -t "$SNAPSHOT_DIR" 2>/dev/null | head -n1 || true)"

    systemctl stop k3s-agent 2>/dev/null || true

    if [[ -n "$latest" ]]; then

        curl -sfL https://get.k3s.io |
            INSTALL_K3S_EXEC="server --cluster-reset --cluster-reset-restore-path=${SNAPSHOT_DIR}/${latest}" \
            sh -

    else

        curl -sfL https://get.k3s.io |
            INSTALL_K3S_EXEC="server --cluster-init" \
            sh -

    fi

    mkdir -p "$(dirname "$CONFIG_FILE")"

    cat > "$CONFIG_FILE" <<EOF
K3SMGR_ROLE=master
K3SMGR_NODE_IP=$(hostname -I | awk '{print $1}')
EOF

    systemctl disable --now k3s-manager-watchdog.timer 2>/dev/null || true

    logger -t k3s-manager-watchdog \
        "Promotion completed."

fi
EOF

    chmod +x "$WATCHDOG_SCRIPT"

    cat > "$WATCHDOG_SERVICE" <<EOF
[Unit]
Description=K3s Manager Watchdog

[Service]
Type=oneshot
ExecStart=${WATCHDOG_SCRIPT}
EOF

    cat > "$WATCHDOG_TIMER" <<EOF
[Unit]
Description=K3s Manager Watchdog Timer

[Timer]
OnBootSec=30
OnUnitActiveSec=${interval}s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload

    systemctl enable --now k3s-manager-watchdog.timer

    log "Watchdog installed."
    log "Check interval: ${interval}s"
    log "Fail threshold: ${threshold}"
}

cmd_watchdog_uninstall() {
    need_root

    systemctl disable --now k3s-manager-watchdog.timer 2>/dev/null || true

    rm -f \
        "$WATCHDOG_TIMER" \
        "$WATCHDOG_SERVICE" \
        "$WATCHDOG_SCRIPT"

    systemctl daemon-reload

    log "Watchdog removed."
}

cmd_promote() {
    need_root

    [[ -x "$WATCHDOG_SCRIPT" ]] ||
        err "Watchdog is not installed."

    "$WATCHDOG_SCRIPT"
}

# ==============================================================================
# RANCHER
# ==============================================================================

cmd_install_rancher() {
    need_root

    [[ -f "$KUBECONFIG_PATH" ]] ||
        err "This must be run on a master."

    export KUBECONFIG="$KUBECONFIG_PATH"

    local hostname_arg=""
    local bootstrap_pass=""

    while [[ $# -gt 0 ]]; do

        case "$1" in

            --hostname)
                hostname_arg="$2"
                shift 2
                ;;

            --password)
                bootstrap_pass="$2"
                shift 2
                ;;

            *)
                err "Unknown option: $1"
                ;;

        esac

    done

    if ! have helm; then

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
    node_ip="$(get_best_ip)"

    local rancher_host
    rancher_host="${hostname_arg:-${node_ip}.sslip.io}"

    [[ -n "$bootstrap_pass" ]] ||
        bootstrap_pass="$(
            head -c32 /dev/urandom |
                base64 |
                tr -dc 'a-zA-Z0-9' |
                head -c20
        )"

    helm upgrade -i rancher \
        rancher-stable/rancher \
        -n cattle-system \
        --set hostname="$rancher_host" \
        --set bootstrapPassword="$bootstrap_pass" \
        --set replicas=1 \
        --wait

    k3s kubectl \
        -n cattle-system \
        patch svc rancher \
        -p '{"spec":{"type":"NodePort"}}' \
        || true

    local nodeport

    nodeport="$(
        k3s kubectl \
            -n cattle-system \
            get svc rancher \
            -o jsonpath='{.spec.ports[0].nodePort}' \
            2>/dev/null ||
            echo "?"
    )"

    echo
    echo "Rancher GUI:"
    echo "https://${rancher_host}"
    echo
    echo "Direct NodePort:"
    echo "https://${node_ip}:${nodeport}"
    echo
    echo "Bootstrap password:"
    echo "${bootstrap_pass}"
    echo
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

# ==============================================================================
# UNINSTALL
# ==============================================================================

cmd_uninstall() {
    need_root

    if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then

        /usr/local/bin/k3s-uninstall.sh

    elif [[ -x /usr/local/bin/k3s-agent-uninstall.sh ]]; then

        /usr/local/bin/k3s-agent-uninstall.sh

    else

        err "No K3s uninstall script found."

    fi

    rm -rf "$CONFIG_DIR"

    log "K3s removed."
}

# ==============================================================================
# HELP
# ==============================================================================

usage() {
    cat <<'EOF'

===========================================================
                    K3S MANAGER
===========================================================

INSTALLATION

First master:

  sudo k3s-manager install master --ha --interface eth0

Master + workloads:

  sudo k3s-manager install master --ha --worker --interface eth0


WORKER

  sudo k3s-manager install worker \
      --server https://MASTER_IP:6443 \
      --token TOKEN \
      --interface eth0


ADDITIONAL HA MASTER

  sudo k3s-manager install join-master \
      --server https://MASTER_IP:6443 \
      --token TOKEN \
      --interface eth0


INFORMATION

  sudo k3s-manager token

  sudo k3s-manager network-info

  sudo k3s-manager status

  sudo k3s-manager list-nodes


NODE MANAGEMENT

  sudo k3s-manager add-node worker

  sudo k3s-manager add-node master

  sudo k3s-manager remove-node NODE


BOOT

  sudo k3s-manager enable-boot

  sudo k3s-manager disable-boot


FAILOVER

  sudo k3s-manager watchdog-install \
      --master MASTER_IP \
      --standby-ssh-key /root/.ssh/id_rsa

  sudo k3s-manager watchdog-uninstall

  sudo k3s-manager promote


RANCHER

  sudo k3s-manager install-rancher

  sudo k3s-manager uninstall-rancher


UNINSTALL

  sudo k3s-manager uninstall


NETWORKING

Use --interface eth0 to force K3s to use eth0.

For example:

  sudo k3s-manager install master \
      --ha \
      --worker \
      --interface eth0


===========================================================

EOF
}

# ==============================================================================
# MAIN
# ==============================================================================

main() {

    local cmd="${1:-}"

    shift || true

    case "$cmd" in

        install)
            cmd_install "$@"
            ;;

        token)
            cmd_token
            ;;

        network-info)
            cmd_network_info
            ;;

        status)
            cmd_status
            ;;

        list-nodes)
            cmd_list_nodes
            ;;

        enable-boot)
            cmd_enable_boot
            ;;

        disable-boot)
            cmd_disable_boot
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
            err "Unknown command: ${cmd}"
            ;;

    esac
}

main "$@"
