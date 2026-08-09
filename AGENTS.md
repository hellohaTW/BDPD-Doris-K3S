# AGENTS.md — 給 AI agent 的操作手冊

這個 repo 做兩件事：**（A）** 用 Docker 模擬一台 Ubuntu 22.04 節點、在裡面跑 k3s、再部署
Apache Doris；**（B）** 把同一份 Doris manifest 部署到**使用者既有的** Kubernetes / k3s 叢集。

讀完這份就能直接操作，不需要重新摸索。所有指令都在 repo 根目錄執行。

---

## 1. 先判斷要走哪條路

| 使用者想要的 | 走哪條 | 指令 |
|---|---|---|
| 「幫我模擬一個環境 / 我想測試看看 / 我沒有叢集」 | **A：模擬節點** | `scripts/01` → `02` → `03` → `04` |
| 「我已經有 k3s / K8s 叢集了」 | **B：既有叢集** | `scripts/deploy-to-existing-cluster.sh` |
| 「我有 Ubuntu 主機，想真的裝 k3s 上去」 | 官方安裝 + B | `curl -sfL https://get.k3s.io \| sh -` 之後走 B |

**不要**用 A 去「幫使用者在他的正式主機上裝 k3s」。A 是把 k3s 跑在一個 privileged 容器裡的
模擬環境，用途是測試與可拋棄式驗證，不是正式部署。

---

## 2. 路線 A：模擬節點（本 repo 自帶）

```bash
./scripts/01-stage-artifacts.sh   # 下載 k3s + 離線 image（第一次 ~5 分鐘，之後會略過）
./scripts/02-start-node.sh        # build Ubuntu 22.04 node image + 跑 k3s（~3-5 分鐘）
./scripts/03-deploy-doris.sh      # render(sandbox profile) + apply + 等 rollout
./scripts/04-verify.sh            # 等 BE Alive + SHOW FRONTENDS/BACKENDS + smoke test
```

拆掉：`./scripts/99-teardown.sh`（加 `--purge-stage` 連下載的素材一起刪）。

前置需求：主機要有 **Docker**、能開 `--privileged`、約 4 vCPU / 8GB+ RAM / 15GB+ 可用磁碟。
主機自己是哪個 Linux 發行版不重要（開發時是 Ubuntu 24.04），22.04 是被模擬出來的那一層。

## 3. 路線 B：既有叢集

```bash
./scripts/deploy-to-existing-cluster.sh --dry-run      # 先看 render 出來的 YAML
./scripts/deploy-to-existing-cluster.sh --yes --verify # 部署並跑 smoke test
```

它用**本機 kubectl 的目前 context**，部署前會印出 context 並要求確認（`--yes` 可略過）。
會先檢查 StorageClass 存在，不存在就列出可用的並中止。

也可以完全不用腳本：**`k8s/` 底下就是 `standard` profile 的預設值，可以直接
`kubectl apply -f k8s/`**（已驗證 render 結果與 `k8s/` 逐字節相同）。腳本多做的事只有
render 覆蓋值、前置檢查、等 rollout、驗證。

### B 的硬性前置需求（最常見的失敗原因）

每一台會跑 BE 的節點都要先做，否則 BE 起不來：

```bash
sysctl -w vm.max_map_count=2000000   # 沒設 start_be.sh 直接 exit 1
swapoff -a                            # BE 拒絕在有 swap 的機器上啟動
```

`vm.max_map_count` **不是 namespaced 的**，所以在節點上設一次就對所有 Pod 生效。

---

## 4. 設定旋鈕

全部是環境變數，定義在 `scripts/env.sh`，由 `scripts/lib/render.sh` 套進 YAML。
`DORIS_PROFILE` 只是換一組預設值，任何單項都能個別覆蓋。

| 變數 | standard（預設） | sandbox | 說明 |
|---|---|---|---|
| `DORIS_PROFILE` | `standard` | `sandbox` | sandbox = 離線側載 + 無 CAP_SYS_RESOURCE |
| `DORIS_IMAGE_PULL_POLICY` | `IfNotPresent` | `Never` | `Never` 一定要搭配已側載的 image |
| `DORIS_SKIP_CHECK_ULIMIT` | `false` | `true` | 跳過 start_be.sh 寫死的 ulimit 檢查 |
| `DORIS_MIN_FD` | `65536` | `16384` | be.conf 的 `min_file_descriptor_number` |
| `DORIS_NAMESPACE` | `doris` | ← | |
| `DORIS_STORAGE_CLASS` | `local-path` | ← | 非 k3s 叢集必須改 |
| `DORIS_FE_REPLICAS` / `DORIS_BE_REPLICAS` | `1` / `1` | ← | FE 要 HA 用奇數；`ELECT_NUMBER` 會自動跟著 FE 副本數 |
| `DORIS_FE_XMX` / `DORIS_FE_MEM_LIMIT` | `3072m` / `5Gi` | ← | limit 要比 Xmx 多留 1.5–2GB |
| `DORIS_BE_MEM_CONF` / `DORIS_BE_MEM_LIMIT` | `4G` / `6Gi` | ← | be.conf 的 mem_limit / Pod limit |
| `DORIS_FE_META_SIZE` / `DORIS_BE_STORAGE_SIZE` | `5Gi` / `10Gi` | ← | **StatefulSet 建好後不能改**，要改先砍掉重建 |
| `DORIS_VERSION` | `4.0.5-slim` | ← | 同時決定 FE/BE image tag |

記憶體預設值是在 4 vCPU / 15GB 機器上實測過的保守值。機器大就往上調。

---

## 5. 成功長什麼樣

`04-verify.sh` / `--verify` 通過時應該看到：

```
doris-node   Ready   control-plane,master   v1.31.5+k3s1   Ubuntu 22.04.5 LTS   containerd://1.7.23-k3s2
doris-fe-0   1/1   Running        Host: doris-fe-0.doris-fe.doris.svc.cluster.local  IsMaster: true  Alive: true
doris-be-0   1/1   Running        Host: doris-be-0.doris-be.doris.svc.cluster.local  TabletNum: 22   Alive: true
==> 存活的 BE 數量: 1
==> Smoke test 通過
```

**在跑過驗證之前不要回報「部署完成」。** Pod `Running` 不等於 Doris 可用 ——
BE 要等 FE 跑完一輪 heartbeat 才會變 `Alive`。

---

## 6. 已知陷阱：錯誤訊息 → 原因 → 處理

這些都是實際踩過並修掉的。看到對應訊息直接對照，不要重新診斷。

**`runc create failed: ... can't get final child's PID from pipe: EOF`**
（所有 Pod 卡在 `ContainerCreating`）
kubelet 把 pause 容器的 `oomScoreAdj` 設成 `-998`，但調降 `oom_score_adj` 需要
`CAP_SYS_RESOURCE`。缺這個 capability 時 runc 的 init 會在回報 PID 前就死掉。
→ 已由 `docker/runc-no-oom-adj.sh` 處理（把負值改寫成 0，透過 containerd 的 `BinaryName` 掛上）。
`node-entrypoint.sh` 會**先偵測再啟用**，一般主機不會走到。
檢查是否生效：`docker logs doris-k3s-node | grep "runc wrapper"`。

**所有 Pod 起不來、但 runc 手動跑最小 spec 卻是正常的**
Docker 的 `--tmpfs /run` 預設 `noexec`，而 containerd 把每個容器的 rootfs 掛在
`/run/k3s/containerd/...` 底下再從那裡 exec。
→ 必須 `--tmpfs /run:rw,exec,nosuid,nodev,mode=755`。

**`Set max number of open file descriptors to a value greater than 60000.`**（BE CrashLoopBackOff）
`start_be.sh` 寫死這個門檻。沒有 `CAP_SYS_RESOURCE` 就開不到。
→ `SKIP_CHECK_ULIMIT=true` + 調低 `min_file_descriptor_number`。
注意這個旗標**同時關掉 `vm.max_map_count` 與 swap 檢查**，所以那兩項要自己確保。

**`error setting rlimit type 7: operation not permitted`**（`docker run` 就失敗）
`--ulimit nofile` 設得比主機 hard limit 大。type 7 = `RLIMIT_NOFILE`。
→ `02-start-node.sh` 會用 `ulimit -Hn` 推導，不要寫死。

**`eviction percentage minimum reclaim nodefs.available must be positive: 0%`**（k3s 反覆重啟）
kubelet 不接受 `eviction-minimum-reclaim=...=0%`。
→ 不要傳這個參數，預設就是 0。
症狀是容器 `RestartCount` 一直增加、Pod 沒有新的 sandbox 嘗試紀錄。

**`Set kernel parameter 'vm.max_map_count' ...`**
→ 在**節點**上 `sysctl -w vm.max_map_count=2000000`（不是 namespaced，設一次全域生效）。

**BE 剛 rollout 完 `Alive: false`、`TabletNum: 0`、`Version` 空白**
不是錯誤，是 FE 還沒跑完第一輪 heartbeat。
→ 要 poll 等待，不要直接判定失敗。腳本裡已經有 3 分鐘的等待迴圈。

**`Unknown table 'backends'` / `Table [backends] does not exist in database [information_schema]`**
Doris 4.0.5 沒有 `information_schema.backends`。
→ 用 `SHOW BACKENDS\G` 再數 `Alive: true`。

**image 拉不動（Docker Hub blob CDN 被擋）**
開發環境的 egress policy 擋掉 `production.cloudfront.docker.com`、`registry.k8s.io`、
`quay.io`、`get.k3s.io`；放行 `github.com`（releases）、`mirror.gcr.io`。
→ 經 `mirror.gcr.io` 拉（`REGISTRY_MIRROR`），k3s 二進位與 airgap tarball 從 GitHub releases 下載。
**這是那個環境的狀況，換環境請先自己測，不要假設一樣。**
查可用的 Doris tag：`curl -s "https://hub.docker.com/v2/repositories/apache/doris/tags?page_size=100"`。

---

## 7. Doris image 的運作方式（改 manifest 前必讀）

官方 `apache/doris:fe-*` / `be-*` image 是為 doris-operator 設計的，但可以獨立使用：

- 進入點是 **`/opt/apache-doris/fe_entrypoint.sh <FE_HEADLESS_HOST>`** 和
  `be_entrypoint.sh <FE_HEADLESS_HOST>`。image 預設的 `ENTRYPOINT`（`init_fe.sh`）**不存在**，
  一定要自己覆蓋 `command`。
- **參數只能是主機名，不能帶 port**。腳本內部是 `mysql -h $addr -P $QUERY_PORT`，
  傳 `host:9030` 會失敗。port 由 `FE_QUERY_PORT` 或 conf 決定。
- `CONFIGMAP_MOUNT_PATH` 會把該目錄的檔案 **symlink 蓋掉整個 conf/**，
  所以 ConfigMap 裡必須是**完整**的 `fe.conf` / `be.conf`，不是片段。
- 走 **FQDN 模式**（`enable_fqdn_mode = true`），FE/BE 用 `hostname -f` 互相註冊。
  因此 FE 和 BE 各需要一個 headless Service，而且要
  `publishNotReadyAddresses: true`（Ready 之前就要能被解析到）。
  請把 `enable_fqdn_mode = true` 明確寫在 ConfigMap 裡 —— entrypoint 會想
  `echo >> fe.conf` 補上，但 ConfigMap 掛載是唯讀的，那個寫入會失敗（不會中斷，但不要依賴它）。
- `POD_INDEX` 是從 `hostname -f` 的第一段取最後一個 `-N`，所以 Pod 名稱結尾必須是序號
  （StatefulSet 天然符合）。
- `ELECT_NUMBER` 決定幾個 FE 參與選舉，超出的變成 observer。
- BE 的 entrypoint 找不到 master FE 就 `exit 1`，所以 `30-be.yaml` 有一個
  initContainer 先等 FE 起來，避免 CrashLoopBackOff 的雜訊。

---

## 8. 除錯用指令

```bash
# 模擬節點（路線 A）——節點本身就是一個容器
docker logs --tail 50 doris-k3s-node                 # k3s / kubelet 的日誌
docker inspect doris-k3s-node --format '{{.RestartCount}}'   # 一直增加 = k3s 在 crash loop
docker exec doris-k3s-node kubectl get pod -A
docker exec doris-k3s-node tail -50 /var/lib/rancher/k3s/agent/containerd/containerd.log

# Doris 本身（兩條路線都適用，路線 A 前面加 docker exec doris-k3s-node）
kubectl -n doris get pod,svc,pvc
kubectl -n doris logs doris-be-0                 # BE 的失敗原因通常在最後 10 行
kubectl -n doris logs doris-be-0 --previous      # CrashLoopBackOff 要看這個
kubectl -n doris describe pod doris-be-0         # 看 Events

# 直接下 SQL
kubectl -n doris exec -i doris-fe-0 -- mysql -h 127.0.0.1 -P 9030 -uroot -e 'SHOW BACKENDS\G'
```

---

## 9. 規則

- **驗證過才回報成功。** 至少要看到 BE `Alive: true` 和 smoke test 通過。
- **不要把 `.stage/` 加進 git**（約 2.7GB，已在 `.gitignore`）。
- **不要在沒有側載 image 的情況下設 `imagePullPolicy: Never`**，Pod 會永遠 `ErrImageNeverPull`。
- **改 `k8s/` 底下的 YAML 時要一併檢查 `scripts/lib/render.sh`。** render 用 sed 比對字串，
  對不上會直接失敗並指出是哪一項（這是刻意的，避免悄悄套用錯誤設定）。
  改完跑 `DORIS_PROFILE=standard` render 一次，結果應該與 `k8s/` 完全相同。
- **`docker volume rm` 之前要先 `docker rm -f` 容器**，否則 volume 還被佔用、刪除會靜默失敗，
  下一次啟動會沿用舊資料。
- 動使用者的正式叢集之前要先確認 context（`deploy-to-existing-cluster.sh` 已內建確認）。

---

## 10. 檔案地圖

| 路徑 | 用途 |
|---|---|
| `docker/Dockerfile` | Ubuntu 22.04 節點 image |
| `docker/node-entrypoint.sh` | 節點前置：cgroup、`/dev/kmsg`、sysctl、ulimit、偵測是否要啟用 runc wrapper |
| `docker/runc-no-oom-adj.sh` | runc wrapper（受限環境用，見 §6） |
| `scripts/env.sh` | 所有設定與 profile |
| `scripts/lib/render.sh` | 把設定套進 manifest，附驗證 |
| `scripts/lib/smoke-test.sql` | 共用的 SQL 驗證腳本 |
| `scripts/01`–`04`, `99` | 路線 A 的流程 |
| `scripts/deploy-to-existing-cluster.sh` | 路線 B |
| `k8s/` | `standard` profile 的 manifest，可直接 apply |
| `README.md` | 給人看的說明 |
