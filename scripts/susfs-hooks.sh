#!/bin/bash
# susfs-hooks.sh - 补齐 SUSFS Inline 后端要求的内核调用点（5.4 vendor 树）
#
# FinaSU 的 KSU_HOOK_SUSFS_INLINE 后端是专门为「内联 SUSFS 内核补丁」设计的
# 钩子架构（见 FinaSU docs/builtin-integration.md），编译期由
# KernelSU/kernel/tools/check_susfs_inline.sh 强制校验调用点完整性：
#
#   drivers/input/input.c  ksu_handle_input_handle_event      (本树已有)
#   fs/exec.c              ksu_handle_execveat                (本树已有)
#   fs/exec.c              ksu_handle_execveat_sucompat       (本树已有)
#   fs/exec.c              ksu_handle_post_execveat_sucompat  (本脚本补齐)
#   fs/exec.c              ksu_setup_preinit_file             (本脚本补齐)
#   fs/exec.c              ksu_preinit_handle_post_execveat   (本脚本补齐)
#   fs/open.c              ksu_handle_faccessat               (本树已有)
#   fs/read_write.c        ksu_handle_sys_read                (本树已有)
#   fs/stat.c              ksu_handle_stat / vfs_fstat        (本树已有)
#   kernel/reboot.c        ksu_handle_sys_reboot              (本树已有)
#   kernel/sys.c           ksu_handle_setresuid               (本树已有)
#
# 另外检查脚本会拒绝上述文件里出现 CONFIG_KSU_MANUAL_HOOK 文本；本树
# fs/stat.c 残留三处 ReSukiSU 时代的 #ifdef CONFIG_KSU_MANUAL_HOOK 块
# （ksu_handle_newfstat_ret / ksu_handle_fstat64_ret，FinaSU 已不实现），
# 本脚本将其移除。
#
# 调用点语义与 FinaSU 官方 pinned SUSFS 补丁（commit 4a4cb1be）保持一致：
#   - is_su_session = !ksu_handle_execveat[_sucompat](...)（成功接管=0）
#   - PID 1 的 "/system/bin/init selinux_setup" execve 交给 preinit 接管，
#     直接执行失败时恢复原 filename 重试（goto orig_flow）
#
# 用法：susfs-hooks.sh <kernel-dir>   幂等，可重复运行。
set -euo pipefail

KDIR="${1:?usage: susfs-hooks.sh <kernel-dir>}"
[ -f "$KDIR/fs/exec.c" ] || { echo "ERROR: not a kernel tree: $KDIR" >&2; exit 1; }

EXEC="$KDIR/fs/exec.c"
STAT="$KDIR/fs/stat.c"
MARK="ksu54_susfs_inline_hooks"

echo "=== [susfs-hooks] fs/exec.c: post_execveat_sucompat + preinit call sites ==="
if grep -q "$MARK" "$EXEC"; then
  echo "  already applied (skip)"
else
python3 - "$EXEC" <<'PYEXEC'
import sys

p = sys.argv[1]
lines = open(p, encoding='utf-8').read().split('\n')

# ---- 1) extern block: insert the 3 new entry points inside the existing
#        CONFIG_KSU_SUSFS guard (between its #endif and the outer #endif) ----
sucompat_i = next(
    (i for i, l in enumerate(lines)
     if l.strip() == 'extern int ksu_handle_execveat_sucompat(int *fd,'), None)
if sucompat_i is None:
    raise SystemExit('ERROR: ksu_handle_execveat_sucompat extern anchor not found')

# find the #ifdef CONFIG_KSU_SUSFS that guards it, scanning backwards
guard_i = None
for i in range(sucompat_i, -1, -1):
    if lines[i].strip() == '#ifdef CONFIG_KSU_SUSFS':
        guard_i = i
        break
if guard_i is None:
    raise SystemExit('ERROR: #ifdef CONFIG_KSU_SUSFS guard not found')

# closing #endif of that guard = first #endif after the sucompat extern block
close_i = next(
    (i for i in range(sucompat_i, len(lines)) if lines[i].strip() == '#endif'), None)
if close_i is None:
    raise SystemExit('ERROR: KSU_SUSFS guard #endif not found')

new_externs = [
    'extern int ksu_handle_post_execveat_sucompat(int *fd,',
    '\t\t\t\t\tstruct filename **filename_ptr,',
    '\t\t\t\t\tvoid *argv, void *envp,',
    '\t\t\t\t\tint *flags, int *retval);',
    '#ifndef KSU_NO_PREINIT',
    'extern int ksu_setup_preinit_file(struct filename **filename_ptr,',
    '\t\t\t\t  struct user_arg_ptr *argv_user);',
    'extern int ksu_preinit_handle_post_execveat(int *fd,',
    '\t\t\t\t\tstruct filename **filename_ptr,',
    '\t\t\t\t\tvoid *argv_user, void *envp_user,',
    '\t\t\t\t\tint *flags, int *retval, int *preinit_fd);',
    '#endif',
]
lines[close_i:close_i] = ['/* %s: FinaSU SUSFS Inline entry points */' % 'ksu54_susfs_inline_hooks'] + new_externs
# adjust indices after insertion
shift = 1 + len(new_externs)

# ---- 2) do_execveat_common: session flags + preinit handoff + retry ----
fn_i = next(
    (i for i, l in enumerate(lines)
     if l.strip() == 'static int do_execveat_common(int fd, struct filename *filename,'), None)
if fn_i is None:
    raise SystemExit('ERROR: do_execveat_common not found')

ret_i = next(
    (i for i in range(fn_i, len(lines))
     if lines[i].strip() == 'return __do_execve_file(fd, filename, argv, envp, flags, NULL);'), None)
if ret_i is None:
    raise SystemExit('ERROR: __do_execve_file return anchor not found')

end_i = next(
    (i for i in range(ret_i + 1, len(lines)) if lines[i].strip() == '}'), None)
if end_i is None:
    raise SystemExit('ERROR: do_execveat_common closing brace not found')

new_fn = [
    'static int do_execveat_common(int fd, struct filename *filename,',
    '\t\t\t      struct user_arg_ptr argv,',
    '\t\t\t      struct user_arg_ptr envp,',
    '\t\t\t      int flags)',
    '{',
    '#ifdef CONFIG_KSU_SUSFS',
    '\tbool is_su_session = false;',
    '#ifndef KSU_NO_PREINIT',
    '\tbool is_ksu_preinit_session = false;',
    '\tint preinit_fd = 0;',
    '#endif',
    '#endif',
    '#ifdef CONFIG_KSU_SUSFS',
    '\tif (likely(susfs_is_current_proc_umounted()))',
    '\t\tgoto orig_flow;',
    '\tif (static_branch_likely(&ksu_su_compat_enabled)) {',
    '\t\tif (static_branch_unlikely(&susfs_is_sdcard_android_data_not_decrypted))',
    '\t\t\tis_su_session = !ksu_handle_execveat(&fd, &filename,',
    '\t\t\t\t\t\t     &argv, &envp, &flags);',
    '\t\telse',
    '\t\t\tis_su_session = !ksu_handle_execveat_sucompat(&fd, &filename,',
    '\t\t\t\t\t\t\t     &argv, &envp, &flags);',
    '\t}',
    '#ifndef KSU_NO_PREINIT',
    '\t/* FinaSU preinit: PID 1 "/system/bin/init selinux_setup" handoff */',
    '\tif (unlikely(current->pid == 1) && !is_su_session) {',
    '\t\tif (fd == AT_FDCWD || !(flags & AT_EMPTY_PATH)) {',
    '\t\t\tpreinit_fd = ksu_setup_preinit_file(&filename, &argv);',
    '\t\t\tif (preinit_fd > 0)',
    '\t\t\t\tis_ksu_preinit_session = true;',
    '\t\t}',
    '\t}',
    '#endif',
    'orig_flow:',
    '#elif defined(CONFIG_KSU)',
    '\t\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);',
    '#endif',
    '\thwui_mon_handle_exec(filename);',
    '\t{',
    '\t\tint retval = __do_execve_file(fd, filename, argv, envp, flags,',
    '\t\t\t\t      NULL);',
    '#ifdef CONFIG_KSU_SUSFS',
    '\t\tif (unlikely(is_su_session))',
    '\t\t\t(void)ksu_handle_post_execveat_sucompat(&fd, &filename,',
    '\t\t\t\t\t\t       &argv, &envp,',
    '\t\t\t\t\t\t       &flags, &retval);',
    '#ifndef KSU_NO_PREINIT',
    '\t\tif (unlikely(is_ksu_preinit_session)) {',
    '\t\t\tif (ksu_preinit_handle_post_execveat(&fd, &filename,',
    '\t\t\t\t\t\t    &argv, &envp,',
    '\t\t\t\t\t\t    &flags, &retval,',
    '\t\t\t\t\t\t    &preinit_fd)) {',
    '\t\t\t\tis_ksu_preinit_session = false;',
    '\t\t\t\tgoto orig_flow;',
    '\t\t\t}',
    '\t\t\treturn retval;',
    '\t\t}',
    '#endif',
    '#endif',
    '\t\treturn retval;',
    '\t}',
    '}',
]
lines[fn_i:end_i + 1] = new_fn

open(p, 'w', encoding='utf-8').write('\n'.join(lines))
print('  fs/exec.c patched: post_execveat_sucompat + preinit + su session flags')
PYEXEC
fi

echo "=== [susfs-hooks] fs/stat.c: remove rejected CONFIG_KSU_MANUAL_HOOK leftovers ==="
if grep -q 'CONFIG_KSU_MANUAL_HOOK' "$STAT"; then
python3 - "$STAT" <<'PYSTAT'
import re, sys

p = sys.argv[1]
s = open(p, encoding='utf-8').read()
before = s.count('CONFIG_KSU_MANUAL_HOOK')
# remove every  #ifdef CONFIG_KSU_MANUAL_HOOK ... #endif  block (3 known blocks)
s = re.sub(r'^[ \t]*#ifdef CONFIG_KSU_MANUAL_HOOK\n.*?^[ \t]*#endif\n',
           '', s, flags=re.M | re.S)
after = s.count('CONFIG_KSU_MANUAL_HOOK')
if after != 0:
    raise SystemExit('ERROR: %d KSU_MANUAL_HOOK references remain' % after)
open(p, 'w', encoding='utf-8').write(s)
print('  fs/stat.c: removed %d KSU_MANUAL_HOOK block(s)' % before)
PYSTAT
else
  echo "  fs/stat.c already clean (skip)"
fi

echo "=== [susfs-hooks] verification ==="
n1=$(grep -c 'ksu_handle_post_execveat_sucompat' "$EXEC" || true)
n2=$(grep -c 'ksu_setup_preinit_file' "$EXEC" || true)
n3=$(grep -c 'ksu_preinit_handle_post_execveat' "$EXEC" || true)
n4=$(grep -c 'CONFIG_KSU_MANUAL_HOOK' "$STAT" || true)
echo "  exec.c post_execveat_sucompat refs : $n1 (expect >= 2)"
echo "  exec.c setup_preinit_file refs    : $n2 (expect >= 2)"
echo "  exec.c preinit_handle_post refs   : $n3 (expect >= 2)"
echo "  stat.c KSU_MANUAL_HOOK refs       : $n4 (expect 0)"
if [ "$n1" -lt 2 ] || [ "$n2" -lt 2 ] || [ "$n3" -lt 2 ] || [ "$n4" -ne 0 ]; then
  echo "ERROR: susfs-hooks verification failed" >&2
  exit 1
fi
echo "=== [susfs-hooks] DONE ==="
