#!/usr/bin/env bash
# 模擬節點的 init：把一台 Ubuntu 22.04 主機在跑 k3s + Doris 之前該做的事做完，
# 然後把 PID 1 交給 k3s server。
set -euo pipefail

log() { echo "[node-entrypoint] $*"; }

# kubelet 會讀 /dev/kmsg；容器裡預設沒有，指到 console 即可。
if [[ ! -e /dev/kmsg ]]; then
    ln -sf /dev/console /dev/kmsg
fi

# kubelet 掛載 volume 時需要 rshared 傳播。
mount --make-rshared / 2>/dev/null || log "warn: cannot make / rshared"

# cgroup v1 主機上，/sys/fs/cgroup 常常是唯讀掛進來的，kubelet 需要可寫。
if [[ -d /sys/fs/cgroup ]] && ! touch /sys/fs/cgroup/.rw-probe 2>/dev/null; then
    mount -o remount,rw /sys/fs/cgroup 2>/dev/null || log "warn: cannot remount cgroup rw"
fi
rm -f /sys/fs/cgroup/.rw-probe 2>/dev/null || true

# Doris BE 的硬性需求：start_be.sh 會檢查 vm.max_map_count，不足就直接退出。
# 這個 sysctl 不是 namespaced 的，容器裡設等於設在整台主機上。
sysctl -w vm.max_map_count=2000000 >/dev/null 2>&1 || log "warn: cannot set vm.max_map_count"
sysctl -w vm.swappiness=0 >/dev/null 2>&1 || true
sysctl -w fs.file-max=6553600 >/dev/null 2>&1 || true
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null 2>&1 || true

# Doris BE 要求 min_file_descriptor_number >= 65536，
# containerd 由 k3s 這個行程 fork，所以在這裡放寬即可繼承下去。
ulimit -n 1048576 2>/dev/null || log "warn: cannot raise nofile"
ulimit -c unlimited 2>/dev/null || true

# Doris 官方建議關閉 THP。
if [[ -w /sys/kernel/mm/transparent_hugepage/enabled ]]; then
    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
fi

# 有些沙箱把 CAP_SYS_RESOURCE 拿掉了，這時沒辦法把 oom_score_adj 調得比自己低。
# kubelet 會要求 pause 容器用 -998，runc 會因此在啟動 init 時失敗
# （"can't get final child's PID from pipe: EOF"），所有 Pod 都會卡住。
# 偵測到這種環境時，改用會把負值抹成 0 的 runc wrapper。
current_adj="$(cat /proc/self/oom_score_adj 2>/dev/null || echo 0)"
if ! echo "$((current_adj - 1))" > /proc/self/oom_score_adj 2>/dev/null; then
    log "cannot lower oom_score_adj (no CAP_SYS_RESOURCE) -> 啟用 runc wrapper"
    mkdir -p /var/lib/rancher/k3s/agent/etc/containerd
    cat > /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl <<'TOML'
version = 2

[plugins."io.containerd.internal.v1.opt"]
  path = "/var/lib/rancher/k3s/agent/containerd"

[plugins."io.containerd.grpc.v1.cri"]
  stream_server_address = "127.0.0.1"
  stream_server_port = "10010"
  enable_selinux = false
  enable_unprivileged_ports = true
  enable_unprivileged_icmp = true
  device_ownership_from_security_context = false
  sandbox_image = "rancher/mirrored-pause:3.6"

[plugins."io.containerd.grpc.v1.cri".containerd]
  snapshotter = "overlayfs"
  disable_snapshot_annotations = true

[plugins."io.containerd.grpc.v1.cri".cni]
  bin_dir = "/var/lib/rancher/k3s/data/cni"
  conf_dir = "/var/lib/rancher/k3s/agent/etc/cni/net.d"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = false
  BinaryName = "/usr/local/bin/runc-no-oom-adj"

[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/var/lib/rancher/k3s/agent/etc/containerd/certs.d"
TOML
else
    echo "$current_adj" > /proc/self/oom_score_adj 2>/dev/null || true
fi

log "kernel=$(uname -r) os=$(. /etc/os-release && echo "$PRETTY_NAME")"
log "vm.max_map_count=$(cat /proc/sys/vm/max_map_count) nofile=$(ulimit -n)"

airgap_count=$(ls -1 /var/lib/rancher/k3s/agent/images/ 2>/dev/null | wc -l)
log "airgap image bundles staged: ${airgap_count}"

log "starting: k3s $*"
exec k3s "$@"
