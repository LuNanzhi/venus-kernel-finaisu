#!/bin/bash
# inline-su-fix.sh - 修复 SUSFS Inline 后端下 adb shell 等进程无法使用 su 的问题
#
# 用法: bash scripts/inline-su-fix.sh <kernel_dir>
#
# 根因（run50/ak3-susfs-8 实机）：
# 1) 内核树 fs/exec.c 的 Inline 直调里，`susfs_is_current_proc_umounted()`
#    为真时直接 goto orig_flow，把 ksu_handle_execveat_sucompat 的重定向
#    整个跳过 —— 被标记 umounted/no_su 的进程（5.4 上两者共用
#    TIF_PROC_UMOUNTED 位）执行 su 时无人接管，落到不存在的
#    /system/bin/su -> "su: inaccessible or not found"。
#    Tracepoint 后端走 syscall hook 的 ksu_hook_execve_common，没有这层
#    跳过，所以 run43 正常。
# 2) FinaSU sucompat.c 的三处 no_su 早退对已授权 UID 也生效 ——
#    授权了 com.android.shell 也照样被 no_su 标记挡住。
#
# 修复：
# 1) fs/exec.c：把 sucompat 调用移到 umounted 检查之前（su 重定向先做，
#    umounted 跳过只作用于后续流程，与 Tracepoint 路径语义一致）。
# 2) sucompat.c：no_su 早退加 allowlist 豁免 —— 已授权 UID 即使带
#    no_su 标记也能走 su 重定向；未授权进程行为不变（防检测器）。

set -euo pipefail

KDIR="${1:?usage: inline-su-fix.sh <kernel_dir>}"
EXEC="$KDIR/fs/exec.c"
SUC="$KDIR/KernelSU/kernel/feature/sucompat.c"

[ -f "$EXEC" ] || { echo "::error::fs/exec.c not found"; exit 1; }

# ---------- 1) 内核树 fs/exec.c ----------
if grep -q 'ksu54_inline_su_fix' "$EXEC"; then
    echo "inline-su-fix: fs/exec.c already fixed"
elif grep -q 'susfs_is_current_proc_umounted())' "$EXEC" \
     && grep -q 'ksu_handle_execveat_sucompat' "$EXEC"; then
python3 - "$EXEC" <<'PYEXEC'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

old_head = (
    "\tif (likely(susfs_is_current_proc_umounted()))\n"
    "\t\tgoto orig_flow;\n"
    "\tif (static_branch_likely(&ksu_su_compat_enabled)) {\n"
)
new_head = (
    "\t/* ksu54_inline_su_fix: run sucompat FIRST so umounted/no_su-marked\n"
    "\t * processes (adb shell) can still exec su; the umounted short-cut\n"
    "\t * below only skips the rest of the flow, matching the Tracepoint\n"
    "\t * path in ksu_hook_execve_common. */\n"
    "\tif (static_branch_likely(&ksu_su_compat_enabled)) {\n"
)
if s.count(old_head) != 1:
    sys.exit('inline-su-fix: exec.c head anchor not unique (count=%d)' % s.count(old_head))
s = s.replace(old_head, new_head, 1)

old_tail = "\t}\norig_flow:\n"
if s.count(old_tail) < 1:
    sys.exit('inline-su-fix: exec.c orig_flow anchor not found')
new_tail = (
    "\t}\n"
    "\tif (likely(susfs_is_current_proc_umounted()))\n"
    "\t\tgoto orig_flow;\n"
    "orig_flow:\n"
)
s = s.replace(old_tail, new_tail, 1)

open(p, 'w', encoding='utf-8').write(s)
print('inline-su-fix: fs/exec.c reordered (sucompat before umounted skip)')
PYEXEC
else
    echo "inline-su-fix: fs/exec.c anchors not found (skip kernel-side fix)"
fi

# ---------- 2) FinaSU sucompat.c（Tracepoint 路径，Inline 模式不编译但保留兼容） ----------
if [ ! -f "$SUC" ]; then
    echo "inline-su-fix: sucompat.c not found (skip FinaSU-side fix)"
else
if grep -q 'ksu54_inline_su_fix' "$SUC"; then
    echo "inline-su-fix: sucompat.c already fixed"
else
python3 - "$SUC" <<'PYSUC'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

old = (
    "    if (unlikely(susfs_is_current_proc_no_su()))\n"
    "        goto do_orig"
)
# 三处早退：do_orig_execve / do_orig_facessat / do_orig_stat
n = 0
for label in ("do_orig_execve", "do_orig_facessat", "do_orig_stat"):
    o = "    if (unlikely(susfs_is_current_proc_no_su()))\n        goto %s;\n" % label
    nw = ("    if (unlikely(susfs_is_current_proc_no_su())\n"
          "        && !ksu_is_allow_uid_for_current(current_uid().val)) /* ksu54_inline_su_fix: allowlisted uid may still su */\n"
          "        goto %s;\n") % label
    c = s.count(o)
    if c:
        s = s.replace(o, nw)
        n += c
if n:
    open(p, 'w', encoding='utf-8').write(s)
    print('inline-su-fix: sucompat.c no_su early-exit exempted for allowlisted uid (%d sites)' % n)
else:
    print('inline-su-fix: sucompat.c no_su anchors not found (skip)')
PYSUC
fi
fi

# ---------- 3) FinaSU extension/susfs.c（Inline 路径的门禁） ----------
SUSC="$KDIR/KernelSU/kernel/extension/susfs.c"
if [ ! -f "$SUSC" ]; then
    echo "inline-su-fix: extension/susfs.c not found (skip inline gate fix)"
else
if grep -q 'ksu54_inline_su_fix' "$SUSC"; then
    echo "inline-su-fix: extension/susfs.c already fixed"
else
python3 - "$SUSC" <<'PYSUSC'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

old = (
    "static bool inline_sucompat_allowed(void)\n"
    "{\n"
    "    return ksu_su_compat_is_enabled() && !susfs_is_current_proc_no_su() &&\n"
    "           ksu_is_allow_uid_for_current(current_uid().val);\n"
    "}\n"
)
if s.count(old) != 1:
    sys.exit('inline-su-fix: inline_sucompat_allowed anchor not unique (count=%d)' % s.count(old))
new = (
    "static bool inline_sucompat_allowed(void)\n"
    "{\n"
    "    /* ksu54_inline_su_fix: allowlisted uid may su even when the no_su/\n"
    "     * umounted thread flag is set (adb shell inherits it in Inline mode).\n"
    "     * Unauthorized processes keep the original behaviour. */\n"
    "    return ksu_su_compat_is_enabled() && ksu_is_allow_uid_for_current(current_uid().val)\n"
    "           && !(susfs_is_current_proc_no_su() && !ksu_is_allow_uid_for_current(current_uid().val));\n"
    "}\n"
)
s = s.replace(old, new, 1)
open(p, 'w', encoding='utf-8').write(s)
print('inline-su-fix: inline_sucompat_allowed exempted for allowlisted uid')
PYSUSC
fi
fi

echo "inline-su-fix: DONE"
