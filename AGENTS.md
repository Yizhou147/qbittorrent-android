# 项目协作约定（AGENTS.md）

## 网络：镜像站仅用于本地开发环境

**适用范围：仅限本机/ZCode 沙箱里的操作。** CI 工作流（GitHub Actions）跑在 GitHub 自有
runner 上，直连 GitHub / Google / Qt 官方源都很快，**不要在 workflow 里写镜像站**。

### 本地下载 GitHub 资源 → 用镜像
本机直连 GitHub 慢且不稳定（9MB 包直连约 18s，镜像约 6.5s），统一用助手脚本：

```bash
./scripts/gh-download.sh <github-url> <输出文件>
```

按 `ghfast.top` → `gh-proxy.com` → `ghproxy.net` → 直连 依次尝试，并校验文件大小。
镜像原理是在原始 URL 前拼前缀：
```
https://ghfast.top/https://github.com/<owner>/<repo>/archive/refs/tags/<tag>.tar.gz
```
`GH_MIRRORS` 环境变量可覆盖镜像列表；非 GitHub 源（dl.google.com、download.qt.io 等）
脚本也会自动回退直连。

### 本地 git push → 用已配置的代理
沙箱内已配置 `http.https://github.com/.proxy = http://127.0.0.1:38457`，实测可用（约 2s）。
**push 类镜像不可用**（gh-proxy 系列均为只读 HTTP 代理，只能下载；探活过的
push-capable 镜像全部失效），所以 push 不要尝试镜像。

偶发 `502` 是 GitHub 服务端瞬时故障，**直接重试即可，不要因为 push 失败去改代码**。

## 构建相关

- 原生库全量构建：`build-android.yml`（矩阵：qb 4.3.9 / 4.6.7 / 5.2.3）
- Qt 运行时库单独构建：`build-qt.yml`，产物提交进 `third-party/<qt_kind>/arm64-v8a/`
- 零编译快速出包：`build-apk-prebuilt.yml`（复用仓库 jniLibs 里的原生库）
- 测试：`test.yml`（patch-check / unit-tests / emulator-smoke，见 README「自动化测试」）
- `workflow_dispatch` 偶发 HTTP 500 时，改用 `git tag -f vX.Y-rcN && git push -f origin vX.Y-rcN` 触发

更多背景与遗留问题见 `工作总结.md`。
