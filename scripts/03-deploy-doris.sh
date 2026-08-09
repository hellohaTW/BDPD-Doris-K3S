#!/usr/bin/env bash
# 把 Doris 部署到「本 repo 模擬節點」上的 k3s（sandbox profile）。
# 要部署到你自己既有的叢集，請改用 scripts/deploy-to-existing-cluster.sh。
set -euo pipefail

# 模擬節點是離線側載 image、而且沒有 CAP_SYS_RESOURCE，固定走 sandbox profile。
export DORIS_PROFILE="${DORIS_PROFILE:-sandbox}"

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/render.sh"

if ! docker inspect "$NODE_NAME" >/dev/null 2>&1; then
    echo "模擬節點 ${NODE_NAME} 不存在，請先執行 scripts/02-start-node.sh" >&2
    exit 1
fi

RENDER_DIR="${RENDER_DIR:-$STAGE_DIR/rendered}"
echo "==> render manifests -> ${RENDER_DIR}"
render_manifests "$RENDER_DIR"
print_render_summary

echo
echo "==> 套用 manifests"
for f in "$RENDER_DIR"/*.yaml; do
    echo "    - $(basename "$f")"
    kube apply -f - < "$f"
done

echo
echo "==> 等待 FE 就緒 (最久 10 分鐘)"
kube -n "$DORIS_NAMESPACE" rollout status statefulset/doris-fe --timeout=600s

echo
echo "==> 等待 BE 就緒 (最久 10 分鐘)"
kube -n "$DORIS_NAMESPACE" rollout status statefulset/doris-be --timeout=600s

echo
kube -n "$DORIS_NAMESPACE" get pod,svc,pvc -o wide
