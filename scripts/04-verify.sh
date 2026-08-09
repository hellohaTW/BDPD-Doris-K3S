#!/usr/bin/env bash
# 用 MySQL 協定連進 Doris，確認叢集狀態並跑一次建表/寫入/查詢。
set -euo pipefail
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

alive=$(count_alive_be)
echo
echo "==> 存活的 BE 數量: ${alive}"
if [[ "$alive" -lt 1 ]]; then
    echo "沒有存活的 BE，中止 smoke test" >&2
    exit 1
fi

echo
echo "==> Smoke test：建庫 / 建表 / 寫入 / 查詢"
dsql <<'SQL'
DROP DATABASE IF EXISTS demo FORCE;
CREATE DATABASE demo;
USE demo;
CREATE TABLE sales (
    dt          DATE        NOT NULL,
    region      VARCHAR(32) NOT NULL,
    product     VARCHAR(64) NOT NULL,
    amount      DECIMAL(12,2) NOT NULL
)
DUPLICATE KEY(dt, region)
DISTRIBUTED BY HASH(region) BUCKETS 3
PROPERTIES ("replication_num" = "1");

INSERT INTO sales VALUES
    ('2026-08-01', 'APAC', 'widget', 1200.50),
    ('2026-08-01', 'EMEA', 'widget',  980.00),
    ('2026-08-02', 'APAC', 'gadget', 2310.75),
    ('2026-08-02', 'AMER', 'widget',  445.20),
    ('2026-08-03', 'APAC', 'widget',  610.00);
SQL

echo
echo "--- SELECT * FROM demo.sales ---"
dsql -e 'SELECT * FROM demo.sales ORDER BY dt, region;'

echo
echo "--- 依 region 匯總 ---"
dsql -e 'SELECT region, COUNT(*) AS orders, SUM(amount) AS total FROM demo.sales GROUP BY region ORDER BY total DESC;'

echo
echo "--- 版本 ---"
dsql -e 'SELECT VERSION();'

echo
echo "==> Smoke test 通過"
echo "從這台主機連線： mysql -h 127.0.0.1 -P ${HOST_MYSQL_PORT} -uroot"
echo "FE Web UI：      http://127.0.0.1:${HOST_HTTP_PORT}"
