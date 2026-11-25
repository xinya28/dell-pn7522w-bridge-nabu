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
- 采样点已参数化，`probe.conf` 里仍是 liuqin 的值（nabu 值待第 1 步拿到驱动后填写）；
- 未在 nabu 上实机验证。
