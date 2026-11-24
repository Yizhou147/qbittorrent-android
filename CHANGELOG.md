# 更新日志

版本号与应用内「设置 → 关于」显示的一致。发布资产见 [Releases](https://github.com/Yizhou147/qbittorrent-android/releases)。

## v1.2.3 (2026-11-24)

- 新增 qBittorrent **5.3.1** 支持（libtorrent 2.0.14 / Qt 6.6.3 / C++20）；补丁集复用 5.3.0，
  050 补丁按 5.3.1 源码重新生成（上游 tracker 过滤新增 `TORRENT_USE_RTC` 分支）
- 5.3.1 作为最新变体改用基础包名 `com.qbittorrent.android`、应用名 `qBittorrent`
  （此前变体保留 `qb439`/`qb467`/`qb523`/`qb524`/`qb530` 后缀包名）
- 5.3.1 真机 `ci/smoke-functional.sh` 全部通过：种子往返、离线 web seed 真实下载（SHA1 一致）、
  非法 URL / 畸形磁力 / 损坏种子分别返回 202/409/415，只报错不崩溃
- 本 release 包含 4.3.9 / 4.6.7 / 5.3.1 三个变体 APK；5.2.3 / 5.2.4 / 5.3.0 继续使用历史版本的包
- 应用版本号升至 `1.2.3`（versionCode 5）

## v1.2.2 (2026-10-21)

- 新增 qBittorrent **5.3.0** 变体（libtorrent 2.0.14 / Qt 6.6.3 / C++20）；补丁集按 5.3.0
  源码重做并本地验证干净打上（`torrentdescriptor.cpp` 上游结构有变化，050 补丁重新生成）
- 5.3.0 真机 `ci/smoke-functional.sh` 全部通过：种子往返、离线 web seed 真实下载（SHA1 一致）、
  非法 URL / 畸形磁力 / 损坏种子只报错不崩溃
- 设置页版本号与右上角角标改为运行时读取；本版起显示 `1.2.2`（v1.2.1 包内设置页为 `1.2.1`，角标仍为 `v1.1`）
- 本 release 包含 4.3.9 / 4.6.7 / 5.3.0 三个变体 APK；5.2.3 / 5.2.4 继续使用 v1.2.1 的包

## v1.2.1 (2026-10-12)

- 新增 qBittorrent **5.2.4** 变体（libtorrent 2.0.14 / Qt 6.6.3 / C++20），补丁集复用 5.2.3 并验证干净打上
- **https tracker 证书校验修复**（`ci/patch-libtorrent.py` 显式注入系统 CA bundle，详见 [移植笔记](docs/PORTING.md)）：
  新装默认开启；从 v1.2.0 及更早覆盖安装的用户配置里存有 `false`，需在 WebUI 手动打开
- JNI 桥接显式包含 `<dlfcn.h>`（5.2.4 头文件链不再传递包含）
- 本 release 包含 4.3.9 / 4.6.7 / 5.2.3 / 5.2.4 四个变体 APK；真机 `ci/smoke-functional.sh` 全量通过

## v1.2.0 (2026-09-13)

- 支持 qBittorrent 4.3.9 / 4.6.7 / 5.2.3 三版本矩阵构建
- **修复 qb 5.2.3（Qt6）打开 WebUI 时闪退**：`JNI_OnLoad` 缓存 app ClassLoader +
  `getMethodID`/`getFieldID` NULL `jclass` 守卫（详见 [移植笔记](docs/PORTING.md)），
  真机与 CI emulator-smoke 均通过
- **修复 qb 5.2.3 添加种子闪退**（按 URL / 畸形磁力 / 损坏文件触发，Boost 异常跨 DSO 未捕获）
- **三个变体改为不同包名**（`.qb439` / `.qb467` / `.qb523`）可同时安装；
  release 包改用固定密钥签名（可覆盖安装）
- 5.2.3 变体升级到 Qt 6.6.3 + C++20
- libtorrent/qBittorrent 改用 API 35 target 编译（修复 Android 16 TLS 对齐问题）
- 修复 CI 构建产物缺少 Qt 库的问题
- Java 层动态加载 Qt5/Qt6 库；清理死代码；改用 nativeLibraryDir 标准 API
- CI 源码改从官方 release 下载 + 统一补丁集，移除 Git LFS 源码包

## v1.1.0 (2026-07-08)

- 新增设置页面：WebUI 切换、端口设置、下载路径设置
- 新增 VueTorrent WebUI 支持（默认中文）
- 新增关于页面：版本号、项目主页、致谢信息
- 修复端口设置不生效的问题
- 修复下载路径设置不生效的问题
- 修复 WebUI 切换后不生效的问题
- 优化启动流程：端口轮询 + 加载提示
- 移除日志功能

## v1.0.0 (2026-07-05)

- 初始发布
- qBittorrent 4.6.7 移植到 Android
- 支持 WebUI 中文界面
- 自动配置和密码设置
