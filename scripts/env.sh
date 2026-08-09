#!/usr/bin/env bash
# 所有腳本共用的設定。可以用環境變數覆蓋，例如：
#   DORIS_VERSION=4.0.7 ./scripts/01-stage-artifacts.sh
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

# --- Doris ----------------------------------------------------------------
# 用 -slim 版本，體積約是完整版的一半，對磁碟比較友善。
DORIS_VERSION="${DORIS_VERSION:-4.0.5-slim}"
DORIS_FE_IMAGE="apache/doris:fe-${DORIS_VERSION}"
DORIS_BE_IMAGE="apache/doris:be-${DORIS_VERSION}"

# 這個環境的 egress policy 擋掉了 Docker Hub 的 blob CDN，
# 所以透過 mirror.gcr.io 這個 Docker Hub 鏡像站拉取。
REGISTRY_MIRROR="${REGISTRY_MIRROR:-mirror.gcr.io}"

# --- 對外連接埠 (在真實主機上) --------------------------------------------
HOST_MYSQL_PORT="${HOST_MYSQL_PORT:-9030}"   # -> NodePort 30030 (Doris FE query)
HOST_HTTP_PORT="${HOST_HTTP_PORT:-8030}"     # -> NodePort 30080 (Doris FE web UI)
HOST_API_PORT="${HOST_API_PORT:-6443}"       # -> k3s apiserver

K8S_NAMESPACE="${K8S_NAMESPACE:-doris}"

# 在模擬節點裡執行 kubectl
kube() { docker exec -i "$NODE_NAME" kubectl "$@"; }
