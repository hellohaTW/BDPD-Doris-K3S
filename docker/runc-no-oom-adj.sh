#!/usr/bin/env bash
# runc wrapper：把 OCI spec 裡「負的」oomScoreAdj 改成 0，然後再交給真正的 runc。
#
# 為什麼需要：kubelet 會把 pause / 系統關鍵容器的 oomScoreAdj 設成 -998，
# 但要把 oom_score_adj 調得比自己低需要 CAP_SYS_RESOURCE。
# 在沒有這個 capability 的沙箱裡，runc 的 init 會在還沒回報 PID 前就死掉，
# 症狀是 "can't get final child's PID from pipe: EOF"，所有 Pod 都卡在 ContainerCreating。
#
# 只有在偵測到無法調降 oom_score_adj 時，node-entrypoint.sh 才會啟用這個 wrapper。
set -uo pipefail

REAL_RUNC="${REAL_RUNC:-/var/lib/rancher/k3s/data/current/bin/runc}"

bundle="."
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[i]}" in
        --bundle|-b)   bundle="${args[i+1]:-.}" ;;
        --bundle=*)    bundle="${args[i]#--bundle=}" ;;
    esac
done

config="$bundle/config.json"
if [[ -f "$config" ]]; then
    adj="$(/usr/bin/jq -r '.process.oomScoreAdj // empty' "$config" 2>/dev/null)"
    if [[ -n "$adj" && "$adj" =~ ^-[0-9]+$ ]]; then
        tmp="$(mktemp)"
        if /usr/bin/jq '.process.oomScoreAdj = 0' "$config" > "$tmp" 2>/dev/null; then
            cat "$tmp" > "$config"
        fi
        rm -f "$tmp"
    fi
fi

exec "$REAL_RUNC" "$@"
