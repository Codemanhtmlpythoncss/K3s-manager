# K3s Manager

A single self-contained bash script that installs, joins, upgrades, diagnoses,
and repairs a [k3s](https://k3s.io) Kubernetes cluster across mixed-OS,
mixed-architecture homelab machines — plus an optional built-in feature to
run and distribute AI inference (via [Ollama](https://ollama.com)) across
every node in that same cluster.

It is designed for the common homelab shape: a few Linux boxes (maybe a
Raspberry Pi, maybe old laptops, maybe a rack of minis) on a flat network,
where you just want `k3s-manager install master` on one box and
`k3s-manager install worker` on the others to give you a working cluster —
with sane defaults, clear errors, and a `doctor` command for when something
inevitably doesn't come up on the first try.

## Features

**Install & lifecycle**
- Single-node bootstrap (`install master`), HA/embedded-etcd masters
  (`--ha` / `install join-master`), and workers (`install worker`)
- Pin the k3s release channel or an exact version (`--channel`, `--version`);
  upgrade later with `upgrade`
- Multi-homed network support: `--interface eth0` pins `--node-ip`,
  `--advertise-address` and `--flannel-iface` to one NIC, so a box with both
  a dedicated cluster NIC and a Wi-Fi/internet NIC doesn't get this wrong
- Automatic TLS SANs for [Tailscale](https://tailscale.com): if Tailscale is
  installed, its IP is added to the API server certificate automatically, so
  `kubectl` works from anywhere on your tailnet with no extra flags
- Full control over `--disable`, `--cluster-cidr`, `--service-cidr`,
  `--datastore-endpoint`, `--node-label`, `--node-taint`
- Clean, complete `uninstall`

**Diagnostics & self-healing**
- `doctor [--fix]` checks (and can fix): swap left on, missing
  `br_netfilter`/`overlay` kernel modules, `ip_forward`, no time-sync
  service, a blocking `iptables` FORWARD policy, firewall ports, node/pod
  health, and reachability to the control-plane
- Every network operation (installer download, package installs, joins)
  retries with backoff instead of failing on the first flaky connection
- A preflight check before any `worker`/`join-master` install, and before any
  `add-node --ssh`, reproduces and explains "no route to host"-style
  failures instead of just reporting them
- `logs`, `status`, `network-info`, `sysinfo` for fast triage

**Coexists with what's already on the box**
- K3s ships Traefik + ServiceLB, which bind ports 80/443 on *every* node by
  default. `install master` detects anything already on 80/443 — including a
  Nextcloud install via snap, Docker, or a manual web root — and
  automatically disables Traefik/ServiceLB to avoid the clash
  (`--keep-ingress` to opt back in)
- `doctor` flags an `iptables` FORWARD policy of DROP/REJECT, a common,
  easy-to-miss cause of Docker (e.g. Nextcloud AIO) and k3s/flannel breaking
  each other's networking on a shared host

**AI distribution (Ollama)**
- `ai install` / `ai uninstall` — a single node's local Ollama, as a proper
  systemd service
- `ai deploy` / `ai undeploy` — run from the control-plane to deploy Ollama
  as a Kubernetes DaemonSet across your whole cluster behind one Service, so
  concurrent inference requests get load-balanced across your physical
  machines by kube-proxy. Filter which nodes participate by name or by
  minimum memory (`--only`, `--exclude`, `--min-memory-gb`)
- `ai model install/list/rm MODEL` — manage models across every deployed
  node (or a single one with `--node`) in one command
- `ai status` / `ai nodes` — see what's running and what's cached where
- See [AI distribution](#ai-distribution-ollama-1) below for exactly what
  "distribute" does and doesn't mean here

**Cluster operations**
- `token` — join info for every detected network (Ethernet, Wi-Fi,
  Tailscale)
- `add-node worker|master --ssh user@host` — provision a **remote** machine
  over SSH in one command, with the same connectivity preflight as above
- `remove-node`, `list-nodes`, `kubeconfig` (with `--ip` to bake in a
  Tailscale address for off-site access), `snapshot save/list/restore`
  (etcd snapshot for HA, or a SQLite tarball backup otherwise)

**HA failover watchdog**
- `watchdog-install --master IP` — a systemd timer that pings the control
  plane and logs (never silently auto-rewrites the cluster) when it's been
  unreachable past a threshold; `promote` to act on it manually

**The tool itself**
- `update [--check] [--force] [--ref BRANCH]` — self-updates from this repo
  (or `git pull`, if run from a clone), with a syntax check and a real
  semver comparison before installing, so it will never silently downgrade
  you
- Global `--yes`, `--dry-run`, `--verbose` flags work anywhere in the
  command line
- Run with no arguments for an interactive menu that walks through OS
  detection, role selection, and everything above

## Supported operating systems

| Package manager | Distros |
|---|---|
| `apt` | Debian, Ubuntu, Raspberry Pi OS, Linux Mint |
| `dnf` | Fedora, RHEL 8+, Rocky Linux, AlmaLinux, Amazon Linux 2023 |
| `yum` | RHEL/CentOS 7, Amazon Linux 2 (legacy, best-effort — these are EOL upstream) |
| `zypper` | openSUSE Leap/Tumbleweed, SLES |
| `pacman` | Arch Linux, Manjaro, EndeavourOS |
| `apk` | Alpine Linux |

Architectures: **x86_64/amd64** and **aarch64/arm64** are fully supported
(including Raspberry Pi 4/5). K3s itself also runs on armhf/riscv64/s390x in
some configurations; the script won't stop you, but the `ai` commands
(Ollama) require x86_64 or arm64.

`k3s-manager` asks you to confirm the OS/package-manager it detects (or lets
you pick manually) before doing anything — it never silently guesses on an
unrecognized system.

**Requirement:** bash ≥ 4.3 (ships by default on every distro above except
RHEL/CentOS 7 and Amazon Linux 2, which are past end-of-life). The script
checks this itself and exits with a clear message rather than failing
halfway through an install.

## Quickstart

Install it:

```bash
sudo curl -sfL https://raw.githubusercontent.com/Codemanhtmlpythoncss/K3s-manager/main/k3s-manager.sh -o /usr/local/bin/k3s-manager && sudo chmod +x /usr/local/bin/k3s-manager
```

Run it with no arguments for the guided menu, or drive it directly:

**On your first machine (control-plane):**
```bash
sudo k3s-manager install master --worker --interface eth0
sudo k3s-manager token
```
(`--worker` lets pods schedule on this node too — drop it for a dedicated
control-plane. `--interface` pins cluster traffic to that NIC; omit it to
let k3s pick automatically.)

**On every other machine (worker):**
```bash
sudo k3s-manager install worker --server https://<MASTER_IP>:6443 --token 'TOKEN' --interface eth0
```

**Or, from the control-plane, provision a worker remotely over SSH:**
```bash
sudo k3s-manager add-node worker --ssh you@10.0.0.4 --interface eth0
```

**Check on it:**
```bash
sudo k3s-manager status
sudo k3s-manager list-nodes
```

**Something's not working:**
```bash
sudo k3s-manager doctor --fix
```

## Command reference

Run `k3s-manager help` for the full, current list — it's generated from the
same code that runs the commands, so it never drifts out of date. Summary:

```
install master [--ha] [--worker] [--interface IFACE] [--channel C|--version V]
               [--tls-san HOST]... [--no-auto-tls-san] [--disable NAME]...
               [--keep-ingress] [--cluster-cidr CIDR] [--service-cidr CIDR]
               [--datastore-endpoint DSN] [--node-label K=V]...
               [--node-taint K=V:Effect]... [--token T] [--yes]
install join-master --server URL --token T [--interface IFACE] [--tls-san HOST]...
install worker --server URL --token T [--interface IFACE] [--node-label K=V]...

upgrade [--channel C | --version V]      uninstall
start | stop | restart                   enable-boot | disable-boot

status                                   doctor [--fix]
network-info                             sysinfo
logs [--follow] [--lines N]              firewall {status|open|disable}

token                                    list-nodes
add-node worker|master [--ssh user@host] [--interface IFACE]
remove-node NODE [--purge]
kubeconfig [--ip IP] [--user USER] [--merge]
snapshot {save|list|restore SNAPSHOT}

ai install [--force]                     ai uninstall [--purge-models]
ai deploy [--only NODE]... [--exclude NODE]... [--min-memory-gb N]
          [--memory-limit 6Gi] [--nodeport PORT] [--image IMG]
ai undeploy [--keep-labels] [--keep-data]
ai status                                ai nodes
ai model install|list|rm MODEL [--node NODE]

watchdog-install --master IP [--check-interval N] [--fail-threshold N]
watchdog-uninstall                       promote

update [--check] [--force] [--ref BRANCH]
menu                                     version | help

Global flags (anywhere): --yes/-y  --dry-run  --verbose/-v
```

## Networking

`--interface eth0` pins `--node-ip`, `--advertise-address`, and
`--flannel-iface` to that interface's IPv4 address. Use it on any node that
has more than one network path (e.g. a dedicated switch/direct-connect NIC
for cluster traffic, plus Wi-Fi for internet) — without it, k3s picks
whichever address the kernel's default route happens to prefer, which is
not always the one you want.

If [Tailscale](https://tailscale.com) is installed, its IP and this node's
hostname are added to the API server's TLS certificate automatically (opt
out with `--no-auto-tls-san`), so `kubectl` and node-to-node API traffic
keep working over Tailscale from off-site with zero extra configuration.

`k3s-manager` never touches routing or adds a default gateway — it only
tells k3s which local address to bind to. A common, well-tested pattern is
a flat, gateway-less subnet on a dedicated switch/NICs for cluster traffic,
with each machine's normal Wi-Fi/LAN connection left as the only default
route for internet access.

## Coexisting with other services (e.g. Nextcloud)

K3s installs the Traefik ingress controller and ServiceLB (Klipper) by
default. Both are `type: LoadBalancer`/ingress-facing and will try to bind
ports **80 and 443 on every node**, whether or not that node is actually
serving the traffic. If you're running Nextcloud — or anything else on
80/443 — on the same host, that's a conflict.

`install master` checks for this automatically:
- Detects an existing listener on 80/443
- Detects Nextcloud specifically, via snap, a running Docker container, a
  `/var/www*/nextcloud` web root, or a matching systemd service
- If either is found, it passes `--disable traefik --disable servicelb` to
  the k3s installer for you, and tells you it did so

Pass `--keep-ingress` if you actually want Traefik/ServiceLB and are
managing the port conflict yourself (e.g. Nextcloud is on a different host).

Separately, `doctor` checks whether the host's `iptables` FORWARD chain
policy is `DROP`/`REJECT`. This is a well-known, easy-to-miss cause of
Docker (including Nextcloud AIO, which is Docker-based) and k3s/flannel
silently breaking each other's pod/container networking when both run on
the same machine. `doctor --fix` inserts an `ACCEPT` rule ahead of the
policy without changing the policy itself.

## AI distribution (Ollama)

`k3s-manager ai` builds on [Ollama](https://ollama.com) — it has the
broadest Linux/x86_64/arm64 support of any local-LLM runner, needs no GPU,
and speaks a simple HTTP API, which makes it the most reliable fit for a
mixed-hardware homelab cluster.

There are two independent modes:

- **`ai install`** sets up Ollama as a normal systemd service on *this*
  node only — nothing cluster-related, just a local `ollama serve`.
- **`ai deploy`** (run once, from the control-plane) deploys Ollama as a
  Kubernetes **DaemonSet**: one pod per node you select, all behind a
  single Service. Requests to that Service get **load-balanced by
  kube-proxy across whichever nodes have a pod** — so if you're serving
  several concurrent requests (multiple users, multiple scripts, etc.),
  they get spread across your physical machines instead of all hitting one
  box.

**What this is not:** it does not split a single model's layers across
multiple machines to run one inference job faster or to fit a model too
large for any one node's memory. That's a genuinely different, much harder
problem (model/tensor-parallel sharding across heterogeneous devices) with
its own specialized, more experimental tooling. What `ai deploy` gives you
is horizontal, request-level distribution: every participating node keeps
its own full copy of whatever models you've pulled there, and can serve any
request for that model independently. `ai model install MODEL` pulls a
model onto every node in the deployment (or just one, with `--node`) so any
of them can serve it without a delay on first request.

```bash
# From the control-plane, after the cluster is up:
sudo k3s-manager ai deploy                          # every Ready node, amd64/arm64 only
sudo k3s-manager ai deploy --exclude k8s-control \
                            --min-memory-gb 4        # e.g. skip a memory-tight control-plane
sudo k3s-manager ai model install llama3.2           # pulled onto every participating node
sudo k3s-manager ai status                           # pods, service, and models per node
```

The Service is `ClusterIP` by default (reachable from inside the cluster,
or via `kubectl port-forward`); pass `--nodeport 31434` to also expose it on
that port on every node's own IP.

## Self-updating

```bash
sudo k3s-manager update            # pulls the latest from this repo, or `git pull` if cloned
sudo k3s-manager update --check    # just report whether an update is available
```

It downloads to a temp file, runs a syntax check, and does a real version
comparison before replacing anything — it will refuse to install an older
version over a newer one unless you pass `--force`. The previous version is
always backed up next to the script before it's replaced.

## Troubleshooting

- **`ssh: connect to host X port 22: No route to host`** (or the same for
  port 6443 during a join): `doctor` and `add-node --ssh` both run this
  exact check before attempting the real operation, and print a checklist
  (service running? firewall? interface up? same subnet?) instead of just
  failing. If two nodes previously pinged each other fine over this network,
  the static IP/interface config is almost never the cause — check the
  target's service, firewall, and interface state first.
- **A node never goes `Ready`**: `sudo k3s-manager doctor` — checks swap,
  kernel modules, sysctls, time sync, firewall, and connectivity to the
  control-plane in one pass.
- **k3s took over ports 80/443 I needed for something else**: see
  [Coexisting with other services](#coexisting-with-other-services-eg-nextcloud)
  above; re-run `install master --keep-ingress` reversed, or disable
  Traefik/ServiceLB after the fact with
  `sudo k3s-manager firewall status` and `kubectl -n kube-system delete svc traefik`.
- **RHEL/Rocky/Alma and SELinux**: the upstream k3s installer already
  installs the `k3s-selinux` policy package automatically on
  SELinux-enabled RPM-based systems; `sysinfo`/`doctor` will still tell you
  the enforcement mode so you know what you're working with.
