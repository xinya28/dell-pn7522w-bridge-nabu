# 小米平板 5（nabu）+ 水龙内核 适配说明

本仓库从 [FlowerLing/dell-pen-bridge-liuqin](https://github.com/FlowerLing/dell-pen-bridge-liuqin)
fork，目标是把戴尔 PN7522W 的两个侧键桥接到 nabu 上的“焦点笔 Plus”。

原项目验证环境是小米平板 6 Pro（`liuqin`，内核 `5.10.237-Fuutao`，`nt36532_touch.ko`）。
桥接本体不依赖机型，唯一与内核/驱动绑定的是**采样点**：在触控驱动的
`nvt_ts_work_func` 里挂 kprobe，读取笔帧中的按钮字节。

## 已经做成可配置的部分

采样点参数从 `package/bin/probe.conf` 读取（`control.sh` 生成 kprobe 事件，
`check.sh` 用它检查驱动是否加载）。需要改的只有：

| 变量 | 含义 |
| --- | --- |
| `PROBE_MODULE` | 触控驱动在 `/proc/modules` 里的模块名 |
| `PROBE_SYMBOL` | 解析笔帧的函数符号，含编译器后缀（`$...`） |
| `PROBE_OFFSET` | 函数内偏移，kprobe 的挂载点 |
| `PROBE_B66` / `B71` / `B72` / `B75` / `B76` / `B77` | 笔帧各字节相对被探测栈帧的偏移 |
| `PROBE_FILTER` | trace 过滤条件 |

C 程序（`src/dell_pen_bridge.c`）只按**字节序号**解释数据，不关心偏移：

- `b66 == 1` 有效笔帧，`b66 == 255` 视为离笔；
- `b71/b72/b75/b76` 全零视为无有效感应；
- `b77 & 0x03` 为两个侧键（`0x02` 上侧键 → `KEY_PAGEUP`，`0x01` 下侧键 → `KEY_PAGEDOWN`）。

如果 nabu 的驱动帧布局和这组语义不同，需要改 C 源码并用 Zig 重新编译
（见根目录 README 的“从源码构建”）。

## 目前缺的东西

水龙内核的触控驱动是**按内核构建**的：符号后缀是编译器生成的，栈帧偏移取决于
编译器版本与优化。liuqin 的 `+0x7fc` / `+210..+221` 不能直接套到 nabu。

需要拿到目标内核里的触控驱动模块，二选一：

1. 水龙内核卡刷包 / ROM 里的 `/vendor/lib/modules/nt36672_touch.ko`
   （nabu 的触控是 Novatek NT36672，模块名可能是 `nt36672_touch`、`nt36xxx_touch`
   或类似，以实际为准）；
2. 一台已经跑水龙内核的 nabu，执行：

   ```sh
   adb shell su -c 'cat /proc/modules | grep -i nt3'
   adb shell su -c 'cat /proc/kallsyms | grep nvt_ts_work_func'
   ```

   并导出对应 `.ko`（`adb pull /vendor/lib/modules/<模块>.ko`）。

## 拿到 .ko 之后的步骤

1. 找函数与符号后缀：

   ```sh
   llvm-readelf -sW nt36672_touch.ko | grep -i nvt_ts_work
   ```

   静态函数在 kallsyms 里通常带 `$<hash>` 后缀；kprobe 写 `模块:符号$hash` 即可。

2. 反汇编定位笔帧：

   ```sh
   llvm-objdump -d --no-show-raw-insn nt36672_touch.ko | sed -n '/<nvt_ts_work_func/,/^$/p'
   ```

   在函数里找读笔上报缓冲区（`0x01` 有效帧判断、`0xff` 离笔判断、按钮位 `& 3`），
   记下这些字节相对栈帧的偏移，对应填入 `PROBE_B66…PROBE_B77`；
   kprobe 的挂载点取该处指令的偏移，填 `PROBE_OFFSET`。

3. 实机小步验证（不装模块也能测）：

   ```sh
   # 在手机上以 root 执行
   echo 'p:probe/raw <模块>:<符号>+<偏移> b66=+210($stack):x8 ...' >> /sys/kernel/tracing/kprobe_events
   cat /sys/kernel/tracing/trace_pipe
   ```

   笔尖在屏幕上移动、按侧键，确认 `b77` 的低两位随按键变化。

4. 填好 `probe.conf`，用 `sh package/bin/control.sh run 30` 试跑，再打 ZIP 安装。

## 现状

- 仓库已 fork 并改名为 `dell-pn7522w-bridge-nabu`；
- **顶部蓝牙键已在 nabu 上跑通**：设备名是 `Dell PN7522W`（不是 `Dell PN7522W Keyboard`），
  已改为前缀匹配，实测单击/双击/长按各产生一次手势（`events=3, last=long`）；
- **侧键不可用**：`probe.conf` 的 `PROBE_MODULE` 留空，`check.sh`/`control.sh`
  不再要求 kprobe，模块只跑顶部键；侧键桥接不启动；
- 二进制改用 NDK clang 交叉编译（`aarch64-linux-android30`，动态链接 bionic），
  不再依赖 Zig/musl；
- 未在 liuqin 上回归验证。

## 2026-11-26 探针结论：侧键不在笔帧里

用 `fastboot boot` 临时启动一个打过 printk 探针的内核（探针挂在 `nvt_ts_work_func`
的笔上报路径，打印 `sp+0x6a` 起的 40 字节），共抓到 3997 帧（悬停 + 落笔 + 按侧键）：

- 第 0 字节（`point_data[66]`）= `0x01`，始终是有效笔帧；
- 第 11 字节（`point_data[77]`，驱动里 `pen_btn1 = data[77] & 1`、`pen_btn2 = (data[77] >> 1) & 1`）
  **3997 帧全部是 `0x00`**，落笔并按住侧键时也不变；
- 驱动源码（`Re-s/xiaomi_kernel_nabu` 的 nt36523）确实会上报
  `BTN_STYLUS/BTN_STYLUS2`（`input_report_key(ts->pen_input_dev, BTN_STYLUS, pen_btn1)`），
  只是这一帧里按钮位永远是 0。

结论：**戴尔 PN7522W 的侧键在 nabu 的触控固件/笔协议里根本没有被发送**，不是驱动丢掉的，
也不是 kprobe 能读出来的——所以侧键桥接在这台机器上无解，除非换笔或改触控固件。
顶部蓝牙键不受影响，已经可用。

## 模块状态显示

`module.prop` 的 `description` 现在由 `control.sh refresh` 实时改写，格式：

```text
顶部键：运行中；笔：已连接；侧键：本内核不支持
```

`service.sh` 启动后每 30 秒刷新一次，KernelSU 模块页重新进入即可看到最新状态；
暂停/恢复、启停时也会立即刷新。作者字段为 `xinya28`。


## 2026-11-25 实机结论（kprobe 不可用）

测试机内核 `4.14.180-moon-os3-ga5805c039`（moon clang 20.0.0）。结论：**原项目的
kprobe 方案在这台机器上无法运行**，需要内核层改动。

1. 输入节点：笔是 `NVTCapacitivePen`（`/dev/input/event4`），能力位里**声明**了
   `BTN_STYLUS`、`BTN_STYLUS2`，但实测从不产生这两个事件。用
   `getevent -lt` 抓全部输入设备、让笔保持悬停并按两个侧键，只看到
   `ABS_X/ABS_Y/ABS_TILT_X/ABS_TILT_Y/ABS_DISTANCE` 和 `BTN_DIGI`，
   触屏节点（event3）也没有任何对应事件。后来用内核探针确认：不是驱动丢弃，
   而是笔帧里根本没有按钮位（见上一节）。
2. 内核配置（`/proc/config.gz`）：

   ```text
   # CONFIG_KPROBES is not set
   # CONFIG_FUNCTION_TRACER is not set
   CONFIG_BPF=y
   CONFIG_BPF_EVENTS=y
   CONFIG_MODULES=y
   # CONFIG_MODULE_SIG is not set
   ```

   `/sys/kernel/tracing` 下只有 `uprobe_events`，没有 `kprobe_events`，
   所以挂 kprobe 读笔帧这条路直接不通；没有 kprobe 也就没有 BPF kprobe 程序可用。
3. `/proc/kallsyms` 的地址被内核打散（root 且 `kptr_restrict=0` 也拿不到真实地址），
   不能靠 kallsyms 直接定位函数。但 `D:\Devices\Mipad5\boot.img` 里就是这颗内核
   （`Linux version 4.14.180-moon-os3-ga5805c039`，ramdisk 是 TWRP），
   可以用字符串 `nvt_ts_work_func` 的 `adrp/add` 引用在 Image 里定位函数再反汇编。

### 可行的后续路线（按代价排序）

- **A. 内核模块 inline hook**：`CONFIG_MODULES=y` 且无模块签名，理论上可加载模块，
  用 `kallsyms_lookup_name` 找 `nvt_ts_work_func`，把函数头改成跳转；没有 kprobe/ftrace
  可用，只能改内核 text。风险高，错误会 panic。
- **B. 改内核驱动后重编内核**：拿到 moon 内核源码，在 nt36523 驱动里把侧键上报成
  `BTN_STYLUS/BTN_STYLUS2`，重编并刷 boot。最干净，但要源码、clang 20 工具链，
  且 bootloader 必须能刷（当前 `ro.boot.flash.locked=1`，需确认）。
- **C. 放弃侧键**：保留本 fork 的采样点参数化，等内核支持 kprobe 或驱动上报侧键。

驱动是内置的（`/proc/modules` 为空），触摸 IC 为 Novatek NT36523
（`/dmesg` 里 `novatek_nt36523_k82_fw01_pen.bin`），与 liuqin 的 nt36532 同属
Novatek 笔驱动代码族，若走 B 路线，改动点相近。

