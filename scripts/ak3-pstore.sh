# AnyKernel3 附加脚本：安装 pstore/ramoops 日志收集器
# 作者：cvbyisme   共创：LuNanzhi
#
# 作用：往 /data/adb/service.d 放一个开机脚本，把 /sys/fs/pstore 里
# 上一次崩溃（panic/oops/watchdog）留下的日志复制到 /sdcard/venus-logs，
# 这样 collect-logs.sh 或手工都能把现场拿出来。
#
# 注意：service.d 由 ksud 以 root 在开机时执行；没有 root 的内核包
# 也不影响刷入（脚本只是放在那里）。

pstore_install() {
  ui_print " ";
  ui_print "- Install pstore log collector";
  if mount 2>/dev/null | grep -qE " on /data type "; then
    if mkdir -p /data/adb/service.d 2>/dev/null; then
      cat > /data/adb/service.d/venus-pstore.sh <<'PSTORE_EOF'
#!/system/bin/sh
# venus: 收集上次崩溃的 pstore/ramoops 日志到 /sdcard/venus-logs
OUT=/sdcard/venus-logs
mkdir -p "$OUT" 2>/dev/null
[ -d /sys/fs/pstore ] || exit 0
found=0
for f in /sys/fs/pstore/*; do
  [ -f "$f" ] || continue
  cp -f "$f" "$OUT/pstore-$(basename "$f")" 2>/dev/null && found=1
done
if [ "$found" = "1" ]; then
  chmod 644 "$OUT"/pstore-* 2>/dev/null
  # 读完清空，避免下次开机重复复制同一份
  for f in /sys/fs/pstore/*; do
    [ -f "$f" ] && : > "$f" 2>/dev/null
  done
fi
PSTORE_EOF
      chmod 755 /data/adb/service.d/venus-pstore.sh 2>/dev/null
      chown 0:0 /data/adb/service.d/venus-pstore.sh 2>/dev/null
      ui_print "  - /data/adb/service.d/venus-pstore.sh installed";
    else
      ui_print "! /data/adb not writable, pstore collector skipped";
    fi
  else
    ui_print "! /data not mounted, pstore collector skipped";
  fi
  ui_print " ";
  return 0;
}

pstore_install;
