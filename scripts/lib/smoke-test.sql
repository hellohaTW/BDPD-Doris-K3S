-- Doris 基本功能驗證：建庫 / 建表 / 寫入 / 查詢
-- 被 scripts/04-verify.sh 與 scripts/deploy-to-existing-cluster.sh --verify 共用。
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

SELECT '--- SELECT * FROM demo.sales ---' AS '';
SELECT * FROM demo.sales ORDER BY dt, region;

SELECT '--- 依 region 匯總 ---' AS '';
SELECT region, COUNT(*) AS orders, SUM(amount) AS total
FROM demo.sales GROUP BY region ORDER BY total DESC;

SELECT '--- 版本 ---' AS '';
SELECT VERSION();
