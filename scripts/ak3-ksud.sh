# AnyKernel3 附加脚本：刷完内核自动安装 ksud
# 作者：cvbyisme   共创：LuNanzhi
# 由 .github/workflows/build-susfs.yml 在打包时 append 到 anykernel.sh 末尾
#
# 设计依据：/data/adb 属于 device-encrypted（DE）存储，只要 /data 分区
# 挂载成功就可写，不需要 FBE 解锁。所以用「真实可写测试」判定，
# 而不是读 /data/system（那是 CE 区，TWRP 读不了，会误判）。
#
# 目录结构参考 LuNanzhi 的成功设备：
#   /data/adb/ksud          实体文件
#   /data/adb/ksu/bin/ksud  软链接 -> /data/adb/ksud

ksud_install() {
  ui_print " ";
  ui_print "- ksud installer by cvbyisme & LuNanzhi";
  KS="$AKHOME/ksud";
  if [ ! -f "$KS" ]; then
    ui_print "! ksud not in package, skip";
    return 0;
  fi
  chmod 755 "$KS" 2>/dev/null;

  OK=0;
  if mount 2>/dev/null | grep -qE " on /data type "; then
    if mkdir -p /data/adb/ksu/bin 2>/dev/null && echo probe > /data/adb/.ksud_wtest 2>/dev/null; then
      rm -f /data/adb/.ksud_wtest;
      cp -f "$KS" /data/adb/ksud 2>/dev/null && OK=1;
    fi
  fi

  if [ "$OK" = "1" ]; then
    chown 0:0 /data/adb/ksud /data/adb/ksu /data/adb/ksu/bin 2>/dev/null;
    chmod 755 /data/adb/ksud 2>/dev/null;
    chmod 700 /data/adb/ksu /data/adb/ksu/bin 2>/dev/null;
    ln -sf /data/adb/ksud /data/adb/ksu/bin/ksud 2>/dev/null;
    # TWRP 的 busybox 常缺 chcon，缺了也无所谓：ksud 运行时会把上下文
    # 重设成 u:object_r:ksu_file:s0
    if command -v chcon >/dev/null 2>&1; then
      chcon u:object_r:adb_data_file:s0 /data/adb/ksud 2>/dev/null;
      chcon u:object_r:adb_data_file:s0 /data/adb/ksu/bin/ksud 2>/dev/null;
    fi
    if [ -s /data/adb/ksud ]; then
      ui_print "  - /data/adb/ksud installed";
      ui_print "  - reboot, then open FinaSU (root ready)";
    else
      OK=0;
      ui_print "! /data/adb/ksud verify failed";
    fi
  else
    ui_print "! /data/adb not writable";
  fi

  # 总是再往 sdcard 放一份（兼作备份与兜底安装）
  SD="";
  for d in /data/media/0 /sdcard /external_sd /storage/emulated/0; do
    if [ -d "$d/Download" ]; then
      SD="$d";
      break;
    fi
  done
  if [ -n "$SD" ]; then
    cp -f "$KS" "$SD/Download/ksud" 2>/dev/null && chmod 755 "$SD/Download/ksud" 2>/dev/null;
    if [ "$OK" = "0" ]; then
      ui_print "  - ksud -> $SD/Download/ksud";
      printf "%s\n" \
        "#!/system/bin/sh" \
        "# run once after boot with root: su -c sh /sdcard/Download/ksud-install.sh" \
        "SRC=/sdcard/Download/ksud" \
        "[ -f \$SRC ] || exit 1" \
        "mkdir -p /data/adb/ksu/bin" \
        "cp -f \$SRC /data/adb/ksud && chmod 755 /data/adb/ksud && chown 0:0 /data/adb/ksud" \
        "ln -sf /data/adb/ksud /data/adb/ksu/bin/ksud" \
        "chmod 700 /data/adb/ksu /data/adb/ksu/bin" \
        "echo done" > "$SD/Download/ksud-install.sh";
      chmod 755 "$SD/Download/ksud-install.sh" 2>/dev/null;
      ui_print "  - after boot: su -c sh /sdcard/Download/ksud-install.sh";
    fi
  fi
  ui_print " ";
  return 0;
}

ksud_install;
