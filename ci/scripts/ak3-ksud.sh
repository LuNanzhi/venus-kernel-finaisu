# AnyKernel3 附加脚本：刷完内核后自动安装 ksud
# 作者：cvbyisme  |  由 .github/workflows/build-susfs.yml 在打包时 append 到 anykernel.sh 末尾
#
# 目录结构参考自 LuNanzhi/venus-kernel-finaisu 成功设备的 /data/adb 布局：
#   /data/adb/ksud          实体文件（ksud 本体）
#   /data/adb/ksu/bin/ksud  软链接 -> /data/adb/ksud
# 感谢 @LuNanzhi 提供可行的 preflight 路线与成功设备 bugreport，
# 没有那两份日志，就定位不到「Android 16 seccomp 拦 reboot syscall」
# 与「/data/adb/ksud 缺失」这两个根因。
## ------------------------------------------------------------------
## ksud auto installer
## 目标：刷完内核后 /data/adb/ksud 自动就位；若 /data 不可写则
##       把 ksud 释放到 sdcard + 生成开机后一键安装脚本，绝不写入加密区。
## ------------------------------------------------------------------
ksud_install() {
  ui_print " ";
  ui_print "- Installing ksud to /data/adb ...";

  KS="$AKHOME/ksud";
  LOG=/tmp/ksud-ak3.log;
  : > $LOG;

  if [ ! -f "$KS" ]; then
    ui_print "! ksud binary missing in package, skip";
    return 0;
  fi
  chmod 755 "$KS" 2>/dev/null;
  echo "SRC: $KS" >> $LOG;
  ls -l "$KS" >> $LOG 2>&1;

  # --- 安全判定：只有 /data 真正解密才敢写 ---
  DATAOK=0;
  if [ -f /data/system/packages.xml ] || [ -d /data/system/users ]; then
    DATAOK=1;
  fi
  echo "DATAOK=$DATAOK" >> $LOG;

  if [ "$DATAOK" = "1" ]; then
    mkdir -p /data/adb/ksu/bin 2>>$LOG;
    if cp -f "$KS" /data/adb/ksud 2>>$LOG; then
      chown 0:0 /data/adb/ksud /data/adb/ksu /data/adb/ksu/bin 2>>$LOG;
      chmod 755 /data/adb/ksud;
      chmod 700 /data/adb/ksu /data/adb/ksu/bin;
      ln -sf /data/adb/ksud /data/adb/ksu/bin/ksud;
      chcon u:object_r:adb_data_file:s0 /data/adb/ksud 2>>$LOG;
      ls -lZ /data/adb/ksud /data/adb/ksu/bin/ksud >> $LOG 2>&1;
      ui_print "  - /data/adb/ksud installed";
      echo "RESULT: installed to /data/adb" >> $LOG;
    else
      DATAOK=0;
      ui_print "! copy to /data/adb failed, fallback";
    fi
  else
    ui_print "! /data/adb not writable (encrypted?), fallback to sdcard";
  fi

  # --- 兜底：释放到 sdcard ---
  SD="";
  for d in /data/media/0 /sdcard /storage/emulated/0; do
    if [ -d "$d/Download" ]; then
      SD="$d";
      break;
    fi
  done

  if [ -n "$SD" ]; then
    cp -f "$KS" "$SD/Download/ksud" 2>>$LOG && chmod 755 "$SD/Download/ksud" 2>>$LOG;
    echo "SD: $SD" >> $LOG;
    ui_print "  - ksud also at $SD/Download/ksud";
    if [ "$DATAOK" = "0" ]; then
      printf "%s\n" \
        "#!/system/bin/sh" \
        "# 有 root 后执行一次：su -c sh /sdcard/Download/ksud-install-after-boot.sh" \
        "SRC=/sdcard/Download/ksud" \
        "DST=/data/adb/ksud" \
        "[ -f \$SRC ] || { echo missing \$SRC; exit 1; }" \
        "mkdir -p /data/adb/ksu/bin" \
        "cp -f \$SRC \$DST && chmod 755 \$DST && chown 0:0 \$DST" \
        "ln -sf \$DST /data/adb/ksu/bin/ksud" \
        "chmod 700 /data/adb/ksu /data/adb/ksu/bin" \
        "ls -l \$DST /data/adb/ksu/bin/ksud" \
        "echo done" > "$SD/Download/ksud-install-after-boot.sh";
      chmod 755 "$SD/Download/ksud-install-after-boot.sh" 2>/dev/null;
      ui_print "  - fallback: Download/ksud-install-after-boot.sh";
    fi
    cp -f $LOG "$SD/Download/ksud-ak3.log" 2>/dev/null;
    ui_print "  - log: Download/ksud-ak3.log";
  else
    ui_print "! no writable sdcard found";
  fi
  return 0;
}

ksud_install;
