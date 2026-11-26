#!/system/bin/sh
MODDIR=${0%/*}
/data/adb/ksu/bin/busybox sh "$MODDIR/bin/top-control.sh" start
/data/adb/ksu/bin/busybox sh "$MODDIR/bin/control.sh" boot
# 定期把实时状态写回 module.prop，KernelSU 模块页刷新即可看到。
( while true; do
    sleep 30
    /data/adb/ksu/bin/busybox sh "$MODDIR/bin/control.sh" refresh >/dev/null 2>&1
  done ) &
