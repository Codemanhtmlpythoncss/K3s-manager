#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Fail fast and clearly on ancient bash instead of a confusing error mid-install.
# `local -n` namerefs need bash >= 4.3; this is only a problem on very old
# distributions (RHEL/CentOS 7, Amazon Linux 2, SLES 12 and earlier).
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    echo "k3s-manager requires bash >= 4.3 (found ${BASH_VERSION:-unknown})." >&2
    echo "This only affects very old distributions (RHEL/CentOS 7, Amazon Linux 2, SLES 12 or earlier)." >&2
    echo "Install a newer bash package for your distro, or use a current OS release." >&2
    exit 1
fi

VERSION="3.1.9"
REPO_RAW_URL="${K3SMGR_REPO_RAW_URL:-https://raw.githubusercontent.com/Codemanhtmlpythoncss/K3s-manager/main/k3s-manager.sh}"
SELF_PATH="$(command -v -- "$0" 2>/dev/null || readlink -f -- "$0" 2>/dev/null || echo "$0")"
CONFIG_DIR="/etc/k3s-manager"
CONFIG_FILE="${CONFIG_DIR}/config.env"
LOG_FILE="/var/log/k3s-manager.log"
K3S_TOKEN_FILE="/var/lib/rancher/k3s/server/node-token"
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
AI_NAMESPACE="ai-inference"
OLLAMA_PORT=11434

ASSUME_YES=0
DRY_RUN=0
VERBOSE=0
NONINTERACTIVE=0
[[ -t 0 ]] || NONINTERACTIVE=1

# ---------- output / logging ----------

c_red() { printf '\033[31m%s\033[0m' "$*"; }
c_green() { printf '\033[32m%s\033[0m' "$*"; }
c_yellow() { printf '\033[33m%s\033[0m' "$*"; }
c_blue() { printf '\033[34m%s\033[0m' "$*"; }

log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" 2>/dev/null || \
        printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

info()  { log "INFO:  $*"; }
warn()  { log "WARN:  $*"; echo "$(c_yellow "WARNING:") $*" >&2; }
ok()    { log "OK:    $*"; echo "$(c_green "OK:") $*"; }

die() {
    log "ERROR: $*"
    echo "$(c_red "ERROR:") $*" >&2
    exit 1
}

vlog() {
    [[ "$VERBOSE" -eq 1 ]] || return 0
    echo "$(c_blue "[verbose]") $*" >&2
}

need_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this command with sudo (root privileges required)."
}

have() {
    command -v "$1" >/dev/null 2>&1
}

confirm() {
    local prompt="$1" default="${2:-y}" reply
    if [[ "$ASSUME_YES" -eq 1 || "$NONINTERACTIVE" -eq 1 ]]; then
        vlog "confirm: auto-answer '$default' for: $prompt"
        [[ "$default" == "y" ]]
        return $?
    fi
    local hint="y/N"
    [[ "$default" == "y" ]] && hint="Y/n"
    read -r -p "$prompt [$hint] " reply || reply=""
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy]$ ]]
}

ask() {
    local prompt="$1" default="${2:-}" reply
    if [[ "$NONINTERACTIVE" -eq 1 ]]; then
        printf '%s\n' "$default"
        return 0
    fi
    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " reply || reply=""
        printf '%s\n' "${reply:-$default}"
    else
        read -r -p "$prompt: " reply || reply=""
        printf '%s\n' "$reply"
    fi
}

# run: honors DRY_RUN/VERBOSE for state-changing commands
run() {
    vlog "+ $*"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "$(c_blue "[dry-run]") $*"
        return 0
    fi
    "$@"
}

# retry N DELAY_SECONDS cmd...  -- retries a flaky command with backoff
retry() {
    local max="$1" delay="$2"
    shift 2
    local attempt=1
    until "$@"; do
        if (( attempt >= max )); then
            warn "Command failed after ${attempt} attempts: $*"
            return 1
        fi
        warn "Attempt ${attempt}/${max} failed: $*  (retrying in ${delay}s)"
        sleep "$delay"
        attempt=$((attempt + 1))
        delay=$(( delay < 30 ? delay * 2 : delay ))
    done
}

on_err() {
    local exit_code=$? line=${BASH_LINENO[0]:-0} cmd=${BASH_COMMAND:-unknown}
    log "ERROR: command failed (exit ${exit_code}) at line ${line}: ${cmd}"
    echo "$(c_red "A step failed:") '${cmd}' (line ${line}, exit ${exit_code})" >&2
    echo "Run 'sudo $(basename "$SELF_PATH") doctor' to diagnose, or check ${LOG_FILE}." >&2
}
trap on_err ERR

ensure_config_dir() {
    install -d -m 0755 "$CONFIG_DIR"
}

# ---------- OS detection (interactive) ----------

OS_ID="unknown"
OS_ID_LIKE=""
OS_VERSION=""
PKG=""
INIT=""

detect_os_auto() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_ID_LIKE="${ID_LIKE:-}"
        OS_VERSION="${VERSION_ID:-${VERSION_CODENAME:-}}"
    fi

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
        PKG=""
    fi

    if have systemctl && systemctl --version >/dev/null 2>&1; then
        INIT="systemd"
    elif have rc-service; then
        INIT="openrc"
    else
        INIT=""
    fi
}

# load_os: detects the OS/package manager and, in interactive sessions,
# asks the user to confirm or pick manually -- this is intentional per
# the user's requirement to "ask for your linux operating system".
load_os() {
    detect_os_auto

    if [[ "$NONINTERACTIVE" -eq 1 || "$ASSUME_YES" -eq 1 ]]; then
        [[ -n "$PKG" ]] || die "Unsupported/undetected package manager. Re-run interactively or set K3SMGR_PKG."
        [[ -n "$INIT" ]] || die "K3s requires systemd or OpenRC."
        return 0
    fi

    echo
    echo "Detected operating system:"
    echo "  ID:              ${OS_ID}"
    [[ -n "$OS_ID_LIKE" ]] && echo "  ID_LIKE:         ${OS_ID_LIKE}"
    [[ -n "$OS_VERSION" ]] && echo "  VERSION:         ${OS_VERSION}"
    echo "  Package manager: ${PKG:-none detected}"
    echo "  Init system:     ${INIT:-none detected}"
    echo

    if [[ -n "$PKG" && -n "$INIT" ]] && confirm "Is this correct?" y; then
        return 0
    fi

    echo "Select your Linux distribution family:"
    echo "  1) Debian / Ubuntu / Raspberry Pi OS   (apt)"
    echo "  2) Fedora / RHEL / CentOS / Rocky/Alma  (dnf)"
    echo "  3) RHEL/CentOS 7 legacy                 (yum)"
    echo "  4) openSUSE / SLES                      (zypper)"
    echo "  5) Arch Linux / Manjaro                 (pacman)"
    echo "  6) Alpine Linux                         (apk)"
    local choice
    choice="$(ask "Choice" "1")"
    case "$choice" in
        1) PKG="apt" ;;
        2) PKG="dnf" ;;
        3) PKG="yum" ;;
        4) PKG="zypper" ;;
        5) PKG="pacman" ;;
        6) PKG="apk" ;;
        *) die "Invalid selection." ;;
    esac

    case "$PKG" in
        apt)    have apt-get || warn "apt-get not found on this system; installs may fail." ;;
        dnf)    have dnf     || warn "dnf not found on this system; installs may fail." ;;
        yum)    have yum     || warn "yum not found on this system; installs may fail." ;;
        zypper) have zypper  || warn "zypper not found on this system; installs may fail." ;;
        pacman) have pacman  || warn "pacman not found on this system; installs may fail." ;;
        apk)    have apk     || warn "apk not found on this system; installs may fail." ;;
    esac

    [[ -n "$INIT" ]] || die "K3s requires systemd or OpenRC, neither was detected."
    ok "Using package manager: ${PKG}"
}

# ---------- config persistence ----------

save_config() {
    ensure_config_dir
    local role="${1:-}" iface="${2:-}" ip="${3:-}" server="${4:-}"
    local channel="${5:-${K3SMGR_CHANNEL:-}}" tls_san="${6:-${K3SMGR_TLS_SAN:-}}"

    umask 077
    cat > "${CONFIG_FILE}.tmp" <<CFG
K3SMGR_ROLE=$(printf '%q' "$role")
K3SMGR_INTERFACE=$(printf '%q' "$iface")
K3SMGR_NODE_IP=$(printf '%q' "$ip")
K3SMGR_SERVER_URL=$(printf '%q' "$server")
K3SMGR_CHANNEL=$(printf '%q' "$channel")
K3SMGR_TLS_SAN=$(printf '%q' "$tls_san")
K3SMGR_LAST_UPDATED=$(printf '%q' "$(date '+%Y-%m-%d %H:%M:%S')")
CFG

    chmod 600 "${CONFIG_FILE}.tmp"
    mv -f "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        . "$CONFIG_FILE"
    fi

    # No saved role (e.g. an earlier install failed before saving): infer it
    # from what the k3s installer actually put on disk.
    if [[ -z "${K3SMGR_ROLE:-}" ]]; then
        if [[ -f /etc/systemd/system/k3s-agent.service || -x /usr/local/bin/k3s-agent-uninstall.sh ]]; then
            K3SMGR_ROLE="worker"
        elif [[ -f /etc/systemd/system/k3s.service || -x /usr/local/bin/k3s-uninstall.sh ]]; then
            K3SMGR_ROLE="master"
        fi
    fi

    if [[ "${K3SMGR_ROLE:-}" == "worker" && -z "${K3SMGR_SERVER_URL:-}" && -r /etc/systemd/system/k3s-agent.service.env ]]; then
        K3SMGR_SERVER_URL="$(sed -n "s/^K3S_URL=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}$/\1/p" /etc/systemd/system/k3s-agent.service.env | head -n1 || true)"
    fi
    return 0
}

# ---------- network helpers ----------

iface_exists() {
    ip link show dev "$1" >/dev/null 2>&1
}

iface_ip() {
    ip -4 -o addr show dev "$1" scope global 2>/dev/null |
        awk 'NR==1 {split($4,a,"/"); print a[1]}'
}

iface_state() {
    cat "/sys/class/net/${1}/operstate" 2>/dev/null || echo "unknown"
}

best_ip() {
    local value
    value="$(ip -4 route get 1.1.1.1 2>/dev/null |
        awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"

    if [[ -n "$value" ]]; then
        printf '%s\n' "$value"
        return 0
    fi

    hostname -I 2>/dev/null | awk '{print $1}' || true
}

# list every interface with a global IPv4, excluding loopback.
# Fields are tab-separated because the script's global IFS ($'\n\t') does
# not include a space, so callers doing `read -r name cidr` need a
# delimiter that IFS still splits on.
list_candidate_ifaces() {
    ip -4 -o addr show scope global 2>/dev/null |
        awk '$2 != "lo" {print $2 "\t" $4}'
}

tailscale_ip() {
    have tailscale || return 1
    tailscale ip -4 2>/dev/null | head -n1
}

network_info() {
    echo "=== K3S NETWORK INFORMATION ==="
    printf '%-12s %-18s %-10s\n' "INTERFACE" "IPV4" "STATE"

    local found=0
    local name cidr ipaddr state

    while read -r name cidr; do
        [[ -z "$name" ]] && continue
        found=1
        ipaddr="${cidr%%/*}"
        state="$(iface_state "$name")"
        printf '%-12s %-18s %-10s\n' "$name" "$ipaddr" "$state"
    done < <(list_candidate_ifaces)

    if [[ "$found" -eq 0 ]]; then
        ip -br addr
    fi

    echo
    echo "=== DEFAULT ROUTE ==="
    ip -4 route show default 2>/dev/null || echo "(none -- expected if this interface is internet-less by design)"

    echo
    echo "=== DEFAULT ROUTED SOURCE IP ==="
    echo "$(best_ip)"

    if have tailscale; then
        echo
        echo "=== TAILSCALE ==="
        local tsip
        tsip="$(tailscale_ip || true)"
        echo "Tailscale IPv4: ${tsip:-not connected}"
        tailscale status --self 2>/dev/null | head -n1 || true
    fi
}

validate_interface() {
    local iface="$1"

    [[ -n "$iface" ]] || return 0

    iface_exists "$iface" ||
        die "Network interface '$iface' does not exist. Run 'network-info' to list available interfaces."

    local state
    state="$(iface_state "$iface")"
    if [[ "$state" != "up" && "$state" != "unknown" ]]; then
        warn "Interface '$iface' is reported '$state'. Attempting to bring it up."
        run ip link set dev "$iface" up || true
        sleep 1
    fi

    local ipaddr
    ipaddr="$(iface_ip "$iface" || true)"

    [[ -n "$ipaddr" ]] ||
        die "Network interface '$iface' has no global IPv4 address. Configure it (e.g. via NetworkManager) before continuing."

    printf '%s\n' "$ipaddr"
}

# build_network_args IFACE [MODE]
# MODE is "server" (default) or "agent". `k3s agent` has no --advertise-address
# flag at all (it's a server/apiserver-only concept) -- passing it makes the
# agent refuse to start with "flag provided but not defined: -advertise-address".
build_network_args() {
    local iface="${1:-}"
    local mode="${2:-server}"
    NETWORK_ARGS=()

    if [[ -n "$iface" ]]; then
        local ipaddr
        ipaddr="$(validate_interface "$iface")"

        NETWORK_ARGS=("--node-ip" "$ipaddr" "--flannel-iface" "$iface")
        if [[ "$mode" == "server" ]]; then
            NETWORK_ARGS+=("--advertise-address" "$ipaddr")
        fi
    fi
    return 0
}

# builds a --tls-san list: explicit SANs + (optionally) hostname + tailscale IP
build_tls_san_args() {
    local extra_csv="${1:-}"
    local include_auto="${2:-1}"
    TLS_SAN_ARGS=()
    local seen=" "

    add_san() {
        local v="$1"
        [[ -n "$v" ]] || return 0
        [[ "$seen" == *" $v "* ]] && return 0
        seen+="$v "
        TLS_SAN_ARGS+=("--tls-san" "$v")
    }

    if [[ -n "$extra_csv" ]]; then
        local IFS=','
        local san
        for san in $extra_csv; do
            add_san "$san"
        done
    fi

    if [[ "$include_auto" -eq 1 ]]; then
        add_san "$(hostname -f 2>/dev/null || hostname)"
        local tsip
        tsip="$(tailscale_ip || true)"
        if [[ -n "$tsip" ]]; then
            add_san "$tsip"
        fi
    fi
    return 0
}

# ---------- prerequisites ----------

pkg_install() {
    # pkg_install PKG1 PKG2 ... -- best-effort; missing optional packages warn, never abort
    local -a pkgs=("$@")
    [[ "${#pkgs[@]}" -gt 0 ]] || return 0

    case "$PKG" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            retry 3 5 run apt-get install -y "${pkgs[@]}" || warn "Some packages failed to install: ${pkgs[*]}"
            ;;
        dnf)
            retry 3 5 run dnf install -y "${pkgs[@]}" || warn "Some packages failed to install: ${pkgs[*]}"
            ;;
        yum)
            retry 3 5 run yum install -y "${pkgs[@]}" || warn "Some packages failed to install: ${pkgs[*]}"
            ;;
        zypper)
            retry 3 5 run zypper --non-interactive install "${pkgs[@]}" || warn "Some packages failed to install: ${pkgs[*]}"
            ;;
        pacman)
            retry 3 5 run pacman -S --noconfirm --needed "${pkgs[@]}" || warn "Some packages failed to install: ${pkgs[*]} (run a full 'pacman -Syu' first if your package database is stale)"
            ;;
        apk)
            retry 3 5 run apk add --no-cache "${pkgs[@]}" || warn "Some packages failed to install: ${pkgs[*]}"
            ;;
        *)
            warn "No known package manager; skipping install of: ${pkgs[*]}"
            ;;
    esac
}

install_prereqs() {
    need_root
    load_os

    info "Detected distro=${OS_ID} package-manager=${PKG} init=${INIT}"
    info "Installing prerequisites..."

    case "$PKG" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            retry 3 5 run apt-get update || warn "apt-get update failed; continuing with cached package lists."
            pkg_install curl ca-certificates open-iscsi nfs-common apparmor apparmor-utils conntrack socat iptables
            ;;
        dnf)
            pkg_install curl ca-certificates nfs-utils socat conntrack-tools iscsi-initiator-utils iptables
            have iscsiadm && run systemctl enable --now iscsid 2>/dev/null || true
            ;;
        yum)
            pkg_install curl ca-certificates nfs-utils socat conntrack-tools iscsi-initiator-utils iptables
            have iscsiadm && run systemctl enable --now iscsid 2>/dev/null || true
            ;;
        zypper)
            pkg_install curl ca-certificates nfs-client socat conntrack-tools open-iscsi iptables
            ;;
        pacman)
            # No -Sy here: syncing without upgrading is an Arch "partial upgrade".
            # iptables is omitted because it conflicts with Arch's default iptables-nft
            # (k3s ships its own iptables binaries anyway).
            pkg_install curl ca-certificates nfs-utils socat conntrack-tools open-iscsi
            ;;
        apk)
            pkg_install curl ca-certificates nfs-utils socat conntrack-tools open-iscsi iptables
            ;;
        *)
            warn "Unrecognized package manager; ensure curl, conntrack and socat are installed manually."
            ;;
    esac

    fix_kernel_modules
    fix_sysctl
    check_swap
    check_time_sync
}

# ---------- kernel/sysctl requirements ----------

fix_kernel_modules() {
    local mod
    for mod in overlay br_netfilter; do
        if ! grep -q "^${mod} " <<<"$(lsmod 2>/dev/null || true)"; then
            run modprobe "$mod" 2>/dev/null || warn "Could not load kernel module '$mod' (may be built-in, which is fine)."
        fi
    done
    install -d -m 0755 /etc/modules-load.d 2>/dev/null || true
    if [[ ! -f /etc/modules-load.d/k3s-manager.conf ]]; then
        printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k3s-manager.conf 2>/dev/null || \
            warn "Could not persist kernel modules to /etc/modules-load.d/k3s-manager.conf"
    fi
}

fix_sysctl() {
    install -d -m 0755 /etc/sysctl.d 2>/dev/null || true
    cat > /etc/sysctl.d/90-k3s-manager.conf <<'SYSCTL' 2>/dev/null || warn "Could not write sysctl settings."
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
SYSCTL
    run sysctl --system >/dev/null 2>&1 || warn "sysctl --system reported issues; some settings may not have applied."
}

check_swap() {
    local swap_on
    swap_on="$(swapon --noheadings 2>/dev/null || true)"
    if [[ -z "$swap_on" ]]; then
        vlog "No active swap detected."
        return 0
    fi

    # k3s runs kubelet with fail-swap-on=false, so swap is fine. Never turn it
    # off persistently just because --yes was passed: on a laptop that can
    # break hibernation. Only do it when a human explicitly says yes.
    info "Swap is enabled. k3s runs fine with swap on, so it is being left alone."
    if [[ "$NONINTERACTIVE" -eq 0 && "$ASSUME_YES" -eq 0 ]] && confirm "Disable swap anyway and comment it out of /etc/fstab?" n; then
        run swapoff -a || warn "swapoff failed."
        if [[ -f /etc/fstab ]]; then
            cp -a /etc/fstab "/etc/fstab.k3s-manager.bak.$(date +%s)" 2>/dev/null || true
            sed -i.bak -E 's/^([^#].*\sswap\s.*)$/#\1/' /etc/fstab 2>/dev/null || \
                warn "Could not edit /etc/fstab automatically; comment out swap entries manually."
        fi
        ok "Swap disabled."
    fi
    return 0
}

check_time_sync() {
    local svc
    for svc in systemd-timesyncd chronyd chrony ntpd ntpsec openntpd; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            vlog "Time sync service active: $svc"
            return 0
        fi
    done
    warn "No active time-sync service detected (systemd-timesyncd/chrony/ntpd). Clock drift can break TLS between nodes."
    return 0
}

# ---------- firewall ----------

detect_firewall() {
    local out=""
    if have ufw && grep -qi "^Status: active" <<<"$(ufw status 2>/dev/null || true)"; then
        echo "ufw"
    elif have firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
        echo "firewalld"
    elif have nft && [[ -n "$(nft list ruleset 2>/dev/null || true)" ]]; then
        echo "nftables"
    elif have iptables && out="$(iptables -S 2>/dev/null || true)" && [[ -n "$out" ]] && grep -qv '^-P .* ACCEPT$' <<<"$out"; then
        echo "iptables"
    else
        echo "none"
    fi
}

# open_k3s_ports ROLE  (server|agent) -- best-effort, never fatal
open_k3s_ports() {
    local role="${1:-server}"
    local fw
    fw="$(detect_firewall)"
    info "Firewall backend detected: ${fw}"

    case "$fw" in
        none)
            vlog "No active firewall detected; skipping port rules."
            return 0
            ;;
        ufw)
            run ufw allow 6443/tcp comment 'k3s API' || true
            run ufw allow 8472/udp comment 'k3s flannel vxlan' || true
            run ufw allow 51820/udp comment 'k3s flannel wireguard' || true
            run ufw allow 51821/udp comment 'k3s flannel wireguard ipv6' || true
            run ufw allow 10250/tcp comment 'kubelet' || true
            if [[ "$role" == "server" ]]; then
                run ufw allow 2379:2380/tcp comment 'k3s etcd' || true
            fi
            ;;
        firewalld)
            run firewall-cmd --permanent --add-port=6443/tcp || true
            run firewall-cmd --permanent --add-port=8472/udp || true
            run firewall-cmd --permanent --add-port=51820-51821/udp || true
            run firewall-cmd --permanent --add-port=10250/tcp || true
            [[ "$role" == "server" ]] && run firewall-cmd --permanent --add-port=2379-2380/tcp || true
            run firewall-cmd --reload || true
            ;;
        nftables|iptables)
            warn "Detected ${fw} with active rules. k3s-manager will not rewrite custom rulesets automatically."
            echo "Ensure these are reachable between nodes: 6443/tcp, 8472/udp, 10250/tcp, 51820-51821/udp, 2379-2380/tcp (servers)."
            ;;
    esac
    ok "Firewall rules reconciled for role: ${role} (backend: ${fw})"
}

cmd_firewall() {
    need_root
    local action="${1:-status}"
    case "$action" in
        status)
            echo "Detected backend: $(detect_firewall)"
            if have ufw; then echo; ufw status verbose 2>/dev/null || true; fi
            if have firewall-cmd; then echo; firewall-cmd --list-all 2>/dev/null || true; fi
            ;;
        open)
            load_config
            open_k3s_ports "${K3SMGR_ROLE:-server}"
            ;;
        disable)
            confirm "Disable the host firewall entirely? This reduces security." n || { echo "Aborted."; return 0; }
            if have ufw; then run ufw disable; fi
            if have firewall-cmd; then run systemctl stop firewalld; fi
            ;;
        *)
            die "Usage: k3s-manager firewall {status|open|disable}"
            ;;
    esac
    return 0
}

# ---------- coexistence with other host services (e.g. Nextcloud) ----------

# port_in_use PORT -- true if something is already listening on this TCP port
port_in_use() {
    local port="$1"
    if have ss; then
        grep -qE "[.:]${port}\$" <<<"$(ss -ltn 2>/dev/null | awk 'NR>1{print $4}' || true)"
    elif have netstat; then
        grep -qE "[.:]${port}\$" <<<"$(netstat -ltn 2>/dev/null | awk 'NR>2{print $4}' || true)"
    else
        (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null && { exec 3>&-; return 0; } || return 1
    fi
}

# detect_nextcloud -- best-effort detection of a Nextcloud install on THIS host,
# covering the common install methods (snap, Docker/AIO, apt/manual web root).
detect_nextcloud() {
    local found=0 how=""

    if have snap && grep -qi '^nextcloud ' <<<"$(snap list 2>/dev/null || true)"; then
        found=1; how="snap package 'nextcloud'"
    fi
    if have docker && grep -qi 'nextcloud' <<<"$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null || true)"; then
        found=1; how="${how:+$how, }a running Docker container"
    fi
    if [[ -d /var/www/nextcloud || -d /var/www/html/nextcloud ]]; then
        found=1; how="${how:+$how, }a web root at /var/www*/nextcloud"
    fi
    if grep -qi nextcloud <<<"$(systemctl list-units --type=service --all 2>/dev/null || true)"; then
        found=1; how="${how:+$how, }a systemd service"
    fi

    [[ "$found" -eq 1 ]] && printf '%s\n' "$how"
    return $(( 1 - found ))
}

# preflight_host_ports -- warns about (and can auto-mitigate) port 80/443 clashes
# before k3s's bundled Traefik ingress + ServiceLB try to bind them on every node.
# Sets AUTO_DISABLE_INGRESS=1 if it decides Traefik/ServiceLB should be skipped.
AUTO_DISABLE_INGRESS=0
preflight_host_ports() {
    local keep_ingress="${1:-0}"
    local nc_how
    nc_how="$(detect_nextcloud || true)"

    if [[ -n "$nc_how" ]]; then
        warn "Detected Nextcloud on this host (${nc_how})."
    fi

    local p80=0 p443=0
    port_in_use 80  && p80=1
    port_in_use 443 && p443=1

    if [[ "$p80" -eq 1 || "$p443" -eq 1 ]]; then
        warn "Port $([[ $p80 -eq 1 ]] && echo -n 80)$([[ $p80 -eq 1 && $p443 -eq 1 ]] && echo -n '/')$([[ $p443 -eq 1 ]] && echo -n 443) already in use on this host."
        echo "K3s installs the Traefik ingress controller + ServiceLB by default, which bind 80/443 on EVERY node."
        echo "That would conflict with Nextcloud (or anything else already serving on those ports)."
        if [[ "$keep_ingress" -eq 1 ]]; then
            warn "Proceeding anyway because --keep-ingress was passed. Expect a port conflict on 80/443."
        else
            info "Disabling Traefik + ServiceLB for this install to avoid the conflict (pass --keep-ingress to override)."
            AUTO_DISABLE_INGRESS=1
        fi
    fi
}

forward_policy_is_blocking() {
    have iptables || return 1
    local policy
    policy="$(iptables -S FORWARD 2>/dev/null | awk '/^-P FORWARD/{print $3}' || true)"
    [[ "$policy" == "DROP" || "$policy" == "REJECT" ]]
}

# fix_forward_policy -- Docker (used by Nextcloud AIO and many homelab setups) and
# k3s/flannel both depend on the FORWARD chain allowing traffic. A DROP/REJECT
# default policy is a common, well-documented cause of "it worked until I
# installed the other one" breakage. Only touches the policy if it is actually
# blocking, and only when explicitly asked to fix (doctor --fix), since this is
# a host-wide firewall posture change.
fix_forward_policy() {
    have iptables || return 0
    local policy
    policy="$(iptables -S FORWARD 2>/dev/null | awk '/^-P FORWARD/{print $3}' || true)"
    if [[ "$policy" == "DROP" || "$policy" == "REJECT" ]]; then
        warn "iptables FORWARD policy is ${policy}. This can silently break k3s pod networking and/or Docker container networking (e.g. Nextcloud) on the same host."
        run iptables -I FORWARD -j ACCEPT
        ok "Inserted an ACCEPT rule at the top of FORWARD. (Policy left as ${policy}; only the rule ordering changed.)"
    fi
}

# memory_cgroup_available -- kubelet (inside k3s) requires the memory cgroup
# controller. Some kernels (notably Raspberry Pi OS and other minimal ARM
# images) ship with it disabled by default, which makes k3s/k3s-agent fail
# immediately on start -- the official k3s installer itself warns about this.
memory_cgroup_available() {
    [[ -d /sys/fs/cgroup/memory ]] && return 0
    [[ -r /sys/fs/cgroup/cgroup.controllers ]] && grep -qw memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null && return 0
    return 1
}

# fix_memory_cgroup -- edits the kernel command line to enable it. This only
# takes effect after a reboot, so it deliberately does NOT claim to be an
# immediate fix like the other doctor checks.
fix_memory_cgroup() {
    local params="cgroup_memory=1 cgroup_enable=memory"
    echo "    Current kernel cmdline: $(cat /proc/cmdline 2>/dev/null)"

    if grep -qw 'cgroup_memory=1' /proc/cmdline 2>/dev/null; then
        warn "The running kernel already has cgroup_memory=1 but the controller is still missing -- check for 'cgroup_disable=memory' later on the line, or a kernel built without CONFIG_MEMCG."
        return 1
    fi

    local cmdline_file="" f
    for f in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
        [[ -f "$f" ]] && { cmdline_file="$f"; break; }
    done

    if [[ -n "$cmdline_file" ]]; then
        if grep -q 'cgroup_memory=1' "$cmdline_file" 2>/dev/null; then
            warn "${cmdline_file} already has cgroup_memory=1 -- it just hasn't taken effect yet. Reboot: sudo reboot"
            return 0
        fi
        cp -a "$cmdline_file" "${cmdline_file}.k3s-manager.bak.$(date +%s)" 2>/dev/null || true
        # The Pi bootloader only reads the FIRST line of cmdline.txt.
        run sed -i "1 s/\$/ ${params}/" "$cmdline_file"
        ok "Added '${params}' to ${cmdline_file} (backup saved alongside)."
        echo "    $(c_yellow "A REBOOT is required for this to take effect:") sudo reboot"
        return 0
    fi

    if [[ -f /etc/default/grub ]] && have update-grub; then
        if grep -q 'cgroup_memory=1' /etc/default/grub 2>/dev/null; then
            warn "/etc/default/grub already has cgroup_memory=1 -- run 'sudo update-grub' if you haven't, then reboot."
            return 0
        fi
        cp -a /etc/default/grub "/etc/default/grub.k3s-manager.bak.$(date +%s)" 2>/dev/null || true
        run sed -i "s/^GRUB_CMDLINE_LINUX=\"\(.*\)\"/GRUB_CMDLINE_LINUX=\"\1 ${params}\"/" /etc/default/grub
        run update-grub
        ok "Added '${params}' to GRUB_CMDLINE_LINUX and ran update-grub (backup saved alongside)."
        echo "    $(c_yellow "A REBOOT is required for this to take effect:") sudo reboot"
        return 0
    fi

    warn "Couldn't find /boot/firmware/cmdline.txt, /boot/cmdline.txt, or GRUB to edit automatically."
    echo "    Add '${params}' to your bootloader's kernel command line manually, then reboot."
    return 1
}

# ---------- kubectl wrapper ----------

kctl() {
    [[ -x /usr/local/bin/k3s ]] || die "K3s is not installed."
    [[ -f "$KUBECONFIG_PATH" ]] || die "Kubeconfig not found: $KUBECONFIG_PATH"
    KUBECONFIG="$KUBECONFIG_PATH" /usr/local/bin/k3s kubectl "$@"
}

# kctl_available -- like kctl's preconditions, but returns false instead of
# dying; safe to use inside doctor_check / other non-fatal probes.
kctl_available() {
    [[ -x /usr/local/bin/k3s && -f "$KUBECONFIG_PATH" ]]
}

kctl_quiet() {
    kctl_available || return 1
    KUBECONFIG="$KUBECONFIG_PATH" /usr/local/bin/k3s kubectl "$@" >/dev/null 2>&1
}

wait_for_k3s() {
    local service="${1:-k3s}"
    local tries=0
    local max_tries=60

    while (( tries < max_tries )); do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            return 0
        fi
        sleep 2
        tries=$((tries + 1))
    done

    return 1
}

wait_for_node_ready() {
    local node="${1:-$(hostname)}"
    local tries=0 max_tries=60
    while (( tries < max_tries )); do
        if grep -qw Ready <<<"$(kctl get node "$node" --no-headers 2>/dev/null | awk '{print $2}' || true)"; then
            return 0
        fi
        sleep 3
        tries=$((tries + 1))
    done
    return 1
}

# ---------- preflight connectivity checks ----------

tcp_check() {
    local host="$1" port="$2" timeout="${3:-4}"
    timeout "$timeout" bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" 2>/dev/null
}

# preflight_join SERVER_URL -- checked before a worker/join-master attempts to join
preflight_join() {
    local server="$1"
    local host port

    host="$(sed -E 's#^https?://##; s#[:/].*$##' <<<"$server")"
    port="$(sed -E 's#^https?://[^:]+:?##; s#/.*$##' <<<"$server")"
    [[ "$port" =~ ^[0-9]+$ ]] || port=6443

    info "Preflight: checking reachability of ${host}:${port} ..."

    if ! ping -c1 -W2 "$host" >/dev/null 2>&1; then
        warn "Host ${host} did not respond to ping. Continuing, but this often means:"
        echo "    - the target machine is powered off, or"
        echo "    - the Ethernet cable/interface on one side is down, or"
        echo "    - ICMP is blocked by a firewall (not necessarily fatal for TCP)."
    fi

    if tcp_check "$host" "$port" 5; then
        ok "TCP ${host}:${port} is reachable."
        return 0
    fi

    warn "Cannot reach ${host}:${port} (this reproduces a 'no route to host' / connection-refused style failure)."
    echo "Checklist before retrying:"
    echo "  1. On the SERVER, confirm k3s is running:   sudo systemctl status k3s"
    echo "  2. On the SERVER, confirm the port is listening: sudo ss -tlnp | grep 6443"
    echo "  3. On the SERVER, check the firewall:        sudo $(basename "$SELF_PATH") firewall status"
    echo "  4. On THIS node, confirm the interface is up: ip link show"
    echo "  5. Confirm both sides are on the same subnet and the switch/cable is connected."
    if confirm "Continue anyway?" n; then
        return 0
    fi
    die "Aborting join due to failed connectivity preflight. Fix the above and re-run."
}

# ---------- version / channel resolution ----------

resolve_install_env() {
    # sets INSTALL_ENV_ARGS (array of NAME=VALUE) based on --channel/--version selection
    local channel="${1:-}" version="${2:-}"
    INSTALL_ENV_ARGS=()
    if [[ -n "$version" ]]; then
        INSTALL_ENV_ARGS+=("INSTALL_K3S_VERSION=${version}")
    elif [[ -n "$channel" ]]; then
        INSTALL_ENV_ARGS+=("INSTALL_K3S_CHANNEL=${channel}")
    fi
}

exec_string_from_args() {
    local -n _args="$1"
    local exec_string="" arg
    for arg in "${_args[@]+"${_args[@]}"}"; do
        exec_string+=" $(printf '%q' "$arg")"
    done
    printf '%s\n' "${exec_string# }"
}

run_k3s_installer() {
    # run_k3s_installer ENV_ASSIGNMENTS_ARRAY_NAME
    local -n _env="$1"
    local e
    local -a env_cmd=(env)
    for e in "${_env[@]+"${_env[@]}"}"; do
        env_cmd+=("$e")
    done

    info "Downloading and running the official k3s installer (https://get.k3s.io) ..."
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "$(c_blue "[dry-run]") curl -sfL https://get.k3s.io | ${env_cmd[*]} sh -"
        return 0
    fi

    local tmp
    tmp="$(mktemp)"
    if ! retry 3 10 curl -sfL --connect-timeout 10 https://get.k3s.io -o "$tmp"; then
        rm -f "$tmp"
        die "Could not download the k3s installer after multiple attempts. Check internet connectivity on this node's Wi-Fi/internet interface."
    fi
    chmod +x "$tmp"
    if ! "${env_cmd[@]}" sh "$tmp"; then
        rm -f "$tmp"
        die "The k3s installer exited with an error. See ${LOG_FILE} and 'journalctl -u k3s -xe' / 'journalctl -u k3s-agent -xe'."
    fi
    rm -f "$tmp"
}

# ---------- install: server / worker / join-master ----------

install_server() {
    need_root

    local cluster_init=0 allow_workloads=0 keep_ingress=0
    local token="" iface="" channel="" version="" tls_san_csv="" no_auto_san=0
    local cluster_cidr="" service_cidr="" datastore_endpoint=""
    local -a disable_components=() node_labels=() node_taints=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ha|--cluster-init) cluster_init=1; shift ;;
            --worker|--allow-workloads) allow_workloads=1; shift ;;
            --token) [[ $# -ge 2 ]] || die "--token requires a value."; token="$2"; shift 2 ;;
            --interface) [[ $# -ge 2 ]] || die "--interface requires a value."; iface="$2"; shift 2 ;;
            --channel) [[ $# -ge 2 ]] || die "--channel requires a value."; channel="$2"; shift 2 ;;
            --version) [[ $# -ge 2 ]] || die "--version requires a value."; version="$2"; shift 2 ;;
            --tls-san) [[ $# -ge 2 ]] || die "--tls-san requires a value."; tls_san_csv+="${tls_san_csv:+,}$2"; shift 2 ;;
            --no-auto-tls-san) no_auto_san=1; shift ;;
            --disable) [[ $# -ge 2 ]] || die "--disable requires a component name."; disable_components+=("--disable" "$2"); shift 2 ;;
            --keep-ingress) keep_ingress=1; shift ;;
            --cluster-cidr) [[ $# -ge 2 ]] || die "--cluster-cidr requires a value."; cluster_cidr="$2"; shift 2 ;;
            --service-cidr) [[ $# -ge 2 ]] || die "--service-cidr requires a value."; service_cidr="$2"; shift 2 ;;
            --datastore-endpoint) [[ $# -ge 2 ]] || die "--datastore-endpoint requires a value."; datastore_endpoint="$2"; shift 2 ;;
            --node-label) [[ $# -ge 2 ]] || die "--node-label requires K=V."; node_labels+=("--node-label" "$2"); shift 2 ;;
            --node-taint) [[ $# -ge 2 ]] || die "--node-taint requires K=V:Effect."; node_taints+=("--node-taint" "$2"); shift 2 ;;
            --yes|-y) ASSUME_YES=1; shift ;;
            --) shift; break ;;
            *) die "Unknown 'install master' option: $1" ;;
        esac
    done

    preflight_host_ports "$keep_ingress"
    if [[ "$AUTO_DISABLE_INGRESS" -eq 1 ]]; then
        disable_components+=("--disable" "traefik" "--disable" "servicelb")
    fi

    install_prereqs
    build_network_args "$iface"
    build_tls_san_args "$tls_san_csv" "$(( no_auto_san == 1 ? 0 : 1 ))"

    local -a args=("server")
    [[ "$cluster_init" -eq 1 ]] && args+=("--cluster-init")
    [[ -n "$token" ]] && args+=("--token" "$token")
    [[ "${#NETWORK_ARGS[@]}" -gt 0 ]] && args+=("${NETWORK_ARGS[@]}")
    [[ "${#TLS_SAN_ARGS[@]}" -gt 0 ]] && args+=("${TLS_SAN_ARGS[@]}")
    [[ "${#disable_components[@]}" -gt 0 ]] && args+=("${disable_components[@]}")
    [[ "${#node_labels[@]}" -gt 0 ]] && args+=("${node_labels[@]}")
    [[ "${#node_taints[@]}" -gt 0 ]] && args+=("${node_taints[@]}")
    [[ -n "$cluster_cidr" ]] && args+=("--cluster-cidr" "$cluster_cidr")
    [[ -n "$service_cidr" ]] && args+=("--service-cidr" "$service_cidr")
    [[ -n "$datastore_endpoint" ]] && args+=("--datastore-endpoint" "$datastore_endpoint")

    resolve_install_env "$channel" "$version"
    local exec_string
    exec_string="$(exec_string_from_args args)"

    local -a env_assign=("INSTALL_K3S_EXEC=${exec_string}")
    [[ -n "$token" ]] && env_assign+=("K3S_TOKEN=${token}")
    env_assign+=("${INSTALL_ENV_ARGS[@]+"${INSTALL_ENV_ARGS[@]}"}")

    local node_ip
    if [[ -n "$iface" ]]; then
        node_ip="$(validate_interface "$iface")"
    else
        node_ip="$(best_ip)"
    fi
    [[ -n "$node_ip" ]] || die "Could not determine the server IPv4 address."
    local server_url="https://${node_ip}:6443"

    # Save role/config BEFORE attempting the actual install, so that if the
    # service fails to come up, 'doctor'/'status' on this node still know
    # it's meant to be a server (not a worker) and check k3s accordingly.
    save_config "master" "$iface" "$node_ip" "$server_url" "$channel" "$tls_san_csv"

    info "Installing K3s server (channel=${channel:-default} version=${version:-default})..."
    [[ -x /usr/local/bin/k3s ]] && info "K3s binary already present; installer will reconcile the existing service."

    run_k3s_installer env_assign

    if [[ "$INIT" == "systemd" ]]; then
        run systemctl enable k3s
        run systemctl restart k3s
    fi

    wait_for_k3s k3s || die "k3s.service did not become active. Check: sudo journalctl -u k3s -xe / sudo k3s-manager doctor"

    open_k3s_ports "server"

    if [[ "$allow_workloads" -eq 1 ]]; then
        sleep 5
        local node
        node="$(hostname)"
        kctl taint nodes "$node" \
            node-role.kubernetes.io/control-plane:NoSchedule- \
            node-role.kubernetes.io/master:NoSchedule- \
            2>/dev/null || true
    fi

    if wait_for_node_ready "$(hostname)"; then
        ok "K3s master installed and node is Ready."
    else
        warn "K3s master installed but the node has not reported Ready yet. Run 'sudo $(basename "$SELF_PATH") doctor' if this persists."
    fi
    echo "Primary API URL: ${server_url}"
    echo "Run 'sudo $(basename "$SELF_PATH") token' to get join information."
    echo "Run 'sudo $(basename "$SELF_PATH") kubeconfig' to set up kubectl access."
    if [[ "$AUTO_DISABLE_INGRESS" -eq 1 ]]; then
        echo "Traefik + ServiceLB were disabled to avoid a port 80/443 conflict on this host."
        echo "Re-enable with: sudo $(basename "$SELF_PATH") install master --keep-ingress ... (reruns the installer, safe to repeat)"
    fi
}

install_worker() {
    need_root

    local server="" token="" iface="" channel="" version=""
    local -a node_labels=() node_taints=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --server) [[ $# -ge 2 ]] || die "--server requires a URL."; server="$2"; shift 2 ;;
            --token) [[ $# -ge 2 ]] || die "--token requires a value."; token="$2"; shift 2 ;;
            --interface) [[ $# -ge 2 ]] || die "--interface requires an interface."; iface="$2"; shift 2 ;;
            --channel) [[ $# -ge 2 ]] || die "--channel requires a value."; channel="$2"; shift 2 ;;
            --version) [[ $# -ge 2 ]] || die "--version requires a value (use the server's, e.g. v1.36.4+k3s1)."; version="$2"; shift 2 ;;
            --node-label) [[ $# -ge 2 ]] || die "--node-label requires K=V."; node_labels+=("--node-label" "$2"); shift 2 ;;
            --node-taint) [[ $# -ge 2 ]] || die "--node-taint requires K=V:Effect."; node_taints+=("--node-taint" "$2"); shift 2 ;;
            --yes|-y) ASSUME_YES=1; shift ;;
            *) die "Unknown 'install worker' option: $1" ;;
        esac
    done

    [[ -n "$server" ]] || die "worker requires --server."
    [[ -n "$token" ]] || die "worker requires --token."

    preflight_join "$server"
    install_prereqs

    if [[ -z "$iface" ]]; then
        local server_host
        server_host="$(sed -E 's#^https?://##; s#[:/].*$##' <<<"$server")"
        iface="$(ip -4 route get "$server_host" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
        if [[ -n "$iface" ]]; then
            info "No --interface given; using '${iface}', the interface that routes to ${server_host}."
        fi
    fi
    build_network_args "$iface" "agent"

    local node_ip
    if [[ -n "$iface" ]]; then
        node_ip="$(validate_interface "$iface")"
    else
        node_ip="$(best_ip)"
    fi

    # Save role/config BEFORE attempting the actual join, so that if the
    # service fails to come up, 'doctor'/'status' on this node still know
    # it's meant to be a worker and check k3s-agent (not k3s) accordingly.
    save_config "worker" "$iface" "$node_ip" "$server"

    local -a args=("agent")
    [[ "${#NETWORK_ARGS[@]}" -gt 0 ]] && args+=("${NETWORK_ARGS[@]}")
    [[ "${#node_labels[@]}" -gt 0 ]] && args+=("${node_labels[@]}")
    [[ "${#node_taints[@]}" -gt 0 ]] && args+=("${node_taints[@]}")

    local exec_string
    exec_string="$(exec_string_from_args args)"
    local -a env_assign=("K3S_URL=${server}" "K3S_TOKEN=${token}" "INSTALL_K3S_EXEC=${exec_string}")
    resolve_install_env "$channel" "$version"
    env_assign+=("${INSTALL_ENV_ARGS[@]+"${INSTALL_ENV_ARGS[@]}"}")

    info "Joining worker to ${server} (k3s ${version:-${channel:-stable channel}})..."
    run_k3s_installer env_assign

    if [[ "$INIT" == "systemd" ]]; then
        run systemctl enable k3s-agent
        run systemctl restart k3s-agent
    fi

    wait_for_k3s k3s-agent || die "k3s-agent.service did not become active. Check: sudo journalctl -u k3s-agent -xe / sudo k3s-manager doctor"

    open_k3s_ports "agent"
    ok "Worker installed and joined to ${server}."
}

install_join_master() {
    need_root

    local server="" token="" iface="" tls_san_csv="" no_auto_san=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --server) [[ $# -ge 2 ]] || die "--server requires a URL."; server="$2"; shift 2 ;;
            --token) [[ $# -ge 2 ]] || die "--token requires a value."; token="$2"; shift 2 ;;
            --interface) [[ $# -ge 2 ]] || die "--interface requires an interface."; iface="$2"; shift 2 ;;
            --tls-san) [[ $# -ge 2 ]] || die "--tls-san requires a value."; tls_san_csv+="${tls_san_csv:+,}$2"; shift 2 ;;
            --no-auto-tls-san) no_auto_san=1; shift ;;
            --yes|-y) ASSUME_YES=1; shift ;;
            *) die "Unknown 'install join-master' option: $1" ;;
        esac
    done

    [[ -n "$server" ]] || die "join-master requires --server."
    [[ -n "$token" ]] || die "join-master requires --token."

    preflight_join "$server"
    install_prereqs
    build_network_args "$iface"
    build_tls_san_args "$tls_san_csv" "$(( no_auto_san == 1 ? 0 : 1 ))"

    local -a args=("server" "--server" "$server" "--token" "$token")
    [[ "${#NETWORK_ARGS[@]}" -gt 0 ]] && args+=("${NETWORK_ARGS[@]}")
    [[ "${#TLS_SAN_ARGS[@]}" -gt 0 ]] && args+=("${TLS_SAN_ARGS[@]}")

    local exec_string
    exec_string="$(exec_string_from_args args)"
    local -a env_assign=("INSTALL_K3S_EXEC=${exec_string}" "K3S_TOKEN=${token}")

    local node_ip
    if [[ -n "$iface" ]]; then
        node_ip="$(validate_interface "$iface")"
    else
        node_ip="$(best_ip)"
    fi

    # Save role/config BEFORE attempting the actual join, so that if the
    # service fails to come up, 'doctor'/'status' on this node still know
    # it's meant to be a server (not a worker) and check k3s accordingly.
    save_config "master" "$iface" "$node_ip" "$server" "" "$tls_san_csv"

    info "Joining HA server to ${server}..."
    run_k3s_installer env_assign

    if [[ "$INIT" == "systemd" ]]; then
        run systemctl enable k3s
        run systemctl restart k3s
    fi

    wait_for_k3s k3s || die "k3s.service did not become active. Check: sudo journalctl -u k3s -xe / sudo k3s-manager doctor"

    open_k3s_ports "server"
    ok "HA master joined successfully."
}

# ---------- simple commands ----------

cmd_install() {
    local role="${1:-}"
    shift || true

    case "$role" in
        master) install_server "$@" ;;
        worker|agent) install_worker "$@" ;;
        join-master) install_join_master "$@" ;;
        *) die "Usage: k3s-manager install {master|worker|join-master} [options]" ;;
    esac
}

cmd_token() {
    need_root

    [[ -r "$K3S_TOKEN_FILE" ]] ||
        die "K3s server token not found. This node is not a K3s server."

    local token
    token="$(cat "$K3S_TOKEN_FILE")"

    local default_ip
    default_ip="$(best_ip)"

    echo
    echo "=================================================="
    echo "                 K3S JOIN INFORMATION"
    echo "=================================================="
    echo
    echo "Token:"
    echo "  ${token}"
    echo
    echo "Ready-to-run join commands (one per detected address on this node)."
    echo "If --interface doesn't match the OTHER machine's own NIC name, change"
    echo "it -- check with 'ip -br addr' or 'k3s-manager network-info' there."
    echo

    local name cidr ipaddr note
    while read -r name cidr; do
        [[ -z "$name" ]] && continue
        ipaddr="${cidr%%/*}"
        note=""
        [[ "$ipaddr" == "$default_ip" ]] && note="  (this node's default-routed address -- likely Wi-Fi/LAN, not a dedicated cluster NIC)"
        echo "-- via ${name} (${ipaddr})${note} --"
        echo "  Worker:"
        echo "    sudo k3s-manager install worker --server https://${ipaddr}:6443 --token '${token}' --interface eth0"
        echo "  Additional HA master:"
        echo "    sudo k3s-manager install join-master --server https://${ipaddr}:6443 --token '${token}' --interface eth0"
        echo
    done < <(list_candidate_ifaces)

    if have tailscale; then
        local tsip
        tsip="$(tailscale_ip || true)"
        if [[ -n "$tsip" ]]; then
            echo "-- via tailscale (${tsip}) --"
            echo "  Worker (Tailscale isn't a local NIC to pin --interface to, so it's omitted):"
            echo "    sudo k3s-manager install worker --server https://${tsip}:6443 --token '${token}'"
            echo
        fi
    fi

    echo "Remote provisioning over SSH instead (run from here):"
    echo "  sudo k3s-manager add-node worker --ssh user@<target-ip> --interface eth0"
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
    echo "Updated:    ${K3SMGR_LAST_UPDATED:-unknown}"
    echo

    if [[ -x /usr/local/bin/k3s ]]; then
        echo "K3s binary: $(/usr/local/bin/k3s --version 2>/dev/null | head -n1)"
        echo
    fi

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
            echo
            echo "=== SYSTEM PODS (non-Running) ==="
            kctl get pods -A --field-selector=status.phase!=Running 2>/dev/null | grep -v '^No resources' || echo "(all pods Running)"
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
    need_root; load_os; load_config
    local service="k3s"
    [[ "${K3SMGR_ROLE:-}" == "worker" ]] && service="k3s-agent"
    if [[ "$INIT" == "systemd" ]]; then
        run systemctl enable "$service"
    else
        run rc-update add "$service" default
    fi
    ok "$service enabled at boot."
}

cmd_disable_boot() {
    need_root; load_os; load_config
    local service="k3s"
    [[ "${K3SMGR_ROLE:-}" == "worker" ]] && service="k3s-agent"
    if [[ "$INIT" == "systemd" ]]; then
        run systemctl disable "$service"
    else
        run rc-update del "$service" default || true
    fi
    ok "$service disabled at boot."
}

cmd_restart() {
    need_root; load_os; load_config
    local service="k3s"
    [[ "${K3SMGR_ROLE:-}" == "worker" ]] && service="k3s-agent"
    if [[ "$INIT" == "systemd" ]]; then run systemctl restart "$service"; else run rc-service "$service" restart; fi
    ok "$service restarted."
}

cmd_stop() {
    need_root; load_os; load_config
    local service="k3s"
    [[ "${K3SMGR_ROLE:-}" == "worker" ]] && service="k3s-agent"
    if [[ "$INIT" == "systemd" ]]; then run systemctl stop "$service"; else run rc-service "$service" stop; fi
    ok "$service stopped."
}

cmd_start() {
    need_root; load_os; load_config
    local service="k3s"
    [[ "${K3SMGR_ROLE:-}" == "worker" ]] && service="k3s-agent"
    if [[ "$INIT" == "systemd" ]]; then run systemctl start "$service"; else run rc-service "$service" start; fi
    ok "$service started."
}

cmd_logs() {
    need_root; load_config
    local service="k3s"
    [[ "${K3SMGR_ROLE:-}" == "worker" ]] && service="k3s-agent"
    local lines=200 follow=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --follow|-f) follow=1; shift ;;
            --lines) [[ $# -ge 2 ]] || die "--lines requires a number."; lines="$2"; shift 2 ;;
            *) die "Usage: k3s-manager logs [--follow] [--lines N]" ;;
        esac
    done

    if have journalctl; then
        if [[ "$follow" -eq 1 ]]; then
            journalctl -u "$service" -f
        else
            journalctl -u "$service" -n "$lines" --no-pager
        fi
    else
        tail -n "$lines" "$LOG_FILE"
    fi
}

cmd_upgrade() {
    need_root
    load_config
    local channel="" version=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --channel) [[ $# -ge 2 ]] || die "--channel requires a value."; channel="$2"; shift 2 ;;
            --version) [[ $# -ge 2 ]] || die "--version requires a value."; version="$2"; shift 2 ;;
            *) die "Usage: k3s-manager upgrade [--channel stable|latest|testing] [--version vX.Y.Z+k3sN]" ;;
        esac
    done

    [[ -x /usr/local/bin/k3s ]] || die "K3s is not installed on this node."
    local before
    before="$(/usr/local/bin/k3s --version 2>/dev/null | head -n1 || true)"
    info "Current: ${before}"

    resolve_install_env "$channel" "$version"
    local -a env_assign=("${INSTALL_ENV_ARGS[@]+"${INSTALL_ENV_ARGS[@]}"}")
    if [[ "${#env_assign[@]}" -eq 0 ]]; then
        env_assign=("INSTALL_K3S_CHANNEL=stable")
    fi

    local service="k3s"
    [[ "${K3SMGR_ROLE:-}" == "worker" ]] && service="k3s-agent"

    confirm "Upgrade k3s on this node (service: ${service})?" y || { echo "Aborted."; return 0; }

    run_k3s_installer env_assign

    if [[ "$INIT" == "systemd" ]]; then
        run systemctl restart "$service"
    fi
    wait_for_k3s "$service" || die "Service did not come back up after upgrade. Check: sudo journalctl -u $service -xe"

    local after
    after="$(/usr/local/bin/k3s --version 2>/dev/null | head -n1 || true)"
    ok "Upgraded: ${before}  ->  ${after}"
}

cmd_kubeconfig() {
    need_root
    [[ -f "$KUBECONFIG_PATH" ]] || die "This node has no kubeconfig; it is not a K3s server."

    local target_ip="" target_user="${SUDO_USER:-}" do_merge=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ip) [[ $# -ge 2 ]] || die "--ip requires a value."; target_ip="$2"; shift 2 ;;
            --user) [[ $# -ge 2 ]] || die "--user requires a value."; target_user="$2"; shift 2 ;;
            --merge) do_merge=1; shift ;;
            *) die "Usage: k3s-manager kubeconfig [--ip IP] [--user USER] [--merge]" ;;
        esac
    done

    [[ -n "$target_ip" ]] || target_ip="$(tailscale_ip || best_ip)"
    [[ -n "$target_ip" ]] || die "Could not determine an IP to embed in the kubeconfig; pass --ip explicitly."

    local out="/tmp/k3s.yaml.$$"
    sed "s#https://127.0.0.1:6443#https://${target_ip}:6443#" "$KUBECONFIG_PATH" > "$out"
    chmod 600 "$out"

    if [[ -n "$target_user" && "$target_user" != "root" ]]; then
        local home_dir
        home_dir="$(getent passwd "$target_user" | cut -d: -f6 || true)"
        [[ -n "$home_dir" ]] || die "Could not resolve home directory for user '$target_user'."
        install -d -m 0700 -o "$target_user" -g "$target_user" "${home_dir}/.kube"
        local dest="${home_dir}/.kube/config"
        if [[ "$do_merge" -eq 1 && -f "$dest" ]]; then
            KUBECONFIG="${dest}:${out}" /usr/local/bin/k3s kubectl config view --flatten > "${dest}.new"
            mv "${dest}.new" "$dest"
        else
            cp "$out" "$dest"
        fi
        chown "$target_user:$target_user" "$dest"
        chmod 600 "$dest"
        rm -f "$out"
        ok "Kubeconfig written to ${dest} (server: https://${target_ip}:6443)"
    else
        echo "$out"
        echo "Kubeconfig written to ${out} (server: https://${target_ip}:6443)"
        echo "Copy it to your workstation, e.g.:"
        echo "  scp $(hostname -I 2>/dev/null | awk '{print $1}'):${out} ~/.kube/config"
    fi
    echo
    echo "Tip: use --ip $(tailscale_ip 2>/dev/null || echo '<tailscale-ip>') to generate a kubeconfig that works over Tailscale from anywhere."
}

# ---------- multi-node orchestration ----------

ssh_preflight() {
    local target="$1"
    local host="${target##*@}"

    info "Preflight: checking SSH reachability of ${host}..."
    if ! ping -c1 -W2 "$host" >/dev/null 2>&1; then
        warn "No ping reply from ${host}. It may be powered off or on a different network segment."
    fi
    if ! tcp_check "$host" 22 5; then
        warn "Cannot reach ${host}:22 ('no route to host' / connection refused)."
        echo "Before retrying, on the TARGET machine check:"
        echo "  - sshd is running:      sudo systemctl status ssh"
        echo "  - firewall allows 22:   sudo ufw status  /  sudo firewall-cmd --list-all"
        echo "  - the interface is up:  ip -br addr"
        echo "  - routing/subnet match: ip route"
        if ! confirm "Attempt the SSH connection anyway?" n; then
            die "Aborted add-node for ${target}."
        fi
    else
        ok "TCP ${host}:22 is reachable."
    fi
}

cmd_add_node() {
    need_root
    load_config

    local kind="${1:-}"
    shift || true

    local ssh_target="" iface="" version=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ssh) [[ $# -ge 2 ]] || die "--ssh requires user@host."; ssh_target="$2"; shift 2 ;;
            --interface) [[ $# -ge 2 ]] || die "--interface requires an interface."; iface="$2"; shift 2 ;;
            --version) [[ $# -ge 2 ]] || die "--version requires a value."; version="$2"; shift 2 ;;
            *) die "Unknown add-node option: $1" ;;
        esac
    done

    local role_cmd
    case "$kind" in
        worker) role_cmd="install worker" ;;
        master) role_cmd="install join-master" ;;
        *) die "Usage: k3s-manager add-node {worker|master} [--ssh user@host] [--interface IFACE] [--version V]" ;;
    esac

    [[ -r "$K3S_TOKEN_FILE" ]] ||
        die "This command must be run on a K3s server."

    # Use the address this server was installed on (its --interface IP), not the
    # default-routed one -- on multi-homed nodes the default route is usually Wi-Fi.
    local master_ip="${K3SMGR_NODE_IP:-}"
    if [[ -z "$master_ip" ]] && kctl_available; then
        master_ip="$(kctl get node "$(hostname)" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
    fi
    [[ -n "$master_ip" ]] || master_ip="$(best_ip)"
    info "Workers will join via https://${master_ip}:6443"
    [[ -n "$master_ip" ]] || die "Could not determine master IP."

    # A node must never run a newer k3s than the server, so default to ours.
    if [[ -z "$version" ]]; then
        version="$(/usr/local/bin/k3s --version 2>/dev/null | awk '/k3s version/{print $3; exit}' || true)"
    fi

    local token
    token="$(cat "$K3S_TOKEN_FILE")"
    local server="https://${master_ip}:6443"

    # --interface is optional: 'install worker' picks whichever NIC routes to the server.
    local -a args=(--server "$server" --token "$token")
    [[ -n "$iface" ]] && args+=(--interface "$iface")
    [[ -n "$version" && "$kind" == "worker" ]] && args+=(--version "$version")

    local remote_args="" a
    for a in "${args[@]}"; do
        remote_args+=" $(printf '%q' "$a")"
    done

    if [[ -z "$ssh_target" ]]; then
        echo "Copy this script to the target node (e.g. scp $(printf '%q' "$SELF_PATH") user@host:/tmp/k3s-manager.sh), then run there:"
        echo
        echo "  sudo install -m 755 /tmp/k3s-manager.sh /usr/local/bin/k3s-manager && sudo k3s-manager ${role_cmd}${remote_args}"
        echo
        echo "...or re-run with --ssh user@host to have k3s-manager do all of that for you."
        return 0
    fi

    ssh_preflight "$ssh_target"

    # One shared connection: the target's SSH password is asked for once and
    # reused for the copy and the install.
    local -a sshopts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10
                      -o ControlMaster=auto -o "ControlPath=/tmp/k3smgr-add-%C" -o ControlPersist=300)

    info "Connecting to ${ssh_target} (enter its SSH password if asked)..."
    ssh "${sshopts[@]}" -fN "$ssh_target" || die "Could not connect to ${ssh_target}."

    info "Copying k3s-manager ${VERSION} to ${ssh_target}..."
    scp "${sshopts[@]}" -q "$SELF_PATH" "${ssh_target}:/tmp/k3s-manager.sh" ||
        die "Could not copy k3s-manager to ${ssh_target}."

    local remote_cmd="sudo install -m 755 /tmp/k3s-manager.sh /usr/local/bin/k3s-manager && sudo /usr/local/bin/k3s-manager -y ${role_cmd}${remote_args}; rc=\$?; rm -f /tmp/k3s-manager.sh; exit \$rc"

    info "Running '${role_cmd}' on ${ssh_target} (enter its sudo password if asked)..."
    local rc=0
    ssh "${sshopts[@]}" -t "$ssh_target" "$remote_cmd" || rc=$?
    ssh "${sshopts[@]}" -O exit "$ssh_target" >/dev/null 2>&1 || true

    if [[ "$rc" -eq 0 ]]; then
        ok "${ssh_target} joined the cluster as a ${kind}."
    else
        die "Remote install on ${ssh_target} failed (exit ${rc}). Run 'sudo k3s-manager doctor' on that node."
    fi
}

cmd_remove_node() {
    need_root

    local node="" purge=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --purge) purge=1; shift ;;
            *) [[ -z "$node" ]] && { node="$1"; shift; } || die "Unexpected argument: $1" ;;
        esac
    done
    [[ -n "$node" ]] || die "Usage: k3s-manager remove-node NODE [--purge]"

    kctl drain "$node" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --force \
        --timeout=120s || warn "Drain reported issues; continuing."

    kctl delete node "$node" || warn "Node object deletion reported issues."

    if [[ "$purge" -eq 1 ]]; then
        warn "--purge only removes the node object from the cluster."
        echo "To fully uninstall k3s FROM the removed node itself, run on that node:"
        echo "  sudo $(basename "$SELF_PATH") uninstall"
    fi

    ok "Node removed: $node"
}

cmd_uninstall() {
    need_root
    load_config

    confirm "This will completely remove k3s and k3s-manager configuration from THIS node. Continue?" n || {
        echo "Aborted."
        return 0
    }

    if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
        /usr/local/bin/k3s-uninstall.sh
    elif [[ -x /usr/local/bin/k3s-agent-uninstall.sh ]]; then
        /usr/local/bin/k3s-agent-uninstall.sh
    else
        warn "No K3s uninstall script found; k3s may already be removed. Cleaning up k3s-manager state only."
    fi

    systemctl disable --now k3s-manager-watchdog.timer 2>/dev/null || true
    rm -f /etc/systemd/system/k3s-manager-watchdog.timer /etc/systemd/system/k3s-manager-watchdog.service /usr/local/bin/k3s-manager-watchdog.sh
    systemctl daemon-reload 2>/dev/null || true
    rm -rf /var/lib/k3s-manager
    rm -f /etc/modules-load.d/k3s-manager.conf /etc/sysctl.d/90-k3s-manager.conf
    rm -rf "$CONFIG_DIR"

    ok "K3s and k3s-manager configuration removed from this node."
}

# ---------- backup / restore ----------

cmd_snapshot() {
    need_root
    local action="${1:-}"
    shift || true

    [[ -x /usr/local/bin/k3s ]] || die "K3s is not installed on this node."

    case "$action" in
        save)
            local name
            name="k3s-snapshot-$(date +%Y%m%d-%H%M%S)"
            if /usr/local/bin/k3s etcd-snapshot save --name "$name" 2>/tmp/k3s-snap-err.$$; then
                ok "etcd snapshot saved: $name (see /var/lib/rancher/k3s/server/db/snapshots/)"
            else
                if grep -qi "etcd is not running" /tmp/k3s-snap-err.$$ 2>/dev/null; then
                    warn "This server uses the default SQLite datastore (not etcd/HA), so 'etcd-snapshot' does not apply."
                    local dest
                    dest="/var/backups/k3s-sqlite-$(date +%Y%m%d-%H%M%S).tar.gz"
                    install -d -m 0700 /var/backups
                    tar czf "$dest" -C /var/lib/rancher/k3s/server db 2>/dev/null && \
                        ok "SQLite datastore backed up to ${dest}" || die "Backup failed."
                else
                    cat /tmp/k3s-snap-err.$$ >&2
                    die "etcd-snapshot save failed."
                fi
            fi
            rm -f /tmp/k3s-snap-err.$$
            ;;
        list)
            /usr/local/bin/k3s etcd-snapshot ls 2>/dev/null || {
                echo "No etcd snapshots (SQLite datastore). SQLite backups (if any):"
                ls -lh /var/backups/k3s-sqlite-*.tar.gz 2>/dev/null || echo "(none found)"
            }
            ;;
        restore)
            local snap="${1:-}"
            [[ -n "$snap" ]] || die "Usage: k3s-manager snapshot restore SNAPSHOT_NAME_OR_PATH"
            warn "Restoring a snapshot stops k3s and rewrites cluster state. This is destructive."
            confirm "Continue with restore from '${snap}'?" n || { echo "Aborted."; return 0; }
            run systemctl stop k3s
            if [[ -f "$snap" ]]; then
                run /usr/local/bin/k3s server --cluster-reset --cluster-reset-restore-path="$snap"
            else
                run /usr/local/bin/k3s server --cluster-reset --etcd-s3=false --cluster-reset-restore-path="$(dirname "$K3S_TOKEN_FILE")/db/snapshots/${snap}"
            fi
            run systemctl start k3s
            wait_for_k3s k3s && ok "Restore complete; k3s restarted." || die "k3s did not come back up after restore."
            ;;
        *)
            die "Usage: k3s-manager snapshot {save|list|restore SNAPSHOT}"
            ;;
    esac
}

# ---------- doctor: diagnose + optional auto-fix ----------

DOCTOR_ISSUES=0
DOCTOR_FIX=0

doctor_check() {
    local desc="$1" ok_cond="$2" fix_cmd="${3:-}"
    printf '%-60s' "  ${desc}..."
    if eval "$ok_cond"; then
        echo "$(c_green OK)"
        return 0
    fi
    echo "$(c_red "ISSUE")"
    DOCTOR_ISSUES=$((DOCTOR_ISSUES + 1))
    if [[ -n "$fix_cmd" ]]; then
        if [[ "$DOCTOR_FIX" -eq 1 ]]; then
            echo "    Fixing: $fix_cmd"
            if eval "$fix_cmd"; then
                ok "    Fixed."
            else
                warn "    Fix attempt failed; manual intervention needed."
            fi
        else
            echo "    Suggested fix: $fix_cmd"
            echo "    (re-run with 'doctor --fix' to apply automatically)"
        fi
    fi
    # Issues are tallied in DOCTOR_ISSUES; returning non-zero here would make
    # `set -e` abort doctor at the first problem it finds.
    return 0
}

cmd_doctor() {
    need_root
    load_os
    load_config

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fix) DOCTOR_FIX=1; shift ;;
            *) die "Usage: k3s-manager doctor [--fix]" ;;
        esac
    done

    local service="k3s"
    [[ "${K3SMGR_ROLE:-}" == "worker" ]] && service="k3s-agent"

    echo "=== K3S-MANAGER DOCTOR (role: ${K3SMGR_ROLE:-unknown}, fix: $([[ $DOCTOR_FIX -eq 1 ]] && echo on || echo off)) ==="
    echo

    echo "-- Binaries & services --"
    doctor_check "k3s binary installed" '[[ -x /usr/local/bin/k3s ]]'
    doctor_check "${service}.service enabled" "systemctl is-enabled --quiet ${service} 2>/dev/null" "systemctl enable ${service}"
    doctor_check "${service}.service active" "systemctl is-active --quiet ${service} 2>/dev/null" "systemctl restart ${service} && sleep 5"

    echo
    echo "-- Host requirements --"
    if [[ -n "$(swapon --noheadings 2>/dev/null || true)" ]]; then
        printf '%-60s%s\n' "  swap..." "on (fine -- k3s runs kubelet with fail-swap-on=false)"
    fi
    doctor_check "br_netfilter loaded" 'grep -q "^br_netfilter " <<<"$(lsmod 2>/dev/null || true)"' "modprobe br_netfilter"
    doctor_check "overlay loaded" 'grep -q "^overlay " <<<"$(lsmod 2>/dev/null || true)"' "modprobe overlay"
    doctor_check "ip_forward enabled" '[[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" == "1" ]]' "sysctl -w net.ipv4.ip_forward=1"
    doctor_check "time sync service active" 'systemctl is-active --quiet systemd-timesyncd 2>/dev/null || systemctl is-active --quiet chronyd 2>/dev/null || systemctl is-active --quiet chrony 2>/dev/null || systemctl is-active --quiet ntpd 2>/dev/null'
    doctor_check "/var free space > 1GiB" '[[ $(df --output=avail -B1 /var 2>/dev/null | tail -1) -gt 1073741824 ]]'

    printf '%-60s' "  memory cgroup controller available..."
    if memory_cgroup_available; then
        echo "$(c_green OK)"
    else
        echo "$(c_red "ISSUE")"
        DOCTOR_ISSUES=$((DOCTOR_ISSUES + 1))
        warn "kubelet (inside k3s) requires the memory cgroup controller; without it, k3s/k3s-agent typically fails immediately on start ('control process exited with error code')."
        if [[ "$DOCTOR_FIX" -eq 1 ]]; then
            fix_memory_cgroup || true
        else
            echo "    Re-run with 'doctor --fix' to have the kernel cmdline edited automatically (a reboot will still be required afterward)."
        fi
    fi

    echo
    echo "-- Networking --"
    if [[ -n "${K3SMGR_INTERFACE:-}" ]]; then
        doctor_check "interface ${K3SMGR_INTERFACE} exists" "iface_exists '${K3SMGR_INTERFACE}'"
        doctor_check "interface ${K3SMGR_INTERFACE} is up" "[[ \"\$(iface_state '${K3SMGR_INTERFACE}')\" == up ]]" "ip link set dev '${K3SMGR_INTERFACE}' up"
        doctor_check "interface ${K3SMGR_INTERFACE} has an IPv4" "[[ -n \"\$(iface_ip '${K3SMGR_INTERFACE}')\" ]]"
    fi
    local fw
    fw="$(detect_firewall)"
    echo "  Firewall backend: ${fw}"
    if [[ "$fw" != "none" ]]; then
        doctor_check "port 6443 reachable locally" "tcp_check 127.0.0.1 6443 3 || [[ '${K3SMGR_ROLE:-}' == worker ]]" "$(basename "$SELF_PATH") firewall open"
    fi
    doctor_check "iptables FORWARD policy not DROP/REJECT" '! forward_policy_is_blocking' "fix_forward_policy"

    echo
    echo "-- Coexistence --"
    local nc_how
    nc_how="$(detect_nextcloud || true)"
    if [[ -n "$nc_how" ]]; then
        echo "  Nextcloud detected: ${nc_how}"
        if kctl_available; then
            doctor_check "no Traefik/ServiceLB port clash (80/443)" \
                '! ( (port_in_use 80 || port_in_use 443) && kctl_quiet get svc -n kube-system traefik ) ' \
                "kctl delete svc traefik -n kube-system 2>/dev/null; kctl scale deploy/traefik -n kube-system --replicas=0 2>/dev/null"
        fi
    else
        echo "  Nextcloud: not detected on this host"
    fi

    if [[ "${K3SMGR_ROLE:-}" == "worker" && -n "${K3SMGR_SERVER_URL:-}" ]]; then
        local host
        host="$(sed -E 's#^https?://##; s#[:/].*$##' <<<"${K3SMGR_SERVER_URL}")"
        doctor_check "server ${host}:6443 reachable" "tcp_check '${host}' 6443 4"
    fi

    if [[ -x /usr/local/bin/k3s && -f "$KUBECONFIG_PATH" && "${K3SMGR_ROLE:-}" != "worker" ]]; then
        echo
        echo "-- Cluster state --"
        doctor_check "API server responds" "kctl get --raw=/healthz >/dev/null 2>&1"
        doctor_check "this node is Ready" "grep -qw Ready <<<\"\$(kctl get node \"\$(hostname)\" --no-headers 2>/dev/null | awk '{print \$2}' || true)\""
        local notready
        notready="$(kctl get nodes --no-headers 2>/dev/null | awk '$2 !~ /Ready/{print $1}' || true)"
        if [[ -n "$notready" ]]; then
            warn "Nodes NOT Ready: ${notready}"
        fi
        local badpods
        badpods="$(kctl get pods -A --no-headers 2>/dev/null | awk '$4 !~ /Running|Completed/{print}' | head -n5 || true)"
        if [[ -n "$badpods" ]]; then
            warn "Pods not Running/Completed (top 5):"
            echo "$badpods"
        fi
    fi

    echo
    if [[ "$DOCTOR_ISSUES" -eq 0 ]]; then
        ok "No issues found."
    else
        echo "$(c_yellow "Found ${DOCTOR_ISSUES} issue(s).")"
        if [[ "$DOCTOR_FIX" -eq 0 ]]; then
            echo "Re-run: sudo $(basename "$SELF_PATH") doctor --fix"
        fi
    fi
    return 0
}

# ---------- watchdog (failover monitor) ----------

cmd_watchdog_install() {
    need_root
    load_os

    local master="" interval=15 threshold=8

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --master) [[ $# -ge 2 ]] || die "--master requires an IP/hostname."; master="$2"; shift 2 ;;
            --check-interval) [[ $# -ge 2 ]] || die "--check-interval requires seconds."; interval="$2"; shift 2 ;;
            --fail-threshold) [[ $# -ge 2 ]] || die "--fail-threshold requires a number."; threshold="$2"; shift 2 ;;
            *) die "Unknown watchdog option: $1" ;;
        esac
    done

    [[ -n "$master" ]] || die "--master is required."

    install -d -m 0755 "$CONFIG_DIR"

    cat > "$CONFIG_FILE.watchdog" <<CFG
K3SMGR_WATCHDOG_MASTER=$(printf '%q' "$master")
K3SMGR_WATCHDOG_INTERVAL=$(printf '%q' "$interval")
K3SMGR_WATCHDOG_THRESHOLD=$(printf '%q' "$threshold")
CFG
    cat "$CONFIG_FILE.watchdog" >> "$CONFIG_FILE" 2>/dev/null || cp "$CONFIG_FILE.watchdog" "$CONFIG_FILE"
    rm -f "$CONFIG_FILE.watchdog"
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

    ok "Watchdog installed. Master: ${master}  Interval: ${interval}s  Threshold: ${threshold}"
}

cmd_watchdog_uninstall() {
    need_root
    systemctl disable --now k3s-manager-watchdog.timer 2>/dev/null || true
    rm -f /etc/systemd/system/k3s-manager-watchdog.timer /etc/systemd/system/k3s-manager-watchdog.service /usr/local/bin/k3s-manager-watchdog.sh
    systemctl daemon-reload
    rm -rf /var/lib/k3s-manager
    ok "Watchdog removed."
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

# ---------- self-update (updates the k3s-manager tool itself) ----------

# version_compare A B -- prints 1 if A>B, -1 if A<B, 0 if equal (dotted numeric versions)
version_compare() {
    local a="$1" b="$2"
    [[ "$a" == "$b" ]] && { echo 0; return; }

    local -a va vb
    IFS=. read -ra va <<<"$a"
    IFS=. read -ra vb <<<"$b"
    local i na nb
    for ((i = 0; i < 4; i++)); do
        na="${va[i]:-0}"; na="${na//[^0-9]/}"; na="${na:-0}"
        nb="${vb[i]:-0}"; nb="${nb//[^0-9]/}"; nb="${nb:-0}"
        if (( 10#$na > 10#$nb )); then echo 1; return; fi
        if (( 10#$na < 10#$nb )); then echo -1; return; fi
    done
    echo 0
}

find_git_root_of_self() {
    local dir
    dir="$(cd "$(dirname "$SELF_PATH")" && pwd)"
    if have git && git -C "$dir" rev-parse --show-toplevel >/dev/null 2>&1; then
        git -C "$dir" rev-parse --show-toplevel
    fi
}

need_root_if_owned_by_root() {
    local path="$1"
    if [[ "$(stat -c '%U' "$path" 2>/dev/null || stat -f '%Su' "$path" 2>/dev/null)" == "root" ]]; then
        need_root
    fi
}

cmd_update() {
    local check_only=0 ref="main" force=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check) check_only=1; shift ;;
            --ref) [[ $# -ge 2 ]] || die "--ref requires a branch/tag name."; ref="$2"; shift 2 ;;
            --force) force=1; shift ;;
            *) die "Usage: k3s-manager update [--check] [--ref BRANCH] [--force]" ;;
        esac
    done

    info "Current version: ${VERSION}"
    info "Script location:  ${SELF_PATH}"

    local git_root
    git_root="$(find_git_root_of_self || true)"

    if [[ -n "$git_root" ]]; then
        info "Detected a git checkout at ${git_root}; using 'git pull' to update."
        [[ "$check_only" -eq 1 ]] && { git -C "$git_root" fetch --quiet origin "$ref" 2>/dev/null || true; git -C "$git_root" log --oneline "HEAD..origin/${ref}" 2>/dev/null || echo "(up to date, or unable to compare)"; return 0; }
        need_root_if_owned_by_root "$git_root"
        run git -C "$git_root" fetch --quiet origin "$ref"
        run git -C "$git_root" checkout "$ref"
        run git -C "$git_root" pull --quiet origin "$ref"
        ok "Updated via git. New version: $(grep -m1 '^VERSION=' "${git_root}/k3s-manager.sh" 2>/dev/null || echo unknown)"
        return 0
    fi

    local url="$REPO_RAW_URL"
    if [[ "$ref" != "main" ]]; then
        url="${url/\/main\//\/${ref}\/}"
    fi

    info "Checking ${url} ..."
    local tmp
    tmp="$(mktemp)"
    if ! retry 3 5 curl -sfL --connect-timeout 10 "$url" -o "$tmp"; then
        rm -f "$tmp"
        die "Could not download the latest k3s-manager from GitHub. Check internet connectivity."
    fi

    if ! bash -n "$tmp" 2>/tmp/k3s-manager-update-syntax.$$; then
        echo "$(c_red "Downloaded script failed a syntax check:")"
        cat /tmp/k3s-manager-update-syntax.$$ >&2
        rm -f "$tmp" /tmp/k3s-manager-update-syntax.$$
        die "Aborting self-update; the remote file may be corrupt or incompatible."
    fi
    rm -f /tmp/k3s-manager-update-syntax.$$

    local remote_version
    remote_version="$(grep -m1 -E '^VERSION="' "$tmp" | cut -d'"' -f2 || true)"
    [[ -n "$remote_version" ]] || { rm -f "$tmp"; die "Could not determine the remote version; aborting."; }

    echo "Installed version: ${VERSION}"
    echo "Remote version:    ${remote_version}"

    local cmp
    cmp="$(version_compare "$remote_version" "$VERSION")"

    if [[ "$cmp" -eq 0 && "$force" -eq 0 ]]; then
        rm -f "$tmp"
        ok "Already up to date."
        return 0
    fi

    if [[ "$cmp" -lt 0 && "$force" -eq 0 ]]; then
        rm -f "$tmp"
        if [[ "$check_only" -eq 1 ]]; then
            ok "Installed version (${VERSION}) is newer than the published version (${remote_version}); nothing to do."
        else
            warn "Remote version (${remote_version}) is older than the installed version (${VERSION}); not downgrading."
            echo "Pass --force if you really want to install it anyway (e.g. to roll back)."
        fi
        return 0
    fi

    if [[ "$check_only" -eq 1 ]]; then
        rm -f "$tmp"
        if [[ "$cmp" -gt 0 ]]; then
            echo "$(c_yellow "An update is available.") Run: sudo $(basename "$SELF_PATH") update"
        else
            ok "Already up to date."
        fi
        return 0
    fi

    need_root
    confirm "Install version ${remote_version} over ${VERSION} at ${SELF_PATH}?" y || { rm -f "$tmp"; echo "Aborted."; return 0; }

    local backup
    backup="${SELF_PATH}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$SELF_PATH" "$backup" 2>/dev/null || warn "Could not create a backup at ${backup}."
    chmod +x "$tmp"
    if run cp "$tmp" "$SELF_PATH"; then
        rm -f "$tmp"
        ok "Updated ${SELF_PATH}: ${VERSION} -> ${remote_version}"
        echo "Previous version backed up at: ${backup}"
    else
        rm -f "$tmp"
        die "Failed to install the update. Your original script is unchanged (backup at ${backup})."
    fi
}

# ---------- system info ----------

cmd_sysinfo() {
    detect_os_auto

    local arch cpus mem_kb mem_gb gpu="none detected"
    arch="$(uname -m)"
    cpus="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo unknown)"
    mem_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || true)"
    if [[ -n "$mem_kb" ]]; then
        mem_gb="$(awk -v k="$mem_kb" 'BEGIN{printf "%.1f", k/1024/1024}')"
    else
        mem_gb="unknown"
    fi

    if have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then
        gpu="NVIDIA -- $(nvidia-smi -L 2>/dev/null | head -n1 || true)"
    elif have lspci && grep -qi nvidia <<<"$(lspci 2>/dev/null || true)"; then
        gpu="NVIDIA GPU present, but nvidia-smi/driver not found (CPU-only until drivers are installed)"
    elif have lspci && grep -Eqi 'vga.*amd|display.*amd|3d.*amd' <<<"$(lspci 2>/dev/null || true)"; then
        gpu="AMD GPU present (ROCm support varies by model; CPU fallback otherwise)"
    fi

    echo "=== SYSTEM INFO ==="
    echo "Hostname:        $(hostname)"
    echo "OS:              ${OS_ID:-unknown} ${OS_VERSION:-} (${PKG:-unknown package manager})"
    echo "Kernel:          $(uname -r)"
    echo "Architecture:    ${arch}"
    echo "CPU cores:       ${cpus}"
    echo "Memory (total):  ${mem_gb} GiB"
    echo "GPU:             ${gpu}"
    echo "Disk free (/):   $(df -h / 2>/dev/null | awk 'NR==2{print $4}')"
    if have tailscale; then
        echo "Tailscale IP:    $(tailscale_ip 2>/dev/null || echo 'not connected')"
    fi
    echo
    if ai_arch_supported; then
        ok "This architecture is supported by the 'ai' commands (Ollama)."
    else
        warn "Architecture '${arch}' is not officially supported by Ollama; 'ai install'/'ai deploy' may not work."
    fi
}

# ---------- AI distribution (Ollama across the cluster) ----------
#
# Two independent modes, both built on Ollama (broad Linux/x86_64/arm64
# support, simple HTTP API, no GPU required):
#
#   ai install / ai uninstall  -- a single node's local Ollama (systemd service)
#   ai deploy  / ai undeploy   -- Ollama as a Kubernetes DaemonSet, one pod per
#                                 labeled node, behind a single Service. Requests
#                                 to that Service are load-balanced by kube-proxy
#                                 across whichever nodes are running a pod, i.e.
#                                 concurrent inference requests get spread across
#                                 your physical machines. This is horizontal
#                                 (request-level) distribution -- each node keeps
#                                 its own full copy of whatever models it has
#                                 pulled. It does NOT shard a single model's
#                                 layers across machines (that is a much harder,
#                                 more experimental problem); `ai model install`
#                                 pulls a model onto every node so any of them
#                                 can serve it directly.

ai_arch_supported() {
    case "$(uname -m)" in
        x86_64|amd64|aarch64|arm64) return 0 ;;
        *) return 1 ;;
    esac
}

open_ai_ports() {
    local fw
    fw="$(detect_firewall)"
    case "$fw" in
        none) vlog "No active firewall detected; skipping AI port rule." ;;
        ufw) run ufw allow "${OLLAMA_PORT}/tcp" comment 'ollama API' || true ;;
        firewalld)
            run firewall-cmd --permanent --add-port="${OLLAMA_PORT}/tcp" || true
            run firewall-cmd --reload || true
            ;;
        nftables|iptables)
            warn "Detected ${fw}; open ${OLLAMA_PORT}/tcp manually if you want remote access to Ollama."
            ;;
    esac
}

ai_install() {
    need_root
    load_os

    local force=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=1; shift ;;
            --yes|-y) ASSUME_YES=1; shift ;;
            *) die "Usage: k3s-manager ai install [--force]" ;;
        esac
    done

    if ! ai_arch_supported; then
        warn "Architecture '$(uname -m)' is not officially supported by Ollama."
        confirm "Attempt the install anyway?" n || die "Aborted."
    fi

    if have ollama && [[ "$force" -eq 0 ]]; then
        ok "Ollama already installed ($(ollama --version 2>/dev/null | head -n1))."
    else
        info "Installing Ollama (official installer, sets up its own systemd service)..."
        local tmp
        tmp="$(mktemp)"
        if ! retry 3 10 curl -fsSL --connect-timeout 10 https://ollama.com/install.sh -o "$tmp"; then
            rm -f "$tmp"
            die "Could not download the Ollama installer. Check internet connectivity on this node's Wi-Fi/internet interface."
        fi
        if [[ "$DRY_RUN" -eq 1 ]]; then
            echo "$(c_blue "[dry-run]") sh $tmp   (Ollama official installer)"
        else
            sh "$tmp" || { rm -f "$tmp"; die "The Ollama installer failed. See the output above."; }
        fi
        rm -f "$tmp"
    fi

    if [[ "$INIT" == "systemd" ]]; then
        run systemctl enable --now ollama 2>/dev/null || warn "Could not enable/start the ollama service; it may need manual setup."
    fi

    open_ai_ports

    if have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then
        ok "NVIDIA GPU detected -- Ollama will use it automatically."
    else
        info "No NVIDIA GPU detected; Ollama will run on CPU (fine for small/quantized models)."
    fi

    ok "Ollama installed. API on 127.0.0.1:${OLLAMA_PORT} (and externally, if a firewall rule was opened above)."
    echo "Pull a model:  sudo $(basename "$SELF_PATH") ai model install llama3.2"
    echo "For cluster-wide distribution across all your machines instead, run 'ai deploy' on the control-plane."
}

ai_uninstall() {
    need_root

    local purge_models=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --purge-models) purge_models=1; shift ;;
            *) die "Usage: k3s-manager ai uninstall [--purge-models]" ;;
        esac
    done

    confirm "Remove the local Ollama installation from this node?" n || { echo "Aborted."; return 0; }

    run systemctl disable --now ollama 2>/dev/null || true
    rm -f /etc/systemd/system/ollama.service
    systemctl daemon-reload 2>/dev/null || true
    rm -f /usr/local/bin/ollama /usr/bin/ollama 2>/dev/null || true

    if [[ "$purge_models" -eq 1 ]]; then
        rm -rf /usr/share/ollama/.ollama "${HOME}/.ollama" /root/.ollama 2>/dev/null || true
        ok "Removed downloaded models."
    else
        echo "Downloaded models were left in place (typically /usr/share/ollama/.ollama). Pass --purge-models to remove them too."
    fi

    getent passwd ollama >/dev/null 2>&1 && { run userdel ollama 2>/dev/null || true; }

    ok "Ollama removed from this node."
}

ai_deploy() {
    need_root
    kctl_available || die "This must be run on a K3s server (control-plane) node with a working kubeconfig."

    local -a only=() exclude=()
    local min_mem_gb=0 memory_limit="" nodeport="" image="ollama/ollama:latest"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --only) [[ $# -ge 2 ]] || die "--only requires a node name."; only+=("$2"); shift 2 ;;
            --exclude) [[ $# -ge 2 ]] || die "--exclude requires a node name."; exclude+=("$2"); shift 2 ;;
            --min-memory-gb) [[ $# -ge 2 ]] || die "--min-memory-gb requires a number."; min_mem_gb="$2"; shift 2 ;;
            --memory-limit) [[ $# -ge 2 ]] || die "--memory-limit requires a value (e.g. 6Gi)."; memory_limit="$2"; shift 2 ;;
            --nodeport) [[ $# -ge 2 ]] || die "--nodeport requires a port number."; nodeport="$2"; shift 2 ;;
            --image) [[ $# -ge 2 ]] || die "--image requires a value."; image="$2"; shift 2 ;;
            --yes|-y) ASSUME_YES=1; shift ;;
            *) die "Unknown 'ai deploy' option: $1" ;;
        esac
    done

    info "Selecting nodes for AI workloads..."

    local -a candidates=()
    local name
    while read -r name; do
        [[ -n "$name" ]] && candidates+=("$name")
    done < <(kctl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
    [[ "${#candidates[@]}" -gt 0 ]] || die "No cluster nodes found. Is k3s running?"

    local -a selected=()
    local arch mem_ki mem_gb skip o e
    for name in "${candidates[@]}"; do
        skip=0

        if [[ "${#only[@]}" -gt 0 ]]; then
            local found=0
            for o in "${only[@]}"; do [[ "$o" == "$name" ]] && found=1; done
            [[ "$found" -eq 1 ]] || skip=1
        fi

        for e in "${exclude[@]+"${exclude[@]}"}"; do
            [[ "$e" == "$name" ]] && skip=1
        done

        arch="$(kctl get node "$name" -o jsonpath='{.status.nodeInfo.architecture}' 2>/dev/null || true)"
        if [[ "$skip" -eq 0 && "$arch" != "amd64" && "$arch" != "arm64" ]]; then
            warn "Skipping node ${name}: architecture '${arch}' is not supported by the Ollama image."
            skip=1
        fi

        if [[ "$skip" -eq 0 && "$min_mem_gb" != "0" ]]; then
            mem_ki="$(kctl get node "$name" -o jsonpath='{.status.allocatable.memory}' 2>/dev/null | sed 's/Ki$//' || true)"
            if [[ "$mem_ki" =~ ^[0-9]+$ ]]; then
                mem_gb="$(awk -v k="$mem_ki" 'BEGIN{printf "%.0f", k/1024/1024}')"
                if (( mem_gb < min_mem_gb )); then
                    warn "Skipping node ${name}: ~${mem_gb}GiB allocatable memory < --min-memory-gb ${min_mem_gb}."
                    skip=1
                fi
            fi
        fi

        [[ "$skip" -eq 0 ]] && selected+=("$name")
    done

    [[ "${#selected[@]}" -gt 0 ]] || die "No nodes matched the selection criteria."

    echo "AI workloads (Ollama) will run on: ${selected[*]}"

    local -a resource_lines=()
    [[ -n "$memory_limit" ]] && resource_lines=("        resources:" "          limits:" "            memory: \"${memory_limit}\"")

    local svc_type="ClusterIP" nodeport_line=""
    if [[ -n "$nodeport" ]]; then
        svc_type="NodePort"
        nodeport_line="    nodePort: ${nodeport}"
    fi

    local manifest
    manifest="$(cat <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${AI_NAMESPACE}
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ollama
  namespace: ${AI_NAMESPACE}
  labels:
    app: ollama
spec:
  selector:
    matchLabels:
      app: ollama
  template:
    metadata:
      labels:
        app: ollama
    spec:
      nodeSelector:
        k3smgr.io/ai: "true"
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        effect: NoSchedule
        operator: Exists
      - key: node-role.kubernetes.io/master
        effect: NoSchedule
        operator: Exists
      containers:
      - name: ollama
        image: ${image}
        ports:
        - containerPort: ${OLLAMA_PORT}
          name: http
        env:
        - name: OLLAMA_HOST
          value: "0.0.0.0:${OLLAMA_PORT}"
        volumeMounts:
        - name: models
          mountPath: /root/.ollama
$(printf '%s\n' "${resource_lines[@]+"${resource_lines[@]}"}")
      volumes:
      - name: models
        hostPath:
          path: /var/lib/k3s-manager/ollama
          type: DirectoryOrCreate
---
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: ${AI_NAMESPACE}
  labels:
    app: ollama
spec:
  type: ${svc_type}
  selector:
    app: ollama
  ports:
  - port: ${OLLAMA_PORT}
    targetPort: ${OLLAMA_PORT}
    protocol: TCP
${nodeport_line}
YAML
)"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "$(c_blue "[dry-run]") Would label nodes and apply:"
        echo "$manifest"
        return 0
    fi

    confirm "Proceed?" y || { echo "Cancelled."; return 0; }

    for name in "${candidates[@]}"; do
        local want=0 s
        for s in "${selected[@]}"; do [[ "$s" == "$name" ]] && want=1; done
        if [[ "$want" -eq 1 ]]; then
            kctl label node "$name" k3smgr.io/ai=true --overwrite >/dev/null
        else
            kctl label node "$name" k3smgr.io/ai- >/dev/null 2>&1 || true
        fi
    done

    echo "$manifest" | kctl apply -f - || die "Failed to apply the Ollama DaemonSet/Service. Check 'sudo $(basename "$SELF_PATH") ai status'."

    info "Waiting for the Ollama DaemonSet to roll out (first run pulls the ${image} image on every node, this can take a while)..."
    kctl rollout status daemonset/ollama -n "$AI_NAMESPACE" --timeout=300s || \
        warn "Rollout did not finish in time. Check: sudo $(basename "$SELF_PATH") ai status"

    local cip
    cip="$(kctl get svc ollama -n "$AI_NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
    ok "Ollama deployed across: ${selected[*]}"
    echo "In-cluster API (load-balanced across those nodes): http://${cip}:${OLLAMA_PORT}"
    [[ -n "$nodeport" ]] && echo "External API (any node's IP):        http://<any-node-ip>:${nodeport}"
    echo "Pull a model everywhere: sudo $(basename "$SELF_PATH") ai model install llama3.2"
}

ai_undeploy() {
    need_root
    kctl_available || die "This must be run on a K3s server (control-plane) node with a working kubeconfig."

    local keep_labels=0 keep_data=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --keep-labels) keep_labels=1; shift ;;
            --keep-data) keep_data=1; shift ;;
            *) die "Usage: k3s-manager ai undeploy [--keep-labels] [--keep-data]" ;;
        esac
    done

    confirm "Remove the cluster-wide Ollama deployment (namespace ${AI_NAMESPACE})?" n || { echo "Aborted."; return 0; }

    kctl delete daemonset ollama -n "$AI_NAMESPACE" 2>/dev/null || true
    kctl delete svc ollama -n "$AI_NAMESPACE" 2>/dev/null || true
    kctl delete namespace "$AI_NAMESPACE" 2>/dev/null || true

    if [[ "$keep_labels" -eq 0 ]]; then
        local name
        while read -r name; do
            if [[ -n "$name" ]]; then kctl label node "$name" k3smgr.io/ai- >/dev/null 2>&1 || true; fi
        done < <(kctl get nodes -l k3smgr.io/ai=true -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
    fi

    if [[ "$keep_data" -eq 0 ]]; then
        warn "Downloaded models at /var/lib/k3s-manager/ollama on each formerly-labeled node were NOT deleted (they live on the host, not in the cluster)."
        echo "Remove them per node if you want to reclaim space: sudo rm -rf /var/lib/k3s-manager/ollama"
    fi

    ok "Cluster-wide Ollama deployment removed."
}

ai_status() {
    need_root

    local shown=0
    if kctl_available && kctl get namespace "$AI_NAMESPACE" >/dev/null 2>&1; then
        shown=1
        echo "=== CLUSTER AI DEPLOYMENT (namespace: ${AI_NAMESPACE}) ==="
        kctl get pods -n "$AI_NAMESPACE" -o wide
        echo
        kctl get svc -n "$AI_NAMESPACE"
        echo
        echo "=== MODELS PER NODE ==="
        local pod node
        while IFS=$'\t' read -r pod node; do
            [[ -n "$pod" ]] || continue
            echo "-- ${node} (${pod}) --"
            kctl exec -n "$AI_NAMESPACE" "$pod" -- ollama list 2>/dev/null || echo "  (could not query -- pod may still be starting)"
        done < <(ai_model_pods)
    fi

    if have ollama || systemctl cat ollama.service >/dev/null 2>&1; then
        shown=1
        echo
        echo "=== LOCAL OLLAMA (this node) ==="
        systemctl --no-pager --full status ollama 2>/dev/null || true
        if have ollama; then ollama list 2>/dev/null || true; fi
    fi

    if [[ "$shown" -eq 0 ]]; then
        echo "AI features are not installed anywhere yet."
        echo "  Single node:    sudo $(basename "$SELF_PATH") ai install"
        echo "  Whole cluster:  sudo $(basename "$SELF_PATH") ai deploy   (run on the control-plane)"
    fi
}

ai_nodes() {
    need_root
    kctl_available || die "This must be run on a K3s server (control-plane) node with a working kubeconfig."

    echo "=== CLUSTER NODES (for AI scheduling) ==="
    printf '%-20s %-8s %-7s %-10s %-4s\n' "NODE" "ARCH" "READY" "MEM(GiB)" "AI"
    local name arch ready mem_ki mem_gb ai_label
    while IFS=$'\t' read -r name arch ready mem_ki; do
        [[ -n "$name" ]] || continue
        mem_ki="${mem_ki%Ki}"
        if [[ "$mem_ki" =~ ^[0-9]+$ ]]; then
            mem_gb="$(awk -v k="$mem_ki" 'BEGIN{printf "%.1f", k/1024/1024}')"
        else
            mem_gb="?"
        fi
        ai_label="$(kctl get node "$name" -o jsonpath='{.metadata.labels.k3smgr\.io/ai}' 2>/dev/null || true)"
        printf '%-20s %-8s %-7s %-10s %-4s\n' "$name" "$arch" "${ready:-?}" "$mem_gb" "${ai_label:-no}"
    done < <(kctl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.architecture}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\t"}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null)
}

# ai_model_pods -- prints "pod<TAB>node" for every Running ollama pod in the cluster (if any)
ai_model_pods() {
    kctl_available || return 1
    kctl get pods -n "$AI_NAMESPACE" -l app=ollama --field-selector=status.phase=Running \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}' 2>/dev/null
}

ai_model_target_pods() {
    # populates global arrays AI_TARGET_PODS / AI_TARGET_NODES, honoring --node filter
    local only_node="$1"
    AI_TARGET_PODS=(); AI_TARGET_NODES=()
    local pod node
    while IFS=$'\t' read -r pod node; do
        [[ -n "$pod" ]] || continue
        [[ -n "$only_node" && "$node" != "$only_node" ]] && continue
        AI_TARGET_PODS+=("$pod"); AI_TARGET_NODES+=("$node")
    done < <(ai_model_pods)
}

ai_model_install() {
    need_root
    local model="${1:-}"
    shift || true
    [[ -n "$model" ]] || die "Usage: k3s-manager ai model install MODEL [--node NODE]"

    local only_node=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --node) [[ $# -ge 2 ]] || die "--node requires a node name."; only_node="$2"; shift 2 ;;
            *) die "Unknown 'ai model install' option: $1" ;;
        esac
    done

    local -a AI_TARGET_PODS AI_TARGET_NODES
    ai_model_target_pods "$only_node"

    if [[ "${#AI_TARGET_PODS[@]}" -gt 0 ]]; then
        info "Pulling '${model}' into ${#AI_TARGET_PODS[@]} cluster node(s)..."
        local i
        for ((i = 0; i < ${#AI_TARGET_PODS[@]}; i++)); do
            echo "-- ${AI_TARGET_NODES[i]} --"
            kctl exec -n "$AI_NAMESPACE" "${AI_TARGET_PODS[i]}" -- ollama pull "$model" || warn "Pull failed on ${AI_TARGET_NODES[i]}."
        done
        ok "Done. Check with: sudo $(basename "$SELF_PATH") ai status"
        return 0
    fi

    if have ollama; then
        info "No cluster AI deployment found; pulling '${model}' into the local Ollama instance..."
        run ollama pull "$model"
        ok "Done."
        return 0
    fi

    die "No cluster AI deployment ('ai deploy') and no local Ollama ('ai install') found on this node."
}

ai_model_list() {
    local only_node=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --node) [[ $# -ge 2 ]] || die "--node requires a node name."; only_node="$2"; shift 2 ;;
            *) die "Usage: k3s-manager ai model list [--node NODE]" ;;
        esac
    done

    local -a AI_TARGET_PODS AI_TARGET_NODES
    ai_model_target_pods "$only_node"

    if [[ "${#AI_TARGET_PODS[@]}" -gt 0 ]]; then
        local i
        for ((i = 0; i < ${#AI_TARGET_PODS[@]}; i++)); do
            echo "-- ${AI_TARGET_NODES[i]} --"
            kctl exec -n "$AI_NAMESPACE" "${AI_TARGET_PODS[i]}" -- ollama list 2>/dev/null || echo "  (could not query)"
        done
        return 0
    fi

    if have ollama; then
        ollama list
        return 0
    fi

    die "No cluster AI deployment and no local Ollama found on this node."
}

ai_model_rm() {
    need_root
    local model="${1:-}"
    shift || true
    [[ -n "$model" ]] || die "Usage: k3s-manager ai model rm MODEL [--node NODE]"

    local only_node=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --node) [[ $# -ge 2 ]] || die "--node requires a node name."; only_node="$2"; shift 2 ;;
            *) die "Unknown 'ai model rm' option: $1" ;;
        esac
    done

    local -a AI_TARGET_PODS AI_TARGET_NODES
    ai_model_target_pods "$only_node"

    if [[ "${#AI_TARGET_PODS[@]}" -gt 0 ]]; then
        local i
        for ((i = 0; i < ${#AI_TARGET_PODS[@]}; i++)); do
            echo "-- ${AI_TARGET_NODES[i]} --"
            kctl exec -n "$AI_NAMESPACE" "${AI_TARGET_PODS[i]}" -- ollama rm "$model" || warn "Remove failed on ${AI_TARGET_NODES[i]}."
        done
        return 0
    fi

    if have ollama; then
        run ollama rm "$model"
        return 0
    fi

    die "No cluster AI deployment and no local Ollama found on this node."
}

ai_model() {
    local sub="${1:-}"
    shift || true
    case "$sub" in
        install|pull) ai_model_install "$@" ;;
        list|ls) ai_model_list "$@" ;;
        rm|remove|delete) ai_model_rm "$@" ;;
        *) die "Usage: k3s-manager ai model {install|list|rm} MODEL [--node NODE]" ;;
    esac
}

cmd_ai() {
    local sub="${1:-}"
    shift || true
    case "$sub" in
        install) ai_install "$@" ;;
        uninstall) ai_uninstall "$@" ;;
        deploy) ai_deploy "$@" ;;
        undeploy) ai_undeploy "$@" ;;
        status) ai_status "$@" ;;
        nodes) ai_nodes "$@" ;;
        model) ai_model "$@" ;;
        *)
            die "Usage: k3s-manager ai {install|uninstall|deploy|undeploy|status|nodes|model} ..."
            ;;
    esac
}

# ---------- interactive menu ----------

pick_interface() {
    local prompt="${1:-Select the interface k3s should bind to}"
    echo "$prompt:" >&2
    local -a names=()
    local i=1 name cidr
    while read -r name cidr; do
        [[ -z "$name" ]] && continue
        names+=("$name")
        printf '  %d) %-10s %s\n' "$i" "$name" "$cidr" >&2
        i=$((i + 1))
    done < <(list_candidate_ifaces)
    printf '  %d) %s\n' "$i" "skip (let k3s auto-select)" >&2

    local choice
    choice="$(ask "Choice" "1")"
    if [[ "$choice" == "$i" ]]; then
        echo ""
        return 0
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < i )); then
        echo "${names[$((choice - 1))]}"
        return 0
    fi
    # allow typing an interface name directly
    echo "$choice"
}

random_token() {
    if have openssl; then
        openssl rand -hex 32
    else
        head -c48 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c64
    fi
}

menu_install_master() {
    local ha=""
    confirm "Enable HA (embedded etcd, allows multiple masters)?" n && ha="--ha"
    local allow=""
    confirm "Allow workloads to run on this master (useful for a single-node/small cluster)?" y && allow="--worker"

    local iface
    iface="$(pick_interface "Select the network interface for cluster traffic (e.g. your dedicated Ethernet NIC)")"

    local channel
    echo "Release channel: 1) stable  2) latest  3) testing  4) pin exact version"
    local cchoice
    cchoice="$(ask "Choice" "1")"
    local version=""
    case "$cchoice" in
        1) channel="stable" ;;
        2) channel="latest" ;;
        3) channel="testing" ;;
        4) channel=""; version="$(ask "Exact version (e.g. v1.31.4+k3s1)")" ;;
        *) channel="stable" ;;
    esac

    local no_auto_san=""
    if have tailscale && ! confirm "Include this node's Tailscale IP/hostname in the TLS certificate (recommended for remote kubectl access)?" y; then
        no_auto_san="--no-auto-tls-san"
    fi

    local -a cmd_args=(install master)
    [[ -n "$ha" ]] && cmd_args+=("$ha")
    [[ -n "$allow" ]] && cmd_args+=("$allow")
    [[ -n "$iface" ]] && cmd_args+=(--interface "$iface")
    [[ -n "$channel" ]] && cmd_args+=(--channel "$channel")
    [[ -n "$version" ]] && cmd_args+=(--version "$version")
    [[ -n "$no_auto_san" ]] && cmd_args+=("$no_auto_san")
    cmd_args+=(--yes)

    echo
    echo "About to run: $(basename "$SELF_PATH") ${cmd_args[*]}"
    confirm "Proceed?" y || { echo "Cancelled."; return 0; }
    cmd_install "master" "${cmd_args[@]:2}"
}

menu_install_worker() {
    local server token
    server="$(ask "Master API URL (e.g. https://10.50.0.1:6443)")"
    [[ -n "$server" ]] || { echo "Server URL is required."; return 0; }
    token="$(ask "Join token (from 'k3s-manager token' on the master)")"
    [[ -n "$token" ]] || { echo "Token is required."; return 0; }

    local iface
    iface="$(pick_interface "Select the network interface for cluster traffic")"

    local -a cmd_args=(--server "$server" --token "$token")
    [[ -n "$iface" ]] && cmd_args+=(--interface "$iface")

    echo
    echo "About to join this node as a worker to ${server}"
    confirm "Proceed?" y || { echo "Cancelled."; return 0; }
    cmd_install "worker" "${cmd_args[@]}"
}

menu_install_join_master() {
    local server token
    server="$(ask "Existing master API URL (e.g. https://10.50.0.1:6443)")"
    [[ -n "$server" ]] || { echo "Server URL is required."; return 0; }
    token="$(ask "Join token")"
    [[ -n "$token" ]] || { echo "Token is required."; return 0; }
    local iface
    iface="$(pick_interface "Select the network interface for cluster traffic")"

    local -a cmd_args=(--server "$server" --token "$token")
    [[ -n "$iface" ]] && cmd_args+=(--interface "$iface")

    confirm "Proceed joining as an additional HA master?" y || { echo "Cancelled."; return 0; }
    cmd_install "join-master" "${cmd_args[@]}"
}

cmd_menu() {
    need_root
    load_os
    load_config

    while true; do
        echo
        echo "=================================================="
        echo "   K3S MANAGER v${VERSION}  --  interactive menu"
        echo "=================================================="
        echo "  Current role on this node: ${K3SMGR_ROLE:-not installed}"
        echo
        echo "  1) Install this node as the FIRST master (control-plane)"
        echo "  2) Install this node as an additional HA master"
        echo "  3) Install this node as a worker"
        echo "  4) Show join token / info (run on a master)"
        echo "  5) Status"
        echo "  6) Diagnostics (doctor)"
        echo "  7) Set up kubectl access (kubeconfig)"
        echo "  8) Add a remote node over SSH"
        echo "  9) Upgrade k3s on this node"
        echo " 10) Update k3s-manager itself"
        echo " 11) Network info / system info"
        echo " 12) Uninstall k3s from this node"
        echo " 13) AI: deploy Ollama across the cluster"
        echo " 14) AI: install a model everywhere"
        echo " 15) AI: status"
        echo "  0) Exit"
        echo
        local choice
        choice="$(ask "Choice" "0")"
        case "$choice" in
            1) menu_install_master ;;
            2) menu_install_join_master ;;
            3) menu_install_worker ;;
            4) cmd_token ;;
            5) cmd_status ;;
            6) local fix=""; confirm "Auto-fix issues found?" n && fix="--fix"; cmd_doctor ${fix} ;;
            7) cmd_kubeconfig ;;
            8) local kind; kind="$(ask "Add as (worker/master)" "worker")"; local host; host="$(ask "SSH target (user@host)")"; local ifc; ifc="$(ask "Remote interface" "eth0")"; cmd_add_node "$kind" --ssh "$host" --interface "$ifc" ;;
            9) cmd_upgrade ;;
            10) cmd_update ;;
            11) cmd_network_info; cmd_sysinfo ;;
            12) cmd_uninstall ;;
            13) ai_deploy ;;
            14) local model; model="$(ask "Model name (e.g. llama3.2, qwen2.5:7b)")"; [[ -n "$model" ]] && ai_model_install "$model" ;;
            15) ai_status ;;
            0) echo "Bye."; return 0 ;;
            *) echo "Invalid choice." ;;
        esac
    done
}

# ---------- help ----------

cmd_help() {
    cat <<HELP
K3S MANAGER v${VERSION}
$(printf '=%.0s' $(seq 1 $((14 + ${#VERSION}))))

Run with no arguments (or 'menu') for an interactive guided setup that
will ask for your Linux distribution, network interface, and role.

INSTALL
-------
  sudo k3s-manager install master [--ha] [--worker] [--interface eth0]
                                   [--channel stable|latest|testing]
                                   [--version vX.Y.Z+k3sN]
                                   [--tls-san HOST]... [--no-auto-tls-san]
                                   [--disable traefik]... [--keep-ingress]
                                   [--cluster-cidr CIDR]
                                   [--service-cidr CIDR] [--datastore-endpoint DSN]
                                   [--node-label K=V]... [--node-taint K=V:Effect]...
                                   [--token TOKEN] [--yes]

  sudo k3s-manager install join-master --server URL --token T [--interface eth0]
                                        [--tls-san HOST]...

  sudo k3s-manager install worker --server URL --token T [--interface eth0]
                                   [--version vX.Y.Z+k3sN | --channel C]
                                   [--node-label K=V]... [--node-taint K=V:Effect]...

LIFECYCLE
---------
  sudo k3s-manager upgrade [--channel C | --version V]
  sudo k3s-manager uninstall
  sudo k3s-manager start|stop|restart
  sudo k3s-manager enable-boot|disable-boot

DIAGNOSTICS & REPAIR
---------------------
  sudo k3s-manager status
  sudo k3s-manager doctor [--fix]        # checks swap/modules/sysctl/firewall/connectivity/cluster health
  sudo k3s-manager network-info
  sudo k3s-manager logs [--follow] [--lines N]
  sudo k3s-manager firewall {status|open|disable}

CLUSTER OPERATIONS
-------------------
  sudo k3s-manager token
  sudo k3s-manager list-nodes
  sudo k3s-manager add-node worker|master [--ssh user@host] [--interface eth0]
  sudo k3s-manager remove-node NODE [--purge]
  sudo k3s-manager kubeconfig [--ip IP] [--user USER] [--merge]
  sudo k3s-manager snapshot {save|list|restore SNAPSHOT}
  sudo k3s-manager sysinfo

AI DISTRIBUTION (Ollama)
-------------------------
  sudo k3s-manager ai install [--force]                 # single node, systemd service
  sudo k3s-manager ai uninstall [--purge-models]

  sudo k3s-manager ai deploy [--only NODE]... [--exclude NODE]...
                              [--min-memory-gb N] [--memory-limit 6Gi]
                              [--nodeport 31434] [--image ollama/ollama:latest]
                              # cluster-wide: run on the control-plane. Deploys
                              # Ollama as a DaemonSet on every labeled node behind
                              # one Service -- concurrent requests are load
                              # balanced across your machines by kube-proxy.
  sudo k3s-manager ai undeploy [--keep-labels] [--keep-data]
  sudo k3s-manager ai status
  sudo k3s-manager ai nodes                              # arch/memory/AI-label per node

  sudo k3s-manager ai model install MODEL [--node NODE]  # e.g. llama3.2, qwen2.5:7b
  sudo k3s-manager ai model list   [--node NODE]
  sudo k3s-manager ai model rm     MODEL [--node NODE]

HA / WATCHDOG
-------------
  sudo k3s-manager watchdog-install --master IP [--check-interval N] [--fail-threshold N]
  sudo k3s-manager watchdog-uninstall
  sudo k3s-manager promote

TOOL MAINTENANCE
-----------------
  sudo k3s-manager update [--check] [--ref BRANCH] [--force]
  k3s-manager version

GLOBAL FLAGS (valid anywhere in the command line)
---------------------------------------------------
  --yes, -y       assume "yes" to all prompts (non-interactive)
  --dry-run       print state-changing commands instead of running them
  --verbose, -v   print extra diagnostic output

NETWORKING NOTES
-----------------
--interface eth0 pins --node-ip / --advertise-address / --flannel-iface to
that interface's IPv4 address. Use this on multi-homed nodes (e.g. a
dedicated Ethernet NIC for cluster traffic plus Wi-Fi for internet) so k3s
does not bind to the wrong network. TLS SANs automatically include this
node's Tailscale IP (if Tailscale is installed) so kubectl / node-to-node
API access also works over Tailscale from off-site.

COEXISTING WITH OTHER SERVICES (e.g. NEXTCLOUD)
-------------------------------------------------
K3s installs the Traefik ingress controller + ServiceLB by default, and
both try to bind ports 80/443 on EVERY node. If 'install master' detects
something already listening on 80/443 (or a Nextcloud install by any
common method: snap, Docker, apt/manual web root, systemd service), it
automatically adds --disable traefik --disable servicelb so k3s never
touches those ports. Pass --keep-ingress to force Traefik/ServiceLB on
anyway. 'doctor' also checks for an iptables FORWARD policy of DROP/REJECT,
a common cause of Docker (e.g. Nextcloud AIO) and k3s/flannel silently
breaking each other's networking on a shared host.

EXAMPLES
--------
First master (dedicated Ethernet NIC, workloads allowed):
  sudo k3s-manager install master --worker --interface eth0

Get join info from the master:
  sudo k3s-manager token

Join a worker:
  sudo k3s-manager install worker --server https://10.50.0.1:6443 --token 'TOKEN' --interface eth0

Provision a worker remotely from the master over SSH:
  sudo k3s-manager add-node worker --ssh user@10.50.0.4 --interface eth0

Diagnose and auto-fix common issues:
  sudo k3s-manager doctor --fix

Deploy Ollama across the whole cluster and pull a model everywhere:
  sudo k3s-manager ai deploy
  sudo k3s-manager ai model install llama3.2

Update the tool itself:
  sudo k3s-manager update
HELP
}

# ---------- main ----------

main() {
    # global flag pre-scan: --yes/-y, --dry-run, --verbose/-v, --debug may appear anywhere
    local -a rest=()
    local arg
    for arg in "$@"; do
        case "$arg" in
            --yes|-y) ASSUME_YES=1 ;;
            --dry-run) DRY_RUN=1 ;;
            --verbose|-v|--debug) VERBOSE=1 ;;
            *) rest+=("$arg") ;;
        esac
    done
    set -- "${rest[@]+"${rest[@]}"}"

    local command="${1:-menu}"
    shift || true

    case "$command" in
        menu) cmd_menu "$@" ;;
        install) cmd_install "$@" ;;
        token|join-info) cmd_token ;;
        network-info) cmd_network_info ;;
        status) cmd_status ;;
        list-nodes|get-nodes) cmd_list_nodes ;;
        start) cmd_start ;;
        stop) cmd_stop ;;
        restart) cmd_restart ;;
        enable-boot) cmd_enable_boot ;;
        disable-boot) cmd_disable_boot ;;
        add-node) cmd_add_node "$@" ;;
        remove-node) cmd_remove_node "$@" ;;
        watchdog-install) cmd_watchdog_install "$@" ;;
        watchdog-uninstall) cmd_watchdog_uninstall ;;
        promote) cmd_promote ;;
        uninstall) cmd_uninstall ;;
        doctor) cmd_doctor "$@" ;;
        upgrade) cmd_upgrade "$@" ;;
        kubeconfig) cmd_kubeconfig "$@" ;;
        firewall) cmd_firewall "$@" ;;
        logs) cmd_logs "$@" ;;
        snapshot) cmd_snapshot "$@" ;;
        sysinfo) cmd_sysinfo ;;
        ai) cmd_ai "$@" ;;
        update) cmd_update "$@" ;;
        version|--version|-V) echo "k3s-manager ${VERSION}" ;;
        help|--help|-h) cmd_help ;;
        *)
            echo "Unknown command: $command" >&2
            echo
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"












