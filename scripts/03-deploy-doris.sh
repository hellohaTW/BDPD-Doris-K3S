#!/usr/bin/env bash
# 把 Doris 部署到模擬節點上的 k3s。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

if ! docker inspect "$NODE_NAME" >/dev/null 2>&1; then
    echo "模擬節點 ${NODE_NAME} 不存在，請先執行 scripts/02-start-node.sh" >&2
    exit 1
fi

echo "==> 套用 manifests"
for f in "$REPO_ROOT"/k8s/*.yaml; do
    echo "    - $(basename "$f")"
    kube apply -f - < "$f"
done

echo
echo "==> 等待 FE 就緒 (最久 10 分鐘)"
kube -n "$K8S_NAMESPACE" rollout status statefulset/doris-fe --timeout=600s

echo
echo "==> 等待 BE 就緒 (最久 10 分鐘)"
kube -n "$K8S_NAMESPACE" rollout status statefulset/doris-be --timeout=600s

echo
kube -n "$K8S_NAMESPACE" get pod,svc,pvc -o wide
