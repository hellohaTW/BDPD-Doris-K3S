# Apache Doris on k3s（Ubuntu 22.04 模擬環境）

在一台 **模擬出來的 Ubuntu 22.04 節點** 上跑起 k3s，再把 **Apache Doris**（FE + BE）
部署上去，最後用 MySQL 協定連進去驗證。整套流程是腳本化、可重跑的。

實測結果（本 repo 內的腳本跑出來的）：

```
NAME         STATUS   ROLES                  VERSION        OS-IMAGE             CONTAINER-RUNTIME
doris-node   Ready    control-plane,master   v1.31.5+k3s1   Ubuntu 22.04.5 LTS   containerd://1.7.23-k3s2

NAME         READY   STATUS    RESTARTS   AGE
doris-be-0   1/1     Running   0          16s
doris-fe-0   1/1     Running   0          11m

Host: doris-fe-0.doris-fe.doris.svc.cluster.local   Role: FOLLOWER  IsMaster: true   Alive: true
Host: doris-be-0.doris-be.doris.svc.cluster.local   TabletNum: 22   Alive: true
Version: doris-4.0.5-rc01-59de8c4c524
```

---

## 架構

```
真實主機 (Ubuntu 24.04, Docker)
└── docker container「doris-k3s-node」  ← 這就是模擬出來的 Ubuntu 22.04 節點
    ├── /etc/os-release = Ubuntu 22.04.5 LTS   (k8s 的 OS-IMAGE 也是這個)
    ├── k3s server (embedded containerd + flannel + CoreDNS + local-path)
    └── Kubernetes namespace: doris
        ├── StatefulSet doris-fe  (1 replica) ── PVC meta 5Gi   ── Service doris-fe (headless)
        └── StatefulSet doris-be  (1 replica) ── PVC storage 10Gi ─ Service doris-be (headless)
                                                └ NodePort 30030/30080 → 主機的 9030 / 8030
```

FE 與 BE 之間走 **FQDN 模式**（`enable_fqdn_mode = true`）互相註冊，
所以兩邊都各自掛一個 headless Service，Pod 重建換 IP 也不會掉出叢集。

## 快速開始

```bash
./scripts/01-stage-artifacts.sh   # 下載 k3s + 離線 image（第一次約 5 分鐘）
./scripts/02-start-node.sh        # 建立 Ubuntu 22.04 節點並跑起 k3s
./scripts/03-deploy-doris.sh      # 部署 Doris FE + BE
./scripts/04-verify.sh            # SHOW FRONTENDS/BACKENDS + 建表寫入查詢
```

拆掉：

```bash
./scripts/99-teardown.sh                # 只砍節點與資料
./scripts/99-teardown.sh --purge-stage  # 連下載的素材一起砍
```

## 連線方式

| 用途 | 位址 |
|------|------|
| MySQL 協定（查詢） | `mysql -h 127.0.0.1 -P 9030 -uroot` |
| FE Web UI | http://127.0.0.1:8030 |
| kubectl | `export KUBECONFIG=.stage/kubeconfig` 或 `docker exec doris-k3s-node kubectl ...` |

`root` 預設沒有密碼，這是單機測試用的設定。要設密碼的話，建一個 Secret 帶 `password` 這個 key，
掛到 `/etc/basic_auth`，entrypoint 會自動拿去建管理帳號。

## 檔案

| 路徑 | 說明 |
|------|------|
| `docker/Dockerfile` | Ubuntu 22.04 節點 image（k3s、iptables、mysql-client…） |
| `docker/node-entrypoint.sh` | 節點開機前置：cgroup、`/dev/kmsg`、sysctl、ulimit，最後 exec k3s |
| `docker/runc-no-oom-adj.sh` | runc wrapper，見下方「受限環境的處理」 |
| `scripts/env.sh` | 版本與連接埠設定，全部可用環境變數覆蓋 |
| `scripts/0*.sh` | 依序執行的四個步驟 |
| `k8s/10-configmaps.yaml` | `fe.conf` / `be.conf` |
| `k8s/20-fe.yaml` | FE headless Service + NodePort + StatefulSet |
| `k8s/30-be.yaml` | BE headless Service + StatefulSet |

## 版本

| 元件 | 版本 |
|------|------|
| 模擬節點 OS | Ubuntu 22.04.5 LTS (jammy) |
| k3s | v1.31.5+k3s1（Kubernetes 1.31） |
| Apache Doris | 4.0.5（`apache/doris:fe-4.0.5-slim` / `be-4.0.5-slim`） |

改版本：`DORIS_VERSION=4.0.7 K3S_VERSION=v1.32.0+k3s1 ./scripts/01-stage-artifacts.sh`
（`k8s/*.yaml` 裡的 image tag 要一起改）。

## 資源設定

主機是 4 vCPU / 15 GB RAM，所以刻意調小：

| 元件 | CPU | 記憶體 limit | 堆積/mem_limit |
|------|-----|--------------|----------------|
| FE | 0.5–2 | 5 Gi | JVM `-Xmx3072m` |
| BE | 0.5–2 | 6 Gi | `mem_limit = 4G`、JVM `-Xmx1024m` |

要跑更大的資料量就同步調大 `k8s/10-configmaps.yaml` 和 StatefulSet 的 `resources`。

## 為什麼是離線（airgap）安裝

這個環境的對外流量走 **host-local 的 HTTPS proxy**（`127.0.0.1`），而且 egress policy 擋掉了
`production.cloudfront.docker.com`（Docker Hub 的 blob CDN）、`registry.k8s.io`、`quay.io`、`get.k3s.io`。

容器內的 containerd 連不到主機 loopback 上的 proxy，所以 k3s 自己上網拉 image 是不可能的。
做法改成：

1. 在**主機**上透過 `mirror.gcr.io`（Docker Hub 鏡像站，policy 有放行）拉 Doris image；
2. `docker save` 成 tar，跟 k3s 官方的 airgap image tarball 一起放進 `.stage/images/`；
3. 這個目錄掛到節點的 `/var/lib/rancher/k3s/agent/images/`，k3s 啟動時會自動匯入 containerd。

Pod 的 `imagePullPolicy` 因此設成 `Never`。

## 受限環境的處理

這個沙箱少了幾個一般主機有的權限，踩到的坑與對應處理都留在程式碼裡：

**1. `--tmpfs /run` 預設是 `noexec`**
containerd 把每個容器的 rootfs 掛在 `/run/k3s/containerd/...` 底下再從那裡 exec，
`noexec` 會讓所有 Pod 起不來。`02-start-node.sh` 改用
`--tmpfs /run:rw,exec,nosuid,nodev,mode=755`。

**2. 沒有 `CAP_SYS_RESOURCE` → 不能調降 `oom_score_adj`**
kubelet 會把 pause 容器的 `oomScoreAdj` 設成 `-998`，但把 `oom_score_adj` 調得比自己低需要
`CAP_SYS_RESOURCE`。少了它，runc 的 init 會在回報 PID 之前就死掉，錯誤訊息是

```
runc create failed: unable to start container process:
can't get final child's PID from pipe: EOF
```

所有 Pod 就卡在 `ContainerCreating`。處理方式是 `docker/runc-no-oom-adj.sh`：
一個 runc wrapper，把 OCI spec 裡的負值 `oomScoreAdj` 改成 `0` 再交給真正的 runc，
透過 containerd 的 `BinaryName` 掛上去。
`node-entrypoint.sh` 會**先偵測**再決定要不要啟用，一般主機上不會走到這條路。

**3. 同樣因為沒有 `CAP_SYS_RESOURCE`，nofile hard limit 卡在 20000**
但 `start_be.sh` 寫死要 `ulimit -n >= 60000`。BE 因此設 `SKIP_CHECK_ULIMIT=true`
（這個檢查同時涵蓋 `vm.max_map_count` 與 swap，兩者已經在節點層處理好：
`vm.max_map_count=2000000`、無 swap），實際的 fd 需求改由 `be.conf` 的
`min_file_descriptor_number = 16384` 控制。
在 nofile 開得夠大的正式環境，這兩項都可以拿掉。

## 已知限制

- 單 FE、單 BE，`replication_num = 1`，是功能驗證用的規模，不是高可用設定。
  要 HA 就把 replicas 調成 3（FE 記得同步調 `ELECT_NUMBER`）。
- 節點容器需要 `--privileged`，因為 k3s 要跑自己的 containerd 與 CNI。
- `root` 沒有密碼。
- 所有資料放在 local-path PV（即節點容器內的 docker volume），
  `99-teardown.sh` 會把它刪掉。
