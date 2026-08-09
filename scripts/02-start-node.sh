#!/usr/bin/env bash
# 建立並啟動「Ubuntu 22.04 模擬節點」，在裡面跑起 k3s single-node cluster。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

cd "$REPO_ROOT"

if [[ ! -x "$STAGE_DIR/k3s" ]]; then
    echo "找不到 $STAGE_DIR/k3s，請先執行 scripts/01-stage-artifacts.sh" >&2
    exit 1
fi

echo "==> build ${NODE_IMAGE} (base: ubuntu:${UBUNTU_VERSION})"
docker build --network host -t "$NODE_IMAGE" -f docker/Dockerfile .

if docker inspect "$NODE_NAME" >/dev/null 2>&1; then
    echo "==> 移除舊的 ${NODE_NAME}"
    docker rm -f "$NODE_NAME" >/dev/null
fi

# Doris BE 會檢查 vm.max_map_count；這個 sysctl 不是 namespaced，
# 在真實主機先設好，模擬節點與 Pod 都會吃到。
sysctl -w vm.max_map_count=2000000 >/dev/null 2>&1 || \
    echo "warn: 無法在主機設定 vm.max_map_count，BE 可能會啟動失敗" >&2

# 取主機允許的 nofile hard limit，最多要到 1048576。
host_nofile="$(ulimit -Hn)"
[[ "$host_nofile" == "unlimited" ]] && host_nofile=1048576
NOFILE_LIMIT="${NOFILE_LIMIT:-$(( host_nofile < 1048576 ? host_nofile : 1048576 ))}"
echo "==> 模擬節點的 nofile limit: ${NOFILE_LIMIT}"

echo "==> 啟動模擬節點 ${NODE_NAME}"
docker run -d \
    --name "$NODE_NAME" \
    --hostname "$NODE_HOSTNAME" \
    --privileged \
    --restart unless-stopped \
    `# Doris BE 會檢查可用的 fd 數量；能開多大就開多大。` \
    `# 注意：沒有 CAP_SYS_RESOURCE 的環境沒辦法超過主機的 hard limit，` \
    `# 這時要同步調低 be.conf 的 min_file_descriptor_number。` \
    --ulimit "nofile=${NOFILE_LIMIT}:${NOFILE_LIMIT}" \
    `# containerd 會把每個容器的 rootfs 掛在 /run/k3s/containerd/... 底下再從那裡 exec，` \
    `# 所以這個 tmpfs 一定要 exec；docker 的 --tmpfs 預設是 noexec，會讓所有 Pod 起不來。` \
    --tmpfs /run:rw,exec,nosuid,nodev,mode=755 \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -v "${NODE_NAME}-rancher:/var/lib/rancher/k3s" \
    -v "${NODE_NAME}-kubelet:/var/lib/kubelet" \
    -v "${STAGE_DIR}/images:/var/lib/rancher/k3s/agent/images:ro" \
    -p "${HOST_API_PORT}:6443" \
    -p "${HOST_MYSQL_PORT}:30030" \
    -p "${HOST_HTTP_PORT}:30080" \
    "$NODE_IMAGE" \
    server \
        --node-name "$NODE_HOSTNAME" \
        --write-kubeconfig-mode 644 \
        --tls-san 127.0.0.1 \
        --disable traefik \
        --disable metrics-server \
        --disable servicelb \
        --disable-helm-controller \
        --disable-network-policy \
        '--kubelet-arg=eviction-hard=memory.available<200Mi,nodefs.available<2%,imagefs.available<2%' \
        --kubelet-arg=image-gc-high-threshold=98 \
        --kubelet-arg=image-gc-low-threshold=95 \
        --kubelet-arg=max-pods=60

echo "==> 等待節點 Ready (含匯入離線 image，第一次約 2-5 分鐘)"
deadline=$((SECONDS + 600))
until docker exec "$NODE_NAME" kubectl get node "$NODE_HOSTNAME" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; do
    if (( SECONDS > deadline )); then
        echo "節點在 10 分鐘內沒有 Ready，最後 40 行日誌：" >&2
        docker logs --tail 40 "$NODE_NAME" >&2
        exit 1
    fi
    sleep 5
done

echo "==> 等待 Doris image 匯入 containerd"
deadline=$((SECONDS + 900))
until docker exec "$NODE_NAME" ctr -a /run/k3s/containerd/containerd.sock -n k8s.io images ls -q 2>/dev/null \
        | grep -q "${DORIS_BE_IMAGE}"; do
    if (( SECONDS > deadline )); then
        echo "warn: 沒等到 Doris image 匯入完成，請檢查 docker logs ${NODE_NAME}" >&2
        break
    fi
    sleep 10
done

echo
docker exec "$NODE_NAME" kubectl get node -o wide
echo
docker exec "$NODE_NAME" ctr -a /run/k3s/containerd/containerd.sock -n k8s.io images ls -q \
    | grep -E 'apache/doris' || true

# 把 kubeconfig 匯出到主機，方便從外面用 kubectl 連。
mkdir -p "$STAGE_DIR"
docker exec "$NODE_NAME" cat /etc/rancher/k3s/k3s.yaml \
    | sed "s#127.0.0.1:6443#127.0.0.1:${HOST_API_PORT}#" > "$STAGE_DIR/kubeconfig"
echo
echo "kubeconfig 已匯出：export KUBECONFIG=$STAGE_DIR/kubeconfig"
