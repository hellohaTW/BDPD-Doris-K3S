#!/usr/bin/env bash
# 把 k8s/ 底下的 manifest 依照 scripts/env.sh 的設定 render 成一份新的 YAML。
#
# k8s/ 裡放的是「一般叢集」可以直接 kubectl apply 的預設值，
# 這一層只負責把環境差異（離線側載、受限 sandbox、不同 StorageClass、
# 不同副本數與記憶體）套上去。
#
# 每個替換完成後都會驗證結果，對不上就直接失敗，
# 避免上游 YAML 改字之後 sed 悄悄沒套到、卻部署出錯誤設定。

_render_fail() {
    echo "render 失敗：$1" >&2
    echo "（k8s/ 底下的 YAML 可能被改過，導致 scripts/lib/render.sh 的樣式對不上）" >&2
    exit 1
}

# _expect <檔案> <grep 樣式> <說明>
_expect() {
    # -- 是必要的：像 "-Xmx3072m" 這種樣式開頭是 '-'，不然會被當成 grep 的選項。
    grep -qF -- "$2" "$1" || _render_fail "$3（在 $(basename "$1") 找不到：$2）"
}

# render_manifests <輸出目錄>
render_manifests() {
    local out="$1"
    rm -rf "$out"
    mkdir -p "$out"
    cp "$REPO_ROOT"/k8s/*.yaml "$out"/

    local fe="$out/20-fe.yaml"
    local be="$out/30-be.yaml"
    local cm="$out/10-configmaps.yaml"
    local ns="$out/00-namespace.yaml"

    # --- namespace ---------------------------------------------------------
    sed -i "s|^  name: doris$|  name: ${DORIS_NAMESPACE}|" "$ns"
    sed -i "s|^  namespace: doris$|  namespace: ${DORIS_NAMESPACE}|" "$out"/*.yaml
    _expect "$ns" "name: ${DORIS_NAMESPACE}" "namespace"
    _expect "$fe" "namespace: ${DORIS_NAMESPACE}" "namespace"

    # --- image 與 pull policy ---------------------------------------------
    sed -i "s|image: apache/doris:fe-[^ ]*|image: ${DORIS_FE_IMAGE}|" "$fe"
    sed -i "s|image: apache/doris:be-[^ ]*|image: ${DORIS_BE_IMAGE}|" "$be"
    sed -i "s|^\( *\)imagePullPolicy: .*|\1imagePullPolicy: ${DORIS_IMAGE_PULL_POLICY}|" "$fe" "$be"
    _expect "$fe" "image: ${DORIS_FE_IMAGE}" "FE image"
    _expect "$be" "image: ${DORIS_BE_IMAGE}" "BE image"
    _expect "$fe" "imagePullPolicy: ${DORIS_IMAGE_PULL_POLICY}" "imagePullPolicy"

    # --- StorageClass 與 PVC 大小 -----------------------------------------
    sed -i "s|^\( *\)storageClassName: .*|\1storageClassName: ${DORIS_STORAGE_CLASS}|" "$fe" "$be"
    sed -i "s|^\( *\)storage: 5Gi$|\1storage: ${DORIS_FE_META_SIZE}|" "$fe"
    sed -i "s|^\( *\)storage: 10Gi$|\1storage: ${DORIS_BE_STORAGE_SIZE}|" "$be"
    _expect "$fe" "storageClassName: ${DORIS_STORAGE_CLASS}" "StorageClass"
    _expect "$fe" "storage: ${DORIS_FE_META_SIZE}" "FE meta PVC 大小"
    _expect "$be" "storage: ${DORIS_BE_STORAGE_SIZE}" "BE storage PVC 大小"

    # --- 副本數 ------------------------------------------------------------
    # ELECT_NUMBER 決定有幾個 FE 參與選舉，超出的 pod 會變成 observer，
    # 所以跟著 FE 副本數走（HA 請用奇數）。
    sed -i "s|^\( *\)replicas: 1$|\1replicas: ${DORIS_FE_REPLICAS}|" "$fe"
    sed -i "s|^\( *\)replicas: 1$|\1replicas: ${DORIS_BE_REPLICAS}|" "$be"
    sed -i "/name: ELECT_NUMBER/{n;s|value: .*|value: \"${DORIS_FE_REPLICAS}\"|;}" "$fe"
    _expect "$fe" "replicas: ${DORIS_FE_REPLICAS}" "FE 副本數"
    _expect "$be" "replicas: ${DORIS_BE_REPLICAS}" "BE 副本數"

    # --- 受限環境的旗標 ----------------------------------------------------
    sed -i "/name: SKIP_CHECK_ULIMIT/{n;s|value: .*|value: \"${DORIS_SKIP_CHECK_ULIMIT}\"|;}" "$be"
    sed -i "s|^\( *\)min_file_descriptor_number = .*|\1min_file_descriptor_number = ${DORIS_MIN_FD}|" "$cm"
    _expect "$be" "value: \"${DORIS_SKIP_CHECK_ULIMIT}\"" "SKIP_CHECK_ULIMIT"
    _expect "$cm" "min_file_descriptor_number = ${DORIS_MIN_FD}" "min_file_descriptor_number"

    # --- 記憶體 ------------------------------------------------------------
    sed -i "s|-Xmx[0-9]*[mMgG] -Xms[0-9]*[mMgG]|-Xmx${DORIS_FE_XMX} -Xms${DORIS_FE_XMX}|" "$cm"
    sed -i "s|^\( *\)mem_limit = .*|\1mem_limit = ${DORIS_BE_MEM_CONF}|" "$cm"
    _expect "$cm" "-Xmx${DORIS_FE_XMX} -Xms${DORIS_FE_XMX}" "FE JVM heap"
    _expect "$cm" "mem_limit = ${DORIS_BE_MEM_CONF}" "BE mem_limit"

    # Pod 的 memory limit：只動 limits: 區塊底下那一行，不要碰 requests:。
    sed -i "/^ *limits:$/{n;n;s|^\( *\)memory: .*|\1memory: ${DORIS_FE_MEM_LIMIT}|;}" "$fe"
    sed -i "/^ *limits:$/{n;n;s|^\( *\)memory: .*|\1memory: ${DORIS_BE_MEM_LIMIT}|;}" "$be"
    _expect "$fe" "memory: ${DORIS_FE_MEM_LIMIT}" "FE memory limit"
    _expect "$be" "memory: ${DORIS_BE_MEM_LIMIT}" "BE memory limit"
}

# 把這次 render 用到的設定印出來，方便對照與除錯。
print_render_summary() {
    cat <<EOF
    profile           : ${DORIS_PROFILE}
    namespace         : ${DORIS_NAMESPACE}
    image             : ${DORIS_FE_IMAGE} / ${DORIS_BE_IMAGE}
    imagePullPolicy   : ${DORIS_IMAGE_PULL_POLICY}
    storageClass      : ${DORIS_STORAGE_CLASS}  (FE ${DORIS_FE_META_SIZE} / BE ${DORIS_BE_STORAGE_SIZE})
    replicas          : FE ${DORIS_FE_REPLICAS} / BE ${DORIS_BE_REPLICAS}
    memory            : FE ${DORIS_FE_MEM_LIMIT} (Xmx ${DORIS_FE_XMX}) / BE ${DORIS_BE_MEM_LIMIT} (mem_limit ${DORIS_BE_MEM_CONF})
    SKIP_CHECK_ULIMIT : ${DORIS_SKIP_CHECK_ULIMIT}
    min_fd            : ${DORIS_MIN_FD}
EOF
}
