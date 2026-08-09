#!/usr/bin/env bash
# 所有腳本共用的設定。全部可以用環境變數覆蓋，例如：
#   DORIS_VERSION=4.0.7 ./scripts/01-stage-artifacts.sh
#   DORIS_PROFILE=standard ./scripts/deploy-to-existing-cluster.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE_DIR="${STAGE_DIR:-$REPO_ROOT/.stage}"

# --- 模擬節點 -------------------------------------------------------------
UBUNTU_VERSION="${UBUNTU_VERSION:-22.04}"
NODE_IMAGE="${NODE_IMAGE:-doris-k3s-node:ubuntu-${UBUNTU_VERSION}}"
NODE_NAME="${NODE_NAME:-doris-k3s-node}"
NODE_HOSTNAME="${NODE_HOSTNAME:-doris-node}"

# --- k3s ------------------------------------------------------------------
K3S_VERSION="${K3S_VERSION:-v1.31.5+k3s1}"

# --- Doris image ----------------------------------------------------------
# 用 -slim 版本，體積約是完整版的一半，對磁碟比較友善。
DORIS_VERSION="${DORIS_VERSION:-4.0.5-slim}"
DORIS_FE_IMAGE="${DORIS_FE_IMAGE:-apache/doris:fe-${DORIS_VERSION}}"
DORIS_BE_IMAGE="${DORIS_BE_IMAGE:-apache/doris:be-${DORIS_VERSION}}"

# 有些網路環境擋掉 Docker Hub 的 blob CDN，改用這個 Docker Hub 鏡像站拉取。
# 網路正常的話設成 "docker.io" 就是直接走官方。
REGISTRY_MIRROR="${REGISTRY_MIRROR:-mirror.gcr.io}"

# --- 對外連接埠 (在真實主機上) --------------------------------------------
HOST_MYSQL_PORT="${HOST_MYSQL_PORT:-9030}"   # -> NodePort 30030 (Doris FE query)
HOST_HTTP_PORT="${HOST_HTTP_PORT:-8030}"     # -> NodePort 30080 (Doris FE web UI)
HOST_API_PORT="${HOST_API_PORT:-6443}"       # -> k3s apiserver

# ==========================================================================
# 部署 profile
# ==========================================================================
# standard : 一般的 k3s / Kubernetes 叢集。k8s/ 底下的 YAML 就是這組預設值，
#            所以可以直接 `kubectl apply -f k8s/`，不需要 render。
# sandbox  : 本 repo 的模擬節點，或任何「離線 + 沒有 CAP_SYS_RESOURCE」的環境。
#            image 走離線側載、跳過 BE 寫死的 ulimit 檢查、調低 fd 門檻。
#
# 每一個值都可以單獨用環境變數覆蓋，profile 只是換一組預設值。
DORIS_PROFILE="${DORIS_PROFILE:-standard}"

case "$DORIS_PROFILE" in
    standard)
        _def_pull_policy="IfNotPresent"
        _def_skip_ulimit="false"
        _def_min_fd="65536"
        ;;
    sandbox)
        # image 已經用 docker save side-load 進 containerd，不要再去 registry 拉。
        _def_pull_policy="Never"
        # start_be.sh 寫死要 ulimit -n >= 60000；沒有 CAP_SYS_RESOURCE 的環境過不了。
        _def_skip_ulimit="true"
        _def_min_fd="16384"
        ;;
    *)
        echo "未知的 DORIS_PROFILE: $DORIS_PROFILE (可用: standard / sandbox)" >&2
        exit 1
        ;;
esac

DORIS_NAMESPACE="${DORIS_NAMESPACE:-doris}"
DORIS_IMAGE_PULL_POLICY="${DORIS_IMAGE_PULL_POLICY:-$_def_pull_policy}"
DORIS_SKIP_CHECK_ULIMIT="${DORIS_SKIP_CHECK_ULIMIT:-$_def_skip_ulimit}"
DORIS_MIN_FD="${DORIS_MIN_FD:-$_def_min_fd}"

# k3s 內建 local-path；其它叢集要換成自己的 StorageClass。
DORIS_STORAGE_CLASS="${DORIS_STORAGE_CLASS:-local-path}"

# 副本數。FE 要 HA 請用奇數 (3)，ELECT_NUMBER 會跟著一起設。
DORIS_FE_REPLICAS="${DORIS_FE_REPLICAS:-1}"
DORIS_BE_REPLICAS="${DORIS_BE_REPLICAS:-1}"

# 記憶體。預設是在 4 vCPU / 15GB 的機器上實測過的保守值，
# 機器夠大就往上調（FE 的 k8s limit 要比 Xmx 多留 1.5-2GB 給 JVM 本身以外的部分）。
DORIS_FE_XMX="${DORIS_FE_XMX:-3072m}"
DORIS_FE_MEM_LIMIT="${DORIS_FE_MEM_LIMIT:-5Gi}"
DORIS_BE_MEM_CONF="${DORIS_BE_MEM_CONF:-4G}"      # be.conf 的 mem_limit
DORIS_BE_MEM_LIMIT="${DORIS_BE_MEM_LIMIT:-6Gi}"   # Pod 的 memory limit

# PVC 大小。注意 StatefulSet 建好之後大部分叢集不允許改，要改請先砍掉重建。
DORIS_FE_META_SIZE="${DORIS_FE_META_SIZE:-5Gi}"
DORIS_BE_STORAGE_SIZE="${DORIS_BE_STORAGE_SIZE:-10Gi}"

# 在模擬節點裡執行 kubectl
kube() { docker exec -i "$NODE_NAME" kubectl "$@"; }
