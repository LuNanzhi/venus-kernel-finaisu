# AnyKernel3 附加脚本：刷完内核自动安装 ksud（by cvbyisme）
# 由 .github/workflows/build-susfs.yml 在打包时 append 到 anykernel.sh 末尾
#
# 设计依据：/data/adb 属于 device-encrypted（DE）存储，只要 /data 分区
# 挂载成功就可写，不需要 FBE 解锁。所以用「真实可写测试」判定，
# 而不是读 /data/system（那是 CE 区，TWRP 读不了，会误判）。
#
# 目录结构参考 LuNanzhi/venus-kernel-finaisu 成功设备：
#   /data/adb/ksud          实体文件
#   /data/adb/ksu/bin/ksud  软链接 -> /data/adb/ksud
# 感谢 @LuNanzhi 提供的可行路线与成功设备 bugreport。

ksud_install() {
  ui_print " ";
  ui_print "- ksud: installing...";
  KS="$AKHOME/ksud";
  LOG=/tmp/ksud-ak3.log;
  : > $LOG 2>/dev/null;
  if [ ! -f "$KS" ]; then
    ui_print "! ksud not in package, skip";
    return 0;
  fi
  chmod 755 "$KS" 2>/dev/null;
  echo "src: $(ls -l $KS 2>&1)" >> $LOG;

  # ---- 判断 /data 是否真的挂载 ----
  DMOUNT=$(mount 2>/dev/null | grep -E " on /data type " | head -1);
  echo "data mount: $DMOUNT" >> $LOG;

  OK=0;
  if [ -n "$DMOUNT" ]; then
    # ---- 真实可写测试（DE 区） ----
    if mkdir -p /data/adb/ksu/bin 2>>$LOG && (echo probe > /data/adb/.ksud_wtest) 2>>$LOG; then
      rm -f /data/adb/.ksud_wtest;
      if cp -f "$KS" /data/adb/ksud 2>>$LOG; then
        OK=1;
      fi
    else
      echo "data namespace not writable" >> $LOG;
    fi
  fi

  if [ "$OK" = "1" ]; then
    chown 0:0 /data/adb/ksud /data/adb/ksu /data/adb/ksu/bin 2>>$LOG;
    chmod 755 /data/adb/ksud 2>>$LOG;
    chmod 700 /data/adb/ksu /data/adb/ksu/bin 2>>$LOG;
    ln -sf /data/adb/ksud /data/adb/ksu/bin/ksud 2>>$LOG;
    chcon u:object_r:adb_data_file:s0 /data/adb/ksud 2>>$LOG;
    chcon u:object_r:adb_data_file:s0 /data/adb/ksu/bin/ksud 2>>$LOG;
    # 验证落地
    if [ -s /data/adb/ksud ]; then
      echo "RESULT: OK  $(ls -lZ /data/adb/ksud 2>&1)" >> $LOG;
      echo "LINK  : $(ls -l /data/adb/ksu/bin/ksud 2>&1)" >> $LOG;
      ui_print "  - /data/adb/ksud installed (ready to use)";
    else
      OK=0;
      ui_print "! /data/adb/ksud verify failed";
    fi
  else
    ui_print "! /data/adb not writable -> fallback to sdcard";
  fi

  # ---- 总是往 sdcard 再放一份（兼作备份与兜底安装） ----
  SD="";
  for d in /data/media/0 /sdcard /external_sd /storage/emulated/0; do
    if [ -d "$d" ] && [ -d "$d/Download" ]; then
      SD="$d";
      break;
    fi
  done
  if [ -n "$SD" ]; then
    cp -f "$KS" "$SD/Download/ksud" 2>>$LOG && chmod 755 "$SD/Download/ksud" 2>>$LOG;
    echo "sdcard: $SD" >> $LOG;
    if [ "$OK" = "0" ]; then
      ui_print "  - ksud -> $SD/Download/ksud";
      ui_print "  - /data 没挂上时：开机后 su -c sh /sdcard/Download/ksud-install.sh";
      printf "%s\n" \
        "#!/system/bin/sh" \
        "# 有 root 后执行一次即可" \
        "SRC=/sdcard/Download/ksud" \
        "[ -f \$SRC ] || exit 1" \
        "mkdir -p /data/adb/ksu/bin" \
        "cp -f \$SRC /data/adb/ksud && chmod 755 /data/adb/ksud && chown 0:0 /data/adb/ksud" \
        "ln -sf /data/adb/ksud /data/adb/ksu/bin/ksud" \
        "chmod 700 /data/adb/ksu /data/adb/ksu/bin" \
        "echo done" > "$SD/Download/ksud-install.sh";
      chmod 755 "$SD/Download/ksud-install.sh" 2>/dev/null;
    fi
    cp -f $LOG "$SD/Download/ksud-ak3.log" 2>/dev/null;
    ui_print "  - log: Download/ksud-ak3.log";
  else
    ui_print "! sdcard not reachable, log kept in /tmp/ksud-ak3.log";
  fi
  ui_print " ";
  return 0;
}

ksud_install;
