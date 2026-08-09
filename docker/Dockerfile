# 模擬一台 Ubuntu 22.04 (jammy) 的主機，並在裡面安裝 k3s。
# 這個 image 代表「一台已經準備好跑 Doris 的 Ubuntu 22.04 節點」。
FROM mirror.gcr.io/library/ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive

# k3s / kubelet / containerd 在真實節點上會用到的套件，
# 外加 mysql-client 讓我們可以直接在節點上連 Doris FE。
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        iptables \
        iproute2 \
        ipset \
        conntrack \
        ethtool \
        socat \
        util-linux \
        mount \
        kmod \
        procps \
        psmisc \
        jq \
        less \
        vim-tiny \
        tzdata \
        mysql-client \
    && rm -rf /var/lib/apt/lists/*

# k3s 預設走 iptables-nft，但這個核心/容器組合用 legacy 後端比較穩定。
RUN update-alternatives --set iptables /usr/sbin/iptables-legacy \
    && update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

# k3s 二進位檔由 scripts/01-stage-artifacts.sh 事先下載到 .stage/ 底下。
COPY .stage/k3s /usr/local/bin/k3s
RUN chmod +x /usr/local/bin/k3s \
    && for c in kubectl crictl ctr; do ln -sf /usr/local/bin/k3s /usr/local/bin/$c; done

COPY docker/node-entrypoint.sh /usr/local/bin/node-entrypoint.sh
COPY docker/runc-no-oom-adj.sh /usr/local/bin/runc-no-oom-adj
RUN chmod +x /usr/local/bin/node-entrypoint.sh /usr/local/bin/runc-no-oom-adj

# 離線 image 放這裡，k3s 啟動時會自動匯入 containerd。
RUN mkdir -p /var/lib/rancher/k3s/agent/images

ENV KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
    CRI_CONFIG_FILE=/var/lib/rancher/k3s/agent/etc/crictl.yaml

EXPOSE 6443 30030 30040 30080

ENTRYPOINT ["/usr/local/bin/node-entrypoint.sh"]
