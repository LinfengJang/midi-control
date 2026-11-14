# SMK25II 打击垫灯光工具

已在当前 Mac 和 SINCOSMK25II 键盘上完成独立控制测试。第五个打击垫的临时变红、熄灯、恢复原色已通过设备读回，并由用户确认实体效果。全部十六个打击垫均已通过变红、熄灯、恢复和完整参数核对。上排原色为蓝绿色，下排原色为紫红色，均已各自恢复。十六个打击垫的逐个测试结果保存在本机归档中。原色为 `#00AA7F`。断电后的持久性尚未进行拔线实测；本工具不发送保存指令。

## 直接使用

打开 **Pad Lights.app**，现在是与键盘一致的十六格控制台，上排 1–8、下排 9–16。

- 点击多个方块即可多选，也可以全选、清空、选上排/下排或反选。
- **选中改色**：将选中的打击垫统一改为颜色选择器中的颜色，未选中部分保持不变。
- **选中关灯 / 选中开灯**：关灯时记住每个打击垫各自的颜色，开灯恢复各自关灯前的颜色；从未记录过亮灯颜色时使用当前选色。
- **恢复选中原色**：恢复该预设首次由此控制台读取并保存的颜色参考，不是固定把全部灯变成同一种颜色。
- **全部关灯 / 全部开灯**：直接操作全部十六个，无须先全选。
- **重新读取**：刷新实际颜色和当前预设；窗口里的色条与状态以设备读回值为准。

请先退出 MidiSuite。每次连接约需两秒准备；多个灯光操作不能同时运行。每次批量修改都先备份全部条目，操作后检查选中部分只有 RGB 改变，未选中条目及全局设置均未变化。失败会尝试恢复选中部分。

关闭窗口或菜单中选择退出即停止，没有后台服务、登录项或开机启动项。执行操作时会等待完成后再允许关闭。再次打开应用会将现有窗口显示到前台。

颜色备份、原色参考和关灯前颜色记录保存在当前用户的 `Library/Application Support/SMK25II Pad Lights`。这些数据不会上传。

## 命令接口

`bin/padlights` 是 Apple Silicon Mac 可执行文件，无第三方运行依赖。

```sh
./bin/padlights state
./bin/padlights batch --pads 1,9,16 --operation off --backup /tmp/selected-before-off.json --memory /tmp/last-lit.json
./bin/padlights batch --pads 1,9,16 --operation on --backup /tmp/selected-before-on.json --memory /tmp/last-lit.json
./bin/padlights batch --pads 1,9,16 --operation color --hex 0088FF --backup /tmp/selected-before-color.json --memory /tmp/last-lit.json
./bin/padlights batch --pads 1,9,16 --operation restore --reference /tmp/selected-before-off.json --backup /tmp/selected-before-restore.json --memory /tmp/last-lit.json
./bin/padlights verify-all --backup /tmp/all-pads-before-test.json
./bin/padlights restore-all --backup /tmp/all-pads-before-test.json
./bin/padlights devices
./bin/padlights read --pad 5
./bin/padlights color --pad 5 --hex FF0000 --backup /tmp/pad5-before-red.json
./bin/padlights off --pad 5 --backup /tmp/pad5-before-off.json
./bin/padlights on --backup /tmp/pad5-before-off.json
./bin/padlights restore --backup /tmp/pad5-before-red.json
./bin/padlights demo --pad 5 --hex 000000 --seconds 15 --backup /tmp/pad5-demo.json
./bin/padlights packet --pad 5 --preset 1 --hex 00AA7F
```

`verify-all` 会先备份十六个完整打击垫条目，再逐个红灯一秒、熄灯一秒、恢复，最后比较全部 74 字节条目和全局设置。`restore-all` 只恢复备份中的 RGB，不覆盖其他映射参数。

`--preset 1` 到 `--preset 8` 可指定预设；省略时读取设备当前预设。修改前必须给出不存在的绝对备份路径，避免覆盖旧备份。`on` 是从备份恢复原色，不假设所有打击垫原先都是同一颜色。`packet` 仅生成指令，不连接设备。可加 `--trace` 查看本次收发字节。

正常完成演示时会自动恢复；强行结束进程、拔线或断电可能中止恢复，重新连接后可用备份执行 `restore`。工具不宣称能通过网络或蓝牙控制；已验证的是当前 USB 连接。

## 目录

- `Pad Lights.app`：可直接打开的控制窗口。
- `bin/padlights`：独立命令工具。
- `Sources/PadLightProtocol`：可复用的 Swift 协议库。
- `Sources/NativeMIDI`：macOS CoreMIDI 传输层。
- `Sources/PadLights`：备份、设备识别、校验、操作和读回流程。
- `PROTOCOL.md`：研究结果、消息格式和二代专属地址计算。
- `Tests/`：七项协议测试，包含打包边界、已知报文、回复校验和非法输入。

## 构建

需要 Xcode Command Line Tools，无需联网下载依赖。

```sh
./build.sh
```

图形工具和 CLI 不会自动运行。包中不包含厂商应用、厂商固件、保存全部预设或固件擦写命令。

## 十六格控制台验证

已通过界面完成全部关灯、全部开灯，以及跨两排选择第 1、9、16 号进行开灯和统一改色。批量操作包含完整条目及未选中部分核对。多选绘制使用系统原生按钮。最后已通过独立 MIDI 指令恢复原色，全部十六个完整条目与测试前完全一致。窗口刷新和前台显示需在当前 Mac 解锁后确认。

### 低延迟连接

控制台在窗口存续期间复用一个 MIDI 连接，只有首次连接需要约两秒准备。关闭窗口后子进程随输入管道关闭而退出，不增加登录项或常驻服务。断线或操作失败后释放连接，下一次操作重新连接。

实机测量：首次完整读取约 2.7–3 秒，后续完整读取约 47–66 毫秒；单灯关闭及恢复含全部配置核对分别约 115 / 98 毫秒。十六个完整打击垫记录恢复后与测试前一致。批量操作耗时随选中数量变化。
