package com.qbittorrent.android;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.FileWriter;
import java.io.IOException;

/**
 * qBittorrent.conf 的读写逻辑（纯 Java，无 Android 依赖，可单元测试）。
 *
 * 配置文件位于 <profile>/qBittorrent/config/qBittorrent.conf，
 * 由 Service 在每次启动时写入/更新。
 */
final class QbtConfig {

    private static final String SESSION_PORT = "59342";

    private QbtConfig() {
    }

    /** 解析端口号，无效或超出 1024-65535 返回 null */
    static Integer parsePort(String s) {
        if (s == null) return null;
        try {
            int port = Integer.parseInt(s.trim());
            if (port < 1024 || port > 65535) return null;
            return port;
        } catch (NumberFormatException e) {
            return null;
        }
    }

    /** 生成默认配置内容 */
    static String defaultConfigContent(int webuiPort, String downloadPath) {
        return "[BitTorrent]\n" +
                "Session\\Port=" + SESSION_PORT + "\n" +
                "Session\\QueueingSystemEnabled=false\n" +
                "Session\\ValidateHTTPSTrackerCertificate=false\n\n" +
                "[Meta]\n" +
                "MigrationVersion=6\n\n" +
                "[Preferences]\n" +
                "Downloads\\SavePath=" + downloadPath + "\n" +
                "WebUI\\LocalHostAuth=false\n" +
                "WebUI\\Username=admin\n" +
                "WebUI\\Port=" + webuiPort + "\n" +
                "General\\Locale=zh_CN\n";
    }

    /** 首次启动写入默认配置，已存在则跳过。返回是否写入 */
    static boolean writeDefaultConfig(File profileDir, int webuiPort, String downloadPath) {
        File cfgDir = new File(profileDir, "qBittorrent/config");
        cfgDir.mkdirs();
        File cfgFile = new File(cfgDir, "qBittorrent.conf");
        if (cfgFile.exists()) return false;
        try (FileWriter w = new FileWriter(cfgFile)) {
            w.write(defaultConfigContent(webuiPort, downloadPath));
            return true;
        } catch (IOException e) {
            return false;
        }
    }

    /** 每次启动强制更新 config 中的关键设置。返回是否成功 */
    static boolean updateConfig(File profileDir, int port, String downloadPath,
                                String altUIPath, boolean useAltUI) {
        File cfgFile = new File(profileDir, "qBittorrent/config/qBittorrent.conf");
        if (!cfgFile.exists()) return false;

        try {
            String content = readFile(cfgFile);

            // 替换 [BitTorrent] section 的值
            content = replaceConfigValue(content, "Session\\Port=", "Session\\Port=" + SESSION_PORT);

            // 替换 [Preferences] section 的值
            content = replaceConfigValue(content, "WebUI\\Port=", "WebUI\\Port=" + port);
            content = replaceConfigValue(content, "WebUI\\RootFolder=", "WebUI\\RootFolder=" + altUIPath);
            content = replaceConfigValue(content, "WebUI\\AlternativeUIEnabled=",
                    "WebUI\\AlternativeUIEnabled=" + (useAltUI ? "true" : "false"));
            content = replaceConfigValue(content, "Downloads\\SavePath=", "Downloads\\SavePath=" + downloadPath);
            content = replaceConfigValue(content, "General\\Locale=", "General\\Locale=zh_CN");

            // 如果某个 key 不存在，在合适的位置追加
            if (!content.contains("Session\\Port=")) {
                content = "[BitTorrent]\nSession\\Port=" + SESSION_PORT + "\n" + content;
            }
            if (!content.contains("WebUI\\RootFolder=")) {
                if (content.contains("WebUI\\Port=" + port)) {
                    content = content.replace("WebUI\\Port=" + port,
                            "WebUI\\Port=" + port + "\nWebUI\\RootFolder=" + altUIPath);
                } else {
                    content = "[Preferences]\nWebUI\\RootFolder=" + altUIPath + "\n" + content;
                }
            }
            if (!content.contains("WebUI\\AlternativeUIEnabled=")) {
                if (content.contains("WebUI\\RootFolder=" + altUIPath)) {
                    content = content.replace("WebUI\\RootFolder=" + altUIPath,
                            "WebUI\\RootFolder=" + altUIPath + "\nWebUI\\AlternativeUIEnabled=" + (useAltUI ? "true" : "false"));
                } else {
                    content = "[Preferences]\nWebUI\\AlternativeUIEnabled=" + (useAltUI ? "true" : "false") + "\n" + content;
                }
            }
            if (!content.contains("Downloads\\SavePath=")) {
                content = "[Preferences]\nDownloads\\SavePath=" + downloadPath + "\n" + content;
            }
            if (!content.contains("General\\Locale=")) {
                // General\Locale 必须在 [Preferences] section 下
                if (content.contains("[Preferences]")) {
                    content = content.replace("[Preferences]", "[Preferences]\nGeneral\\Locale=zh_CN");
                } else {
                    content = "[Preferences]\nGeneral\\Locale=zh_CN\n" + content;
                }
            }

            try (FileWriter w = new FileWriter(cfgFile)) {
                w.write(content);
            }
            return true;
        } catch (IOException e) {
            return false;
        }
    }

    /** 替换 config 中第一个匹配 keyPrefix 的行为 newLine，其余行原样保留 */
    static String replaceConfigValue(String content, String keyPrefix, String newLine) {
        String[] lines = content.split("\n");
        StringBuilder sb = new StringBuilder();
        boolean replaced = false;
        for (String line : lines) {
            String trimmed = line.trim();
            if (!replaced && trimmed.startsWith(keyPrefix)) {
                sb.append(newLine).append("\n");
                replaced = true;
            } else {
                sb.append(line).append("\n");
            }
        }
        return sb.toString();
    }

    /** 读取配置文件全部内容，失败返回空串 */
    static String readFile(File f) {
        StringBuilder sb = new StringBuilder();
        try (BufferedReader r = new BufferedReader(new FileReader(f))) {
            String line;
            while ((line = r.readLine()) != null) sb.append(line).append("\n");
        } catch (IOException ignored) {
        }
        return sb.toString();
    }
}
