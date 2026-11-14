#!/bin/bash
# venus-tune.sh - 构建期稳定性/运行时调优（只改 out/.config，不动内核源码）
#
# 用法: bash scripts/venus-tune.sh <kernel_dir> [verify]
#
# 目前包含：
#   - CONFIG_PANIC_TIMEOUT: 5 -> 15
#     panic 后给日志落盘 / ramoops 写入 / 复位留足时间（5s 偏短，
#     容易来不及把崩因写进 pstore，collect-logs 拿不到现场）。

set -u

KERNEL_DIR="${1:?usage: venus-tune.sh <kernel_dir> [verify]}"
MODE="${2:-apply}"
CONFIG_BIN="$KERNEL_DIR/scripts/config"
CFG="$KERNEL_DIR/out/.config"

[ -x "$CONFIG_BIN" ] || { echo "::error::scripts/config not found under $KERNEL_DIR"; exit 1; }
[ -f "$CFG" ] || { echo "::error::$CFG missing (run make venus_defconfig first)"; exit 1; }

if [ "$MODE" = "verify" ]; then
    v=$(grep -E '^CONFIG_PANIC_TIMEOUT=[0-9]+$' "$CFG" | cut -d= -f2)
    [ -n "$v" ] || { echo "::error::CONFIG_PANIC_TIMEOUT missing from .config"; exit 1; }
    [ "$v" -ge 10 ] || { echo "::error::CONFIG_PANIC_TIMEOUT=$v (<10, too short for ramoops)"; exit 1; }
    echo "venus-tune gate: PASS (panic_timeout=$v)"
    exit 0
fi

# ---- panic 超时：5s -> 15s ----
"$CONFIG_BIN" --file "$CFG" --set-val PANIC_TIMEOUT 15
echo "venus-tune: CONFIG_PANIC_TIMEOUT -> 15"
