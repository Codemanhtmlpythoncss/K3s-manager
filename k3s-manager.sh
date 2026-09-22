#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="2.0.0"
CONFIG_DIR="/etc/k3s-manager"
CONFIG_FILE="${CONFIG_DIR}/config.env"
LOG_FILE="/var/log/k3s-manager.log"
K3S_TOKEN_FILE="/var/lib/rancher/k3s/server/node-token"
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"

log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

need_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this command with sudo."
}

have() {
    command -v "$1" >/dev/null 2>&1
}

ensure_config_dir() {
    install -d -m 0755 "$CONFIG_DIR"
}

load_os() {
    [[ -r /etc/os-release ]] || die "/etc/os-release not found."
    # shellcheck disable=SC1091
    . /etc/os-release

    OS_ID="${ID:-unknown}"
    OS_ID_LIKE="${ID_LIKE:-}"

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
        die "Unsupported package manager."
    fi

    if have systemctl && systemctl --version >/dev/null 2>&1; then
        INIT="systemd"
    elif have rc-service; then
        INIT="openrc"
    else
        die "K3s requires systemd or OpenRC."
    fi
}

save_config() {
    ensure_config_dir
    local role="${1:-}" iface="${2:-}" ip="${3:-}" server="${4:-}"

    umask 077
    cat > "${CONFIG_FILE}.tmp" <<CFG
K3SMGR_ROLE=$(printf '%q' "$role")
K3SMGR_INTERFACE=$(printf '%q' "$iface")
K3SMGR_NODE_IP=$(printf '%q' "$ip")
K3SMGR_SERVER_URL=$(printf '%q' "$server")
CFG

    chmod 600 "${CONFIG_FILE}.tmp"
    mv -f "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        . "$CONFIG_FILE"
    fi
}

iface_exists() {
    ip link show dev "$1" >/dev/null 2>&1
}

iface_ip() {
    ip -4 -o addr show dev "$1" scope global 2>/dev/null |
        awk 'NR==1 {split($4,a,"/"); print a[1]}'
}

best_ip() {
    local value
    value="$(ip -4 route get 1.1.1.1 2>/dev/null |
        awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"

    if [[ -n "$value" ]]; then
        printf '%s\n' "$value"
        return 0
    fi

    hostname -I 2>/dev/null | awk '{print $1}'
}

network_info() {
    echo "=== K3S NETWORK INFORMATION ==="
    printf '%-10s %-18s %-10s\n' "INTERFACE" "IPV4" "STATE"

    local found=0
    local iface state ipaddr

    for iface in en0 eth0 wlan0 wlan1; do
        if iface_exists "$iface"; then
            found=1
            ipaddr="$(iface_ip "$iface" || true)"
            state="$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo unknown)"
            printf '%-10s %-18s %-10s\n' \
                "$iface" \
                "${ipaddr:-none}" \
                "$state"
        fi
    done

    if [[ "$found" -eq 0 ]]; then
        ip -br addr
    fi

    echo
    echo "=== DEFAULT ROUTE ==="
    ip -4 route show default 2>/dev/null || true

    echo
    echo "=== DEFAULT ROUTED IP ==="
    echo "$(best_ip)"
}

validate_interface() {
    local iface="$1"

    [[ -n "$iface" ]] || return 0

    iface_exists "$iface" ||
        die "Network interface '$iface' does not exist."

    local ipaddr
    ipaddr="$(iface_ip "$iface" || true)"

    [[ -n "$ipaddr" ]] ||
        die "Network interface '$iface' has no global IPv4 address."

    printf '%s\n' "$ipaddr"
}

build_network_args() {
    local iface="${1:-}"
    NETWORK_ARGS=()

    if [[ -n "$iface" ]]; then
        local ipaddr
        ipaddr="$(validate_interface "$iface")"

        NETWORK_ARGS=(
            "--node-ip" "$ipaddr"
            "--advertise-address" "$ipaddr"
            "--flannel-iface" "$iface"
        )
    fi
}

install_prereqs() {
    need_root
    load_os

    log "Detected distro=${OS_ID} package-manager=${PKG} init=${INIT}"
    log "Installing prerequisites..."

    case "$PKG" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y \
                curl \
                ca-certificates \
                open-iscsi \
                nfs-common \
                apparmor \
                apparmor-utils \
                conntrack \
                socat
            ;;
        dnf)
            dnf install -y curl ca-certificates nfs-utils socat conntrack-tools
            if have iscsiadm; then
                systemctl enable --now iscsid 2>/dev/null || true
            fi
            ;;
        yum)
            yum install -y curl ca-certificates nfs-utils socat conntrack-tools
            if have iscsiadm; then
                systemctl enable --now iscsid 2>/dev/null || true
            fi
            ;;
        zypper)
            zypper --non-interactive install curl ca-certificates nfs-client socat conntrack-tools
            ;;
        pacman)
            pacman -Sy --noconfirm curl ca-certificates nfs-utils socat conntrack-tools
            ;;
        apk)
            apk add --no-cache curl ca-certificates nfs-utils socat conntrack-tools
            ;;
    esac
}

kctl() {
    [[ -x /usr/local/bin/k3s ]] || die "K3s is not installed."
    [[ -f "$KUBECONFIG_PATH" ]] || die "Kubeconfig not found: $KUBECONFIG_PATH"
    KUBECONFIG="$KUBECONFIG_PATH" /usr/local/bin/k3s kubectl "$@"
}

wait_for_k3s() {
    local tries=0
    local max_tries=60

    while (( tries < max_tries )); do
        if systemctl is-active --quiet k3s 2>/dev/null; then
            return 0
        fi
        sleep 2
        tries=$((tries + 1))
    done

    return 1
}

install_server() {
    need_root

    local cluster_init=0
    local allow_workloads=0
    local token=""
    local iface=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ha|--cluster-init)
                cluster_init=1
                shift
                ;;
            --worker|--allow-workloads)
                allow_workloads=1
                shift
                ;;
            --token)
                [[ $# -ge 2 ]] || die "--token requires a value."
                token="$2"
                shift 2
                ;;
            --interface)
                [[ $# -ge 2 ]] || die "--interface requires a value."
                iface="$2"
                shift 2
                ;;
            --)
                shift
                break
                ;;
            *)
                die "Unknown master option: $1"
                ;;
        esac
    done

    install_prereqs
    build_network_args "$iface"

    local -a args
    args=("server")

    if [[ "$cluster_init" -eq 1 ]]; then
        args+=("--cluster-init")
    fi

    if [[ -n "$token" ]]; then
        args+=("--token" "$token")
    fi

    if [[ "${#NETWORK_ARGS[@]}" -gt 0 ]]; then
        args+=("${NETWORK_ARGS[@]}")
    fi

    log "Installing K3s server..."

    if [[ -x /usr/local/bin/k3s ]]; then
        log "K3s binary already exists; using installer for service reconciliation."
    fi

    local exec_string=""
    local arg
    for arg in "${args[@]}"; do
        exec_string+=" $(printf '%q' "$arg")"
    done
    exec_string="${exec_string# }"

    curl -sfL https://get.k3s.io |
        INSTALL_K3S_EXEC="$exec_string" \
        K3S_TOKEN="${token}" \
        sh -

    if [[ "$INIT" == "systemd" ]]; then
        systemctl enable k3s
        systemctl restart k3s
    fi

    local node_ip
    if [[ -n "$iface" ]]; then
        node_ip="$(validate_interface "$iface")"
    else
        node_ip="$(best_ip)"
    fi

    [[ -n "$node_ip" ]] || die "Could not determine the server IPv4 address."

    local server_url="https://${node_ip}:6443"
    save_config "master" "$iface" "$node_ip" "$server_url"

    if [[ "$allow_workloads" -eq 1 ]]; then
        sleep 5
        local node
        node="$(hostname)"
        kctl taint nodes "$node" \
            node-role.kubernetes.io/control-plane:NoSchedule- \
            node-role.kubernetes.io/master:NoSchedule- \
            2>/dev/null || true
    fi

    log "K3s master installed."
    log "Primary API URL: ${server_url}"
    log "Run 'sudo k3s-manager token' to get join information."
}

install_worker() {
    need_root

    local server=""
    local token=""
    local iface=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --server)
                [[ $# -ge 2 ]] || die "--server requires a URL."
                server="$2"
                shift 2
                ;;
            --token)
                [[ $# -ge 2 ]] || die "--token requires a value."
                token="$2"
                shift 2
                ;;
            --interface)
                [[ $# -ge 2 ]] || die "--interface requires an interface."
                iface="$2"
                shift 2
                ;;
            *)
                die "Unknown worker option: $1"
                ;;
        esac
    done

    [[ -n "$server" ]] || die "worker requires --server."
    [[ -n "$token" ]] || die "worker requires --token."

    install_prereqs
    build_network_args "$iface"

    local -a args
    args=("agent")

    if [[ "${#NETWORK_ARGS[@]}" -gt 0 ]]; then
        args+=("${NETWORK_ARGS[@]}")
    fi

    local exec_string=""
    local arg
    for arg in "${args[@]}"; do
        exec_string+=" $(printf '%q' "$arg")"
    done
    exec_string="${exec_string# }"

    log "Joining worker to ${server}..."

    curl -sfL https://get.k3s.io |
        K3S_URL="$server" \
        K3S_TOKEN="$token" \
        INSTALL_K3S_EXEC="$exec_string" \
        sh -

    if [[ "$INIT" == "systemd" ]]; then
        systemctl enable k3s-agent
        systemctl restart k3s-agent
    fi

    local node_ip
    if [[ -n "$iface" ]]; then
        node_ip="$(validate_interface "$iface")"
    else
        node_ip="$(best_ip)"
    fi

    save_config "worker" "$iface" "$node_ip" "$server"
    log "Worker installed successfully."
}

install_join_master() {
    need_root

    local server=""
    local token=""
    local iface=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --server)
                [[ $# -ge 2 ]] || die "--server requires a URL."
                server="$2"
                shift 2
                ;;
            --token)
                [[ $# -ge 2 ]] || die "--token requires a value."
                token="$2"
                shift 2
                ;;
            --interface)
                [[ $# -ge 2 ]] || die "--interface requires an interface."
                iface="$2"
                shift 2
                ;;
            *)
                die "Unknown join-master option: $1"
                ;;
        esac
    done

    [[ -n "$server" ]] || die "join-master requires --server."
    [[ -n "$token" ]] || die "join-master requires --token."

    install_prereqs
    build_network_args "$iface"

    local -a args
    args=("server" "--server" "$server" "--token" "$token")

    if [[ "${#NETWORK_ARGS[@]}" -gt 0 ]]; then
        args+=("${NETWORK_ARGS[@]}")
    fi

    local exec_string=""
    local arg
    for arg in "${args[@]}"; do
        exec_string+=" $(printf '%q' "$arg")"
    done
    exec_string="${exec_string# }"

    log "Joining HA server to ${server}..."

    curl -sfL https://get.k3s.io |
        INSTALL_K3S_EXEC="$exec_string" \
        K3S_TOKEN="$token" \
        sh -

    if [[ "$INIT" == "systemd" ]]; then
        systemctl enable k3s
        systemctl restart k3s
    fi

    local node_ip
    if [[ -n "$iface" ]]; then
        node_ip="$(validate_interface "$iface")"
    else
        node_ip="$(best_ip)"
    fi

    save_config "master" "$iface" "$node_ip" "$server"
    log "HA master joined successfully."
}

cmd_install() {
    local role="${1:-}"
    shift || true

    case "$role" in
        master)
            install_server "$@"
            ;;
        worker|agent)
            install_worker "$@"
            ;;
        join-master)
            install_join_master "$@"
            ;;
        *)
            die "Usage: k3s-manager install {master|worker|join-master} [options]"
            ;;
    esac
}

cmd_token() {
    need_root

    [[ -r "$K3S_TOKEN_FILE" ]] ||
        die "K3s server token not found. This node is not a K3s server."

    local token
    token="$(cat "$K3S_TOKEN_FILE")"

    echo
    echo "=================================================="
    echo "                 K3S JOIN INFORMATION"
    echo "=================================================="
    echo

    local iface ipaddr
    local found=0

    for iface in en0 eth0 wlan0 wlan1; do
        if iface_exists "$iface"; then
            ipaddr="$(iface_ip "$iface" || true)"
            if [[ -n "$ipaddr" ]]; then
                found=1
                echo "$iface:"
                echo "  Server URL: https://${ipaddr}:6443"
                echo
            fi
        fi
    done

    if [[ "$found" -eq 0 ]]; then
        ipaddr="$(best_ip)"
        if [[ -n "$ipaddr" ]]; then
            echo "Detected:"
            echo "  Server URL: https://${ipaddr}:6443"
            echo
        fi
    fi

    echo "Token:"
    echo "  ${token}"
    echo
    echo "Worker:"
    echo "  sudo k3s-manager install worker --server https://<MASTER-IP>:6443 --token '<TOKEN>' --interface eth0"
    echo
    echo "Additional HA master:"
    echo "  sudo k3s-manager install join-master --server https://<MASTER-IP>:6443 --token '<TOKEN>' --interface eth0"
    echo
}

cmd_status() {
    need_root
    load_os
    load_config

    echo "=== K3S MANAGER ==="
    echo "Version:    $VERSION"
    echo "Role:       ${K3SMGR_ROLE:-unknown}"
    echo "Interface:  ${K3SMGR_INTERFACE:-automatic}"
    echo "Node IP:    ${K3SMGR_NODE_IP:-unknown}"
    echo "Server:     ${K3SMGR_SERVER_URL:-unknown}"
    echo

    if [[ "${K3SMGR_ROLE:-}" == "worker" ]]; then
        echo "=== K3S AGENT ==="
        if [[ "$INIT" == "systemd" ]]; then
            systemctl --no-pager --full status k3s-agent || true
        else
            rc-service k3s-agent status || true
        fi
    else
        echo "=== K3S SERVER ==="
        if [[ "$INIT" == "systemd" ]]; then
            systemctl --no-pager --full status k3s || true
        else
            rc-service k3s status || true
        fi

        if [[ -f "$KUBECONFIG_PATH" ]]; then
            echo
            echo "=== CLUSTER NODES ==="
            kctl get nodes -o wide || true
        fi
    fi
}

cmd_list_nodes() {
    need_root
    kctl get nodes -o wide
}

cmd_network_info() {
    network_info
}

cmd_enable_boot() {
    need_root
    load_os
    load_config

    local service="k3s"
    [[ "${K3SMGR_ROLE:-}" == "worker" ]] && service="k3s-agent"

    if [[ "$INIT" == "systemd" ]]; then
        systemctl enable "$service"
        echo "$service enabled at boot."
    else
        rc-update add "$service" default
        echo "$service enabled at boot."
    fi
}

cmd_disable_boot() {
    need_root
    load_os
    load_config

    local service="k3s"
    [[ "${K3SMGR_ROLE:-}" == "worker" ]] && service="k3s-agent"

    if [[ "$INIT" == "systemd" ]]; then
        systemctl disable "$service"
        echo "$service disabled at boot."
    else
        rc-update del "$service" default || true
        echo "$service disabled at boot."
    fi
}

cmd_restart() {
    need_root
    load_os
    load_config

    local service="k3s"
    [[ "${K3SMGR_ROLE:-}" == "worker" ]] && service="k3s-agent"

    if [[ "$INIT" == "systemd" ]]; then
        systemctl restart "$service"
    else
        rc-service "$service" restart
    fi
}

cmd_stop() {
    need_root
    load_os
    load_config

    local service="k3s"
    [[ "${K3SMGR_ROLE:-}" == "worker" ]] && service="k3s-agent"

    if [[ "$INIT" == "systemd" ]]; then
        systemctl stop "$service"
    else
        rc-service "$service" stop
    fi
}

cmd_start() {
    need_root
    load_os
    load_config

    local service="k3s"
    [[ "${K3SMGR_ROLE:-}" == "worker" ]] && service="k3s-agent"

    if [[ "$INIT" == "systemd" ]]; then
        systemctl start "$service"
    else
        rc-service "$service" start
    fi
}

cmd_add_node() {
    need_root

    local kind="${1:-}"
    shift || true

    local ssh_target=""
    local iface="eth0"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ssh)
                [[ $# -ge 2 ]] || die "--ssh requires user@host."
                ssh_target="$2"
                shift 2
                ;;
            --interface)
                [[ $# -ge 2 ]] || die "--interface requires an interface."
                iface="$2"
                shift 2
                ;;
            *)
                die "Unknown add-node option: $1"
                ;;
        esac
    done

    [[ -r "$K3S_TOKEN_FILE" ]] ||
        die "This command must be run on a K3s server."

    local master_ip
    master_ip="$(best_ip)"
    [[ -n "$master_ip" ]] || die "Could not determine master IP."

    local token
    token="$(cat "$K3S_TOKEN_FILE")"

    local server="https://${master_ip}:6443"
    local remote_cmd

    case "$kind" in
        worker)
            remote_cmd="sudo k3s-manager install worker --server $(printf '%q' "$server") --token $(printf '%q' "$token") --interface $(printf '%q' "$iface")"
            ;;
        master)
            remote_cmd="sudo k3s-manager install join-master --server $(printf '%q' "$server") --token $(printf '%q' "$token") --interface $(printf '%q' "$iface")"
            ;;
        *)
            die "Usage: k3s-manager add-node {worker|master} [--ssh user@host] [--interface eth0]"
            ;;
    esac

    if [[ -n "$ssh_target" ]]; then
        ssh -o StrictHostKeyChecking=accept-new "$ssh_target" "$remote_cmd"
    else
        echo "$remote_cmd"
    fi
}

cmd_remove_node() {
    need_root

    local node="${1:-}"
    [[ -n "$node" ]] || die "Usage: k3s-manager remove-node NODE"

    kctl drain "$node" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --force \
        --timeout=120s || true

    kctl delete node "$node" || true

    echo "Node removed: $node"
}

cmd_uninstall() {
    need_root

    if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
        /usr/local/bin/k3s-uninstall.sh
    elif [[ -x /usr/local/bin/k3s-agent-uninstall.sh ]]; then
        /usr/local/bin/k3s-agent-uninstall.sh
    else
        die "No K3s uninstall script found."
    fi

    rm -rf "$CONFIG_DIR"
    echo "K3s manager configuration removed."
}

cmd_watchdog_install() {
    need_root
    load_os

    local master=""
    local interval=15
    local threshold=8

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --master)
                [[ $# -ge 2 ]] || die "--master requires an IP/hostname."
                master="$2"
                shift 2
                ;;
            --check-interval)
                [[ $# -ge 2 ]] || die "--check-interval requires seconds."
                interval="$2"
                shift 2
                ;;
            --fail-threshold)
                [[ $# -ge 2 ]] || die "--fail-threshold requires a number."
                threshold="$2"
                shift 2
                ;;
            *)
                die "Unknown watchdog option: $1"
                ;;
        esac
    done

    [[ -n "$master" ]] || die "--master is required."

    install -d -m 0755 "$CONFIG_DIR"

    cat > "$CONFIG_FILE" <<CFG
K3SMGR_WATCHDOG_MASTER=$(printf '%q' "$master")
K3SMGR_WATCHDOG_INTERVAL=$(printf '%q' "$interval")
K3SMGR_WATCHDOG_THRESHOLD=$(printf '%q' "$threshold")
CFG

    chmod 600 "$CONFIG_FILE"

    cat > /usr/local/bin/k3s-manager-watchdog.sh <<'WATCHDOG'
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG="/etc/k3s-manager/config.env"
STATE_DIR="/var/lib/k3s-manager"
STATE_FILE="${STATE_DIR}/watchdog-failures"

[[ -r "$CONFIG" ]] || exit 0
# shellcheck disable=SC1090
. "$CONFIG"

mkdir -p "$STATE_DIR"

MASTER="${K3SMGR_WATCHDOG_MASTER:-}"
THRESHOLD="${K3SMGR_WATCHDOG_THRESHOLD:-8}"

[[ -n "$MASTER" ]] || exit 0

failures=0
[[ -r "$STATE_FILE" ]] && failures="$(cat "$STATE_FILE")"

if curl -kfsS --connect-timeout 3 --max-time 5 "https://${MASTER}:6443/healthz" >/dev/null 2>&1; then
    echo 0 > "$STATE_FILE"
    exit 0
fi

failures=$((failures + 1))
echo "$failures" > "$STATE_FILE"

logger -t k3s-manager-watchdog "K3s master ${MASTER} unreachable (${failures}/${THRESHOLD})"

if (( failures >= THRESHOLD )); then
    logger -t k3s-manager-watchdog "Failover threshold reached; watchdog will not automatically rewrite the cluster."
    logger -t k3s-manager-watchdog "Manual promotion is required: sudo k3s-manager promote"
fi
WATCHDOG

    chmod 0755 /usr/local/bin/k3s-manager-watchdog.sh

    cat > /etc/systemd/system/k3s-manager-watchdog.service <<'SERVICE'
[Unit]
Description=K3s Manager Watchdog

[Service]
Type=oneshot
ExecStart=/usr/local/bin/k3s-manager-watchdog.sh
SERVICE

    cat > /etc/systemd/system/k3s-manager-watchdog.timer <<SERVICE
[Unit]
Description=K3s Manager Watchdog Timer

[Timer]
OnBootSec=30s
OnUnitActiveSec=${interval}s
AccuracySec=1s

[Install]
WantedBy=timers.target
SERVICE

    systemctl daemon-reload
    systemctl enable --now k3s-manager-watchdog.timer

    echo "Watchdog installed."
    echo "Master: ${master}"
    echo "Interval: ${interval}s"
    echo "Failure threshold: ${threshold}"
}

cmd_watchdog_uninstall() {
    need_root

    systemctl disable --now k3s-manager-watchdog.timer 2>/dev/null || true

    rm -f \
        /etc/systemd/system/k3s-manager-watchdog.timer \
        /etc/systemd/system/k3s-manager-watchdog.service \
        /usr/local/bin/k3s-manager-watchdog.sh

    systemctl daemon-reload
    rm -rf /var/lib/k3s-manager

    echo "Watchdog removed."
}

cmd_promote() {
    need_root

    if [[ -x /usr/local/bin/k3s-manager-watchdog.sh ]]; then
        /usr/local/bin/k3s-manager-watchdog.sh
    else
        echo "Watchdog is not installed."
        echo "Automatic promotion is intentionally not performed by this command."
    fi
}

cmd_help() {
    cat <<'HELP'
K3S MANAGER
===========

Install a master:

  sudo k3s-manager install master --interface eth0

Install an HA/embedded-etcd first master:

  sudo k3s-manager install master --ha --interface eth0

Allow workloads on the master:

  sudo k3s-manager install master --ha --worker --interface eth0

Get join information:

  sudo k3s-manager token

Install a worker:

  sudo k3s-manager install worker \
    --server https://MASTER_IP:6443 \
    --token 'TOKEN' \
    --interface eth0

Join another HA master:

  sudo k3s-manager install join-master \
    --server https://MASTER_IP:6443 \
    --token 'TOKEN' \
    --interface eth0

Network information:

  sudo k3s-manager network-info

Cluster status:

  sudo k3s-manager status

List nodes:

  sudo k3s-manager list-nodes

Start/stop/restart:

  sudo k3s-manager start
  sudo k3s-manager stop
  sudo k3s-manager restart

Boot:

  sudo k3s-manager enable-boot
  sudo k3s-manager disable-boot

Add a node:

  sudo k3s-manager add-node worker
  sudo k3s-manager add-node master

Add over SSH:

  sudo k3s-manager add-node worker --ssh barnaby@worker1 --interface eth0

Remove a node:

  sudo k3s-manager remove-node NODE_NAME

Watchdog:

  sudo k3s-manager watchdog-install --master MASTER_IP

  sudo k3s-manager watchdog-uninstall

  sudo k3s-manager promote

Uninstall:

  sudo k3s-manager uninstall

NETWORKING
==========

--interface eth0 causes K3s to use the IPv4 address assigned to eth0
for:

  --node-ip
  --advertise-address
  --flannel-iface

The token command displays all detected addresses for:

  en0
  eth0
  wlan0
  wlan1

IMPORTANT:

For a multi-node cluster, every node must be able to reach the selected
master address on TCP 6443 and the K3s networking traffic must be allowed
between nodes.

EXAMPLES
========

One master + one worker:

  MASTER:
    sudo k3s-manager install master --interface eth0

  MASTER:
    sudo k3s-manager token

  WORKER:
    sudo k3s-manager install worker --server https://MASTER_ETH0_IP:6443 --token 'TOKEN' --interface eth0

One master + multiple workers:

  Run the worker installation on every worker using the same server/token.

HA:

  MASTER 1:
    sudo k3s-manager install master --ha --interface eth0

  MASTER 2/3:
    sudo k3s-manager install join-master --server https://MASTER1_ETH0_IP:6443 --token 'TOKEN' --interface eth0

VERSION
=======

  k3s-manager ${VERSION}
HELP
}

main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        install)
            cmd_install "$@"
            ;;
        token|join-info)
            cmd_token
            ;;
        network-info)
            cmd_network_info
            ;;
        status)
            cmd_status
            ;;
        list-nodes|get-nodes)
            cmd_list_nodes
            ;;
        start)
            cmd_start
            ;;
        stop)
            cmd_stop
            ;;
        restart)
            cmd_restart
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
        uninstall)
            cmd_uninstall
            ;;
        version|--version|-V)
            echo "k3s-manager ${VERSION}"
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            echo "Unknown command: $command" >&2
            echo
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
