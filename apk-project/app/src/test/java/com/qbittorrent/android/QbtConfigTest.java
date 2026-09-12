package com.qbittorrent.android;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.io.File;
import java.io.FileWriter;
import java.io.IOException;

public class QbtConfigTest {

    @Rule
    public TemporaryFolder tmp = new TemporaryFolder();

    // ===== parsePort =====

    @Test
    public void parsePort_valid() {
        assertEquals(Integer.valueOf(8080), QbtConfig.parsePort("8080"));
        assertEquals(Integer.valueOf(8080), QbtConfig.parsePort(" 8080\n"));
        assertEquals(Integer.valueOf(1024), QbtConfig.parsePort("1024"));
        assertEquals(Integer.valueOf(65535), QbtConfig.parsePort("65535"));
    }

    @Test
    public void parsePort_invalid() {
        assertNull(QbtConfig.parsePort(null));
        assertNull(QbtConfig.parsePort(""));
        assertNull(QbtConfig.parsePort("abc"));
        assertNull(QbtConfig.parsePort("1023"));   // 低于下限
        assertNull(QbtConfig.parsePort("65536"));  // 高于上限
        assertNull(QbtConfig.parsePort("-1"));
    }

    // ===== defaultConfigContent / writeDefaultConfig =====

    @Test
    public void defaultConfigContent_containsKeySettings() {
        String cfg = QbtConfig.defaultConfigContent(9090, "/sdcard/Download");
        assertTrue(cfg.contains("Session\\Port=59342"));
        assertTrue(cfg.contains("WebUI\\Port=9090"));
        assertTrue(cfg.contains("Downloads\\SavePath=/sdcard/Download"));
        assertTrue(cfg.contains("General\\Locale=zh_CN"));
        assertTrue(cfg.contains("WebUI\\Username=admin"));
        assertTrue(cfg.contains("[Preferences]"));
    }

    @Test
    public void writeDefaultConfig_createsFileOnce() throws IOException {
        File profile = tmp.newFolder("profile");
        assertTrue(QbtConfig.writeDefaultConfig(profile, 8080, "/data/downloads"));

        File cfg = new File(profile, "qBittorrent/config/qBittorrent.conf");
        assertTrue(cfg.exists());
        assertTrue(cfg.length() > 0);

        // 第二次调用: 已存在, 跳过
        assertFalse(QbtConfig.writeDefaultConfig(profile, 9090, "/other"));
        assertFalse(QbtConfig.readFile(cfg).contains("9090"));
    }

    // ===== replaceConfigValue =====

    @Test
    public void replaceConfigValue_replacesFirstMatchOnly() {
        String content = "[Preferences]\nWebUI\\Port=8080\nOther=1\nWebUI\\Port=8081\n";
        String result = QbtConfig.replaceConfigValue(content, "WebUI\\Port=", "WebUI\\Port=9090\n");
        assertTrue(result.contains("WebUI\\Port=9090"));
        assertFalse(result.contains("WebUI\\Port=8080"));
        assertTrue(result.contains("WebUI\\Port=8081")); // 第二处不动
        assertTrue(result.contains("Other=1"));
    }

    @Test
    public void replaceConfigValue_missingKey_unchanged() {
        String content = "[Preferences]\nOther=1\n";
        assertEquals(content, QbtConfig.replaceConfigValue(content, "WebUI\\Port=", "WebUI\\Port=9090\n"));
    }

    // ===== updateConfig =====

    private File prepareProfile(String initialContent) throws IOException {
        File profile = tmp.newFolder();
        File cfgDir = new File(profile, "qBittorrent/config");
        assertTrue(cfgDir.mkdirs());
        File cfg = new File(cfgDir, "qBittorrent.conf");
        try (FileWriter w = new FileWriter(cfg)) {
            w.write(initialContent);
        }
        return profile;
    }

    @Test
    public void updateConfig_replacesExistingKeys() throws IOException {
        File profile = prepareProfile(QbtConfig.defaultConfigContent(8080, "/old/path"));

        assertTrue(QbtConfig.updateConfig(profile, 9090, "/new/path", "/data/vuetorrent", true));

        String content = QbtConfig.readFile(new File(profile, "qBittorrent/config/qBittorrent.conf"));
        assertTrue(content.contains("WebUI\\Port=9090"));
        assertFalse(content.contains("WebUI\\Port=8080"));
        assertTrue(content.contains("Downloads\\SavePath=/new/path"));
        assertFalse(content.contains("/old/path"));
        assertTrue(content.contains("WebUI\\RootFolder=/data/vuetorrent"));
        assertTrue(content.contains("WebUI\\AlternativeUIEnabled=true"));
        assertTrue(content.contains("General\\Locale=zh_CN"));
        assertTrue(content.contains("Session\\Port=59342"));
    }

    @Test
    public void updateConfig_appendsMissingKeys() throws IOException {
        // 只有最简骨架, 所有目标 key 都缺失
        File profile = prepareProfile("[Preferences]\nWebUI\\Username=admin\n");

        assertTrue(QbtConfig.updateConfig(profile, 8080, "/downloads", "/data/vuetorrent", false));

        String content = QbtConfig.readFile(new File(profile, "qBittorrent/config/qBittorrent.conf"));
        assertTrue(content.contains("Downloads\\SavePath=/downloads"));
        assertTrue(content.contains("WebUI\\RootFolder=/data/vuetorrent"));
        assertTrue(content.contains("WebUI\\AlternativeUIEnabled=false"));
        assertTrue(content.contains("General\\Locale=zh_CN"));
        assertTrue(content.contains("Session\\Port=59342"));
    }

    @Test
    public void updateConfig_altUIDisabled() throws IOException {
        File profile = prepareProfile(QbtConfig.defaultConfigContent(8080, "/d"));

        assertTrue(QbtConfig.updateConfig(profile, 8080, "/d", "/data/vuetorrent", false));

        String content = QbtConfig.readFile(new File(profile, "qBittorrent/config/qBittorrent.conf"));
        assertTrue(content.contains("WebUI\\AlternativeUIEnabled=false"));
    }

    @Test
    public void updateConfig_missingFile_returnsFalse() throws IOException {
        File profile = tmp.newFolder();
        assertFalse(QbtConfig.updateConfig(profile, 8080, "/d", "/vuetorrent", true));
    }
}
