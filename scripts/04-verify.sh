#!/usr/bin/env bash
# 用 MySQL 協定連進模擬節點上的 Doris，確認叢集狀態並跑一次建表/寫入/查詢。
set -euo pipefail
export DORIS_PROFILE="${DORIS_PROFILE:-sandbox}"
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

# 從模擬節點內部經由 NodePort 連 FE，等同於「從這台 Ubuntu 主機連 Doris」。
dsql() {
    docker exec -i "$NODE_NAME" mysql -h 127.0.0.1 -P 30030 -uroot --connect-timeout 5 "$@"
}

# Pod Ready 只代表連接埠開了；FE 要再跑完一輪 heartbeat 才會把 BE 標成 Alive。
count_alive_be() {
    dsql -e 'SHOW BACKENDS\G' 2>/dev/null | grep -c '^ *Alive: true' || true
}

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
echo "==> SHOW FRONTENDS"
dsql -e 'SHOW FRONTENDS\G' | grep -E 'Host|IsMaster|Alive|Role|Join'

echo
echo "==> SHOW BACKENDS"
dsql -e 'SHOW BACKENDS\G' | grep -E 'Host|Alive|TabletNum|SystemDecommissioned|TotalCapacity|Version'

echo
echo "==> 存活的 BE 數量: $(count_alive_be)"

echo
echo "==> Smoke test：建庫 / 建表 / 寫入 / 查詢"
dsql < "$REPO_ROOT/scripts/lib/smoke-test.sql"

echo
echo "==> Smoke test 通過"
echo "從這台主機連線： mysql -h 127.0.0.1 -P ${HOST_MYSQL_PORT} -uroot"
echo "FE Web UI：      http://127.0.0.1:${HOST_HTTP_PORT}"
