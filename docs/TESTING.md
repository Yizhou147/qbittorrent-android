# 测试

## 自动化（`test.yml`）

1. **patch-check**：对 4.3.9 / 4.6.7 / 5.2.3 / 5.3.0 / 5.3.1 的官方源码试打移植补丁，
   断言关键标记（共享库化、JNI 桥接、翻译可选化、rcc `--no-zstd`、异常兜底），
   防止升级 qBittorrent 版本时补丁失效（5.2.4 补丁集与 5.2.3 相同，未单列）
2. **unit-tests**：JVM 单元测试（`./gradlew test`），覆盖 `QbtConfig` 的配置写入/改写/端口校验
3. **emulator-smoke**：构建工作流成功后自动触发，在 Android 30 模拟器（x86_64 + ARM 指令翻译）
   安装 APK，通过 `adb forward` 轮询 WebUI 并断言 `/api/v2/app/version`；失败时上传 logcat

触发条件：push / PR 到 main 时跑 1、2；构建工作流完成后跑 3。

> **模拟器限制**：x86_64 模拟器的 ARM 翻译层没有实现 `fcvtzs`（double→int）等基线指令，
> qBittorrent 一计算 BT 状态就可能 SIGILL。因此 BT 行为不在模拟器上验证，改由真机脚本覆盖。

**复用已有构建产物跑冒烟**（不触发编译）：

```bash
gh workflow run test.yml -f build_run_id=<构建 run id>
gh workflow run test.yml          # 留空则取最近一次成功构建
```

APK artifact 保留 90 天。只有 APK 内容真的改了（Java / qb 补丁 / Qt 补丁）才需要重新构建。

## 真机功能测试

`ci/smoke-functional.sh` 覆盖模拟器无法验证的 BT 行为：

```bash
ANDROID_SERIAL=<serial> WEBSEED_PORT=18899 \
  bash ci/smoke-functional.sh com.qbittorrent.android 8080
```

前置：设备已连接（`adb devices` 可见），应用已安装且 WebUI 已就绪。

测试内容：

- 种子往返：添加 → 查询 → 停止 → 恢复 → 删除，并检查 `save_path`
- 离线 web seed 真实下载：本机起临时 HTTP 服务 + `adb reverse`，下载完成后比对设备端文件 SHA1
- 非法 URL / 畸形磁力 / 损坏 `.torrent`：断言进程不崩溃（不同 qb 版本返回码不同）
- VueTorrent 页面可达；测试结束清理种子、文件与 `adb reverse`

Windows 下运行需注意：

- `python3` 用 `py -3`；jq 用 Windows 版；`pkill -f` 需用只匹配 python.exe 的替代实现
- 原生 curl / Python 不识别 MSYS 的 `/tmp`，要么替换为 Windows 临时目录，要么在 WSL/Git Bash
  内配好对应工具
- `WEBSEED_PORT` 避开 8899（历史残留监听可能占用）
