#!/usr/bin/env bash
# 拆掉模擬節點與它的資料 volume。.stage/ 下載的素材預設保留，
# 想一起清掉就加上 --purge-stage。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

docker rm -f "$NODE_NAME" 2>/dev/null || true
docker volume rm "${NODE_NAME}-rancher" "${NODE_NAME}-kubelet" 2>/dev/null || true

if [[ "${1:-}" == "--purge-stage" ]]; then
    rm -rf "$STAGE_DIR"
    echo "已刪除 $STAGE_DIR"
fi

echo "已清除模擬節點 ${NODE_NAME}"
