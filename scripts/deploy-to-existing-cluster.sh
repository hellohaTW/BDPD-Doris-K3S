#!/usr/bin/env bash
# 把 Doris 部署到「你自己既有的」Kubernetes / k3s 叢集。
# 用本機的 kubectl 和目前的 context，不需要本 repo 的模擬節點。
#
# 用法：
#   ./scripts/deploy-to-existing-cluster.sh --dry-run    # 只 render，印出來看
#   ./scripts/deploy-to-existing-cluster.sh              # 部署（會先要你確認 context）
#   ./scripts/deploy-to-existing-cluster.sh --yes --verify
#
# 常用覆蓋：
#   DORIS_NAMESPACE=analytics DORIS_STORAGE_CLASS=gp3 \
#   DORIS_BE_REPLICAS=3 DORIS_BE_MEM_LIMIT=32Gi DORIS_BE_MEM_CONF=24G \
#     ./scripts/deploy-to-existing-cluster.sh
set -euo pipefail

# 一般叢集能自己去 registry 拉 image，也有正常的 ulimit。
export DORIS_PROFILE="${DORIS_PROFILE:-standard}"

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/render.sh"

ASSUME_YES=false
DRY_RUN=false
RUN_VERIFY=false
for arg in "$@"; do
    case "$arg" in
        --yes|-y)   ASSUME_YES=true ;;
        --dry-run)  DRY_RUN=true ;;
        --verify)   RUN_VERIFY=true ;;
        -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "未知參數：$arg" >&2; exit 1 ;;
    esac
done

command -v kubectl >/dev/null || { echo "找不到 kubectl" >&2; exit 1; }

RENDER_DIR="${RENDER_DIR:-${TMPDIR:-/tmp}/doris-rendered}"
echo "==> render manifests -> ${RENDER_DIR}"
render_manifests "$RENDER_DIR"
print_render_summary

if $DRY_RUN; then
    echo
    echo "==> --dry-run：以下是會被套用的 YAML"
    for f in "$RENDER_DIR"/*.yaml; do
        echo "----- $(basename "$f") -----"
        cat "$f"
    done
    exit 0
fi

# --- 前置檢查 -------------------------------------------------------------
context="$(kubectl config current-context 2>/dev/null || echo '<none>')"
echo
echo "==> 目標叢集"
echo "    context: ${context}"
kubectl cluster-info 2>/dev/null | head -1 || { echo "連不上叢集" >&2; exit 1; }

if ! kubectl get storageclass "$DORIS_STORAGE_CLASS" >/dev/null 2>&1; then
    echo
    echo "找不到 StorageClass '${DORIS_STORAGE_CLASS}'。現有的：" >&2
    kubectl get storageclass 2>&1 | sed 's/^/    /' >&2
    echo "請用 DORIS_STORAGE_CLASS=<名稱> 指定。" >&2
    exit 1
fi

cat <<EOF

==> 部署前請確認每一台會跑 BE 的節點都做過（BE 起不來最常見的兩個原因）：
      sysctl -w vm.max_map_count=2000000     # 沒設 BE 會直接 exit
      swapoff -a                              # BE 拒絕在有 swap 的機器上啟動
    要永久生效請寫進 /etc/sysctl.d/ 與 /etc/fstab。
EOF

if ! $ASSUME_YES; then
    echo
    read -r -p "要把 Doris 部署到 context '${context}' 的 namespace '${DORIS_NAMESPACE}' 嗎？[y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "已取消"; exit 0; }
fi

# --- 部署 -----------------------------------------------------------------
echo
echo "==> 套用 manifests"
for f in "$RENDER_DIR"/*.yaml; do
    echo "    - $(basename "$f")"
    kubectl apply -f "$f"
done

echo
echo "==> 等待 FE 就緒 (最久 10 分鐘)"
kubectl -n "$DORIS_NAMESPACE" rollout status statefulset/doris-fe --timeout=600s

echo
echo "==> 等待 BE 就緒 (最久 10 分鐘)"
kubectl -n "$DORIS_NAMESPACE" rollout status statefulset/doris-be --timeout=600s

echo
kubectl -n "$DORIS_NAMESPACE" get pod,svc,pvc

# --- 驗證 -----------------------------------------------------------------
# FE image 內就有 mysql client，直接在 Pod 裡連 127.0.0.1 最省事，
# 不用管叢集有沒有對外開 NodePort。
dsql() {
    kubectl -n "$DORIS_NAMESPACE" exec -i doris-fe-0 -- \
        mysql -h 127.0.0.1 -P 9030 -uroot --connect-timeout 5 "$@"
}
count_alive_be() {
    dsql -e 'SHOW BACKENDS\G' 2>/dev/null | grep -c '^ *Alive: true' || true
}

echo
echo "==> 等待 FE 把 BE 標成 Alive"
deadline=$((SECONDS + 180))
until [[ "$(count_alive_be)" -ge 1 ]]; do
    if (( SECONDS > deadline )); then
        echo "3 分鐘內沒有任何 BE 變成 Alive" >&2
        dsql -e 'SHOW BACKENDS\G' >&2 || true
        exit 1
    fi
    sleep 5
done

echo
dsql -e 'SHOW FRONTENDS\G' | grep -E 'Host|IsMaster|Alive|Role|Join'
echo
dsql -e 'SHOW BACKENDS\G' | grep -E 'Host|Alive|TabletNum|TotalCapacity|Version'
echo
echo "==> 存活的 BE 數量: $(count_alive_be)"

if $RUN_VERIFY; then
    echo
    echo "==> Smoke test：建庫 / 建表 / 寫入 / 查詢"
    dsql < "$REPO_ROOT/scripts/lib/smoke-test.sql"
    echo
    echo "==> Smoke test 通過"
fi

cat <<EOF

==> 完成。連線方式：
    kubectl -n ${DORIS_NAMESPACE} port-forward svc/doris-fe-nodeport 9030:9030 8030:8030
    mysql -h 127.0.0.1 -P 9030 -uroot          # 查詢
    http://127.0.0.1:8030                      # FE Web UI

    叢集內的其它 Pod 直接用：doris-fe.${DORIS_NAMESPACE}.svc.cluster.local:9030
EOF
