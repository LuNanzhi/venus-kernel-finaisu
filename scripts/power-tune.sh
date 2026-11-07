#!/bin/bash
# power-tune.sh - 把内核默认 governor 设为 schedutil(EAS/WALT 平台按负载调频)
#
# 用法: bash scripts/power-tune.sh <kernel_dir> [verify]
#
# 只改 out/.config(内核配置层),不改源码。venus_defconfig 未设置默认
# governor,Kconfig 会兜底成 performance(8 核满频,功耗高),这里在
# 构建时显式改为 schedutil。

set -u

KERNEL_DIR="${1:?usage: power-tune.sh <kernel_dir> [verify]}"
MODE="${2:-apply}"
CONFIG_BIN="$KERNEL_DIR/scripts/config"
CFG="$KERNEL_DIR/out/.config"

[ -x "$CONFIG_BIN" ] || { echo "::error::scripts/config not found under $KERNEL_DIR"; exit 1; }
[ -f "$CFG" ] || { echo "::error::$CFG missing (run make venus_defconfig first)"; exit 1; }

if [ "$MODE" = "verify" ]; then
    grep -qx 'CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y' "$CFG" \
        || { echo "::error::CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y missing"; exit 1; }
    grep -qx 'CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y' "$CFG" \
        && { echo "::error::CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y still set"; exit 1; }
    grep -qx 'CONFIG_LRU_GEN_ENABLED=y' "$CFG" \
        || { echo "::error::LRU_GEN_ENABLED=y missing (MGLRU would stay off)"; exit 1; }
    grep -q '^CONFIG_INIT_ON_ALLOC_DEFAULT_ON=y' "$CFG" \
        && { echo "::error::INIT_ON_ALLOC_DEFAULT_ON still enabled"; exit 1; }
    echo "power-tune gate: PASS"
    exit 0
fi

"$CONFIG_BIN" --file "$CFG" \
    --enable CPU_FREQ_DEFAULT_GOV_SCHEDUTIL \
    --disable CPU_FREQ_DEFAULT_GOV_PERFORMANCE
echo "power-tune: default governor -> schedutil"

# ---- 卡顿修复(B 档): 启用 MGLRU + 关掉分配清零 + 关 list 完整性检查 ----
# CONFIG_LRU_GEN=y 但 LRU_GEN_ENABLED 未开时 MGLRU 实际不生效(仍在用传统 LRU),
# 内存压力下回收抖动导致偶发卡顿; INIT_ON_ALLOC_DEFAULT_ON=y 会让每次页分配
# 都清零, 高频分配下有可观 CPU 开销; DEBUG_LIST 属调试开销。
"$CONFIG_BIN" --file "$CFG" \
    --enable LRU_GEN \
    --enable LRU_GEN_ENABLED \
    --disable INIT_ON_ALLOC_DEFAULT_ON \
    --disable DEBUG_LIST
echo "perf-fix: MGLRU on, init_on_alloc off, DEBUG_LIST off"