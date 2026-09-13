# 项目协作约定（AGENTS.md）

## 网络：默认使用镜像站

本仓库开发环境的 GitHub 直连不稳定（下载慢/超时，偶发 502），约定：

### 下载 GitHub 资源 → 走镜像
用 `scripts/gh-download.sh <github-url> <输出文件>`，镜像顺序：
`https://ghfast.top` → `https://gh-proxy.com` → `https://ghproxy.net` → 直连兜底

镜像用法是在原始 GitHub URL 前拼镜像前缀，例如：
```
https://ghfast.top/https://github.com/qbittorrent/qBittorrent/archive/refs/tags/release-4.6.7.tar.gz
```
实测 9MB 包：镜像约 6.5s vs 直连约 18s。`GH_MIRRORS` 环境变量可覆盖镜像列表。

### git push → 走已配置的代理
沙箱内 `git config --global http.https://github.com/.proxy = http://127.0.0.1:38457`
已配置且实测顺畅（约 2s）。**push 类镜像不可用**（gh-proxy 系列均为只读 HTTP 代理，
探活过的 push-capable 镜像全部失效），因此 push 继续依赖该代理。
偶发 `502` 是 GitHub 服务端瞬时故障，重试即可；`git push` 失败时不要改动代码，直接重试。

### CI（GitHub Actions）不适用
workflow 跑在 GitHub 自有 runner 上，直连 GitHub/Google/Qt 官方源都是快的，
**不要把镜像写进 CI 下载步骤**，否则会引入额外故障点。

## 构建相关

- 原生库全量构建：`build-android.yml`（矩阵：qb 4.3.9 / 4.6.7 / 5.2.3）
- Qt 运行时库单独构建：`build-qt.yml`，产物提交进 `third-party/<qt_kind>/arm64-v8a/`
- 零编译快速出包：`build-apk-prebuilt.yml`（复用仓库 jniLibs 里的原生库）
- 测试：`test.yml`（patch-check / unit-tests / emulator-smoke，见 README「自动化测试」）
- `workflow_dispatch` 偶发 HTTP 500 时，改用 `git tag -f vX.Y-rcN && git push -f origin vX.Y-rcN` 触发

更多背景与遗留问题见 `工作总结.md`。
