#!/usr/bin/env bash
# 把所有離線素材準備到 .stage/：
#   * k3s 二進位檔
#   * k3s 內建元件的 airgap image tarball
#   * Doris FE / BE image (docker save 成 tar)
#
# 為什麼要離線：這個環境的對外流量走 host-local 的 HTTPS proxy (127.0.0.1)，
# 容器內的 containerd 連不到它，所以 k3s 沒辦法自己上網拉 image。
# 我們在主機上拉好、存成 tar，再放進 k3s 的 agent/images/ 讓它開機自動匯入。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

mkdir -p "$STAGE_DIR/images"

k3s_url_ver="${K3S_VERSION//+/%2B}"

if [[ ! -x "$STAGE_DIR/k3s" ]]; then
    echo "==> 下載 k3s ${K3S_VERSION}"
    curl -fsSL --retry 4 --retry-delay 2 -o "$STAGE_DIR/k3s" \
        "https://github.com/k3s-io/k3s/releases/download/${k3s_url_ver}/k3s"
    chmod +x "$STAGE_DIR/k3s"
else
    echo "==> k3s 已存在，略過下載"
fi

if [[ ! -f "$STAGE_DIR/images/k3s-airgap-images-amd64.tar.zst" ]]; then
    echo "==> 下載 k3s airgap images (pause / coredns / local-path-provisioner ...)"
    curl -fsSL --retry 4 --retry-delay 2 -o "$STAGE_DIR/images/k3s-airgap-images-amd64.tar.zst" \
        "https://github.com/k3s-io/k3s/releases/download/${k3s_url_ver}/k3s-airgap-images-amd64.tar.zst"
else
    echo "==> k3s airgap images 已存在，略過下載"
fi

stage_doris_image() {
    local image="$1" tar_name="$2"
    if [[ -f "$STAGE_DIR/images/$tar_name" ]]; then
        echo "==> $tar_name 已存在，略過"
        return
    fi
    echo "==> 透過 ${REGISTRY_MIRROR} 拉取 ${image}"
    docker pull "${REGISTRY_MIRROR}/${image}"
    docker tag "${REGISTRY_MIRROR}/${image}" "${image}"
    echo "==> docker save ${image} -> ${tar_name}"
    docker save "${image}" -o "$STAGE_DIR/images/$tar_name"
    # 主機上的 docker 不需要留著這份，省磁碟。
    docker rmi "${REGISTRY_MIRROR}/${image}" >/dev/null 2>&1 || true
}

stage_doris_image "$DORIS_FE_IMAGE" "doris-fe.tar"
stage_doris_image "$DORIS_BE_IMAGE" "doris-be.tar"

echo
echo "==> .stage 內容："
ls -lh "$STAGE_DIR" "$STAGE_DIR/images"
df -h / | tail -1
