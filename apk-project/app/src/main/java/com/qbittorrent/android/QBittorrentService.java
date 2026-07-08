package com.qbittorrent.android;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.res.AssetManager;
import android.os.Build;
import android.os.Environment;
import android.os.IBinder;
import android.util.Log;

import androidx.localbroadcastmanager.content.LocalBroadcastManager;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.FileReader;
import java.io.FileWriter;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.Socket;
import java.net.URL;
import java.net.URLEncoder;

public class QBittorrentService extends Service {

    private static final String TAG = "QBittorrentService";
    public static final String ACTION_LOG = "com.qbittorrent.android.LOG";
    public static final String EXTRA_MESSAGE = "message";
    public static final String EXTRA_LEVEL = "level";
    private static final String CHANNEL_ID = "qbittorrent_service";
    private static final int NOTIFICATION_ID = 1;

    private static volatile boolean nativeMainRunning = false;

    @Override
    public void onCreate() {
        super.onCreate();
        createNotificationChannel();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        Notification notification = buildNotification();
        startForeground(NOTIFICATION_ID, notification);
        if (!nativeMainRunning) {
            new Thread(this::startQBittorrent).start();
        } else {
            broadcastLog("INFO", "qBittorrent 已在运行中");
        }
        return START_STICKY;
    }

    private void broadcastLog(String level, String message) {
        Log.d(TAG, "[" + level + "] " + message);
        Intent logIntent = new Intent(ACTION_LOG);
        logIntent.putExtra(EXTRA_MESSAGE, message);
        logIntent.putExtra(EXTRA_LEVEL, level);
        LocalBroadcastManager.getInstance(this).sendBroadcast(logIntent);
    }

    /** 运行测试二进制，返回 exitCode */
    private int runTest(String libDir, String binaryPath, String... args) {
        try {
            String[] cmd = new String[1 + args.length];
            cmd[0] = binaryPath;
            System.arraycopy(args, 0, cmd, 1, args.length);
            ProcessBuilder pb = new ProcessBuilder(cmd);
            pb.environment().put("LD_LIBRARY_PATH", libDir);
            pb.environment().put("QT_PLUGIN_PATH", libDir);
            pb.environment().put("HOME", new File(getFilesDir(), "config").getAbsolutePath());
            pb.environment().put("TMPDIR", getCacheDir().getAbsolutePath());
            pb.redirectErrorStream(true);
            Process p = pb.start();
            String output = readStream(p.getInputStream());
            int exit = p.waitFor();
            if (!output.isEmpty()) broadcastLog("INFO", "  output: " + output.trim());
            return exit;
        } catch (Exception e) {
            broadcastLog("ERROR", "  exception: " + e.getMessage());
            return -1;
        }
    }

    /** 读取流的全部内容（阻塞直到流关闭） */
    private String readStream(InputStream is) {
        StringBuilder sb = new StringBuilder();
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(is))) {
            String line;
            while ((line = reader.readLine()) != null) {
                sb.append(line).append("\n");
            }
        } catch (IOException ignored) {}
        return sb.toString();
    }

    /** 运行一条 shell 命令并返回 stdout+stderr */
    private String runShell(String cmd) {
        try {
            ProcessBuilder pb = new ProcessBuilder("sh", "-c", cmd);
            pb.environment().put("LD_LIBRARY_PATH", getNativeLibDir());
            pb.redirectErrorStream(true);
            Process p = pb.start();
            String output = readStream(p.getInputStream());
            p.waitFor();
            return output.trim();
        } catch (Exception e) {
            return "ERROR: " + e.getMessage();
        }
    }

    private String getNativeLibDir() {
        String apkPath = getPackageCodePath();
        File appDir = new File(apkPath).getParentFile();
        File libDir = new File(appDir, "lib/arm64");
        if (!libDir.exists()) {
            libDir = new File(appDir, "lib/arm64-v8a");
        }
        try {
            return libDir.getCanonicalPath();
        } catch (IOException e) {
            return libDir.getAbsolutePath();
        }
    }

    // JNI: call qBittorrent main() in-process (needed for Qt5 JNI initialization)
    private native int nativeMain(String[] args);

    /** 复制系统 CA 证书到 app 的 cacerts 目录（供 OpenSSL 使用） */
    private void copyCACerts(File profileDir) {
        File cacertsDir = new File(profileDir, "cacerts");
        File caBundle = new File(profileDir, "ca-certificates.crt");
        if (caBundle.exists() && caBundle.length() > 1000) {
            return;
        }
        cacertsDir.mkdirs();
        File systemCacerts = new File("/system/etc/security/cacerts");
        if (!systemCacerts.exists() || systemCacerts.list() == null) {
            broadcastLog("WARN", "系统 CA 证书目录不存在");
            return;
        }
        String[] certs = systemCacerts.list();
        int count = 0;
        try {
            java.io.FileOutputStream bundleOut = new java.io.FileOutputStream(caBundle);
            for (String cert : certs) {
                try {
                    File src = new File(systemCacerts, cert);
                    File dst = new File(cacertsDir, cert);
                    if (!dst.exists()) {
                        java.io.FileInputStream fis = new java.io.FileInputStream(src);
                        java.io.FileOutputStream fos = new java.io.FileOutputStream(dst);
                        byte[] buf = new byte[4096];
                        int len;
                        while ((len = fis.read(buf)) > 0) {
                            fos.write(buf, 0, len);
                        }
                        fis.close();
                        fos.close();
                    }
                    java.io.FileInputStream fis2 = new java.io.FileInputStream(src);
                    byte[] buf2 = new byte[4096];
                    int len2;
                    while ((len2 = fis2.read(buf2)) > 0) {
                        bundleOut.write(buf2, 0, len2);
                    }
                    bundleOut.write('\n');
                    fis2.close();
                    count++;
                } catch (Exception ignored) {}
            }
            bundleOut.close();
        } catch (Exception e) {
            broadcastLog("WARN", "CA 证书复制失败: " + e.getMessage());
        }
        broadcastLog("INFO", "已复制 " + count + " 个 CA 证书");
    }

    /** 递归删除目录 */
    private void deleteRecursive(File file) {
        if (file.isDirectory()) {
            File[] children = file.listFiles();
            if (children != null) {
                for (File child : children) {
                    deleteRecursive(child);
                }
            }
        }
        file.delete();
    }

    /** 从 assets 的 vuetorrent.zip 解压到应用数据目录 */
    private void copyQbWeb(File profileDir) {
        File targetDir = new File(profileDir, "vuetorrent");
        broadcastLog("INFO", "正在解压 VueTorrent...");
        // 删除旧目录，确保使用最新的 zip
        if (targetDir.exists()) {
            deleteRecursive(targetDir);
        }
        targetDir.mkdirs();
        try (InputStream is = getAssets().open("vuetorrent.zip");
             java.util.zip.ZipInputStream zis = new java.util.zip.ZipInputStream(is)) {
            java.util.zip.ZipEntry entry;
            byte[] buf = new byte[8192];
            while ((entry = zis.getNextEntry()) != null) {
                String name = entry.getName();
                // 跳过 zip 内的顶层目录前缀 (如 "vuetorrent/")
                int slash = name.indexOf('/');
                if (slash >= 0) name = name.substring(slash + 1);
                if (name.isEmpty()) { zis.closeEntry(); continue; }
                File outFile = new File(targetDir, name);
                if (entry.isDirectory()) {
                    outFile.mkdirs();
                } else {
                    outFile.getParentFile().mkdirs();
                    try (FileOutputStream fos = new FileOutputStream(outFile)) {
                        int len;
                        while ((len = zis.read(buf)) > 0) fos.write(buf, 0, len);
                    }
                }
                zis.closeEntry();
            }
            broadcastLog("INFO", "VueTorrent 解压完成: " + targetDir.getAbsolutePath());
            // 验证
            File indexHtml = new File(targetDir, "public/index.html");
            if (indexHtml.exists()) {
                broadcastLog("INFO", "index.html 存在，大小: " + indexHtml.length());
            } else {
                broadcastLog("WARN", "index.html 不存在！");
            }
        } catch (IOException e) {
            broadcastLog("WARN", "解压 VueTorrent 失败: " + e.getMessage());
        }
    }

    private void copyAssetDir(AssetManager am, String assetPath, File targetDir) throws IOException {
        targetDir.mkdirs();
        String[] list = am.list(assetPath);
        if (list != null && list.length > 0) {
            // 是目录，递归复制子项
            for (String child : list) {
                copyAssetDir(am, assetPath + "/" + child, new File(targetDir, child));
            }
        } else {
            // list 为空：可能是文件，也可能是 list() 失败的目录
            // 先尝试作为文件打开
            try (InputStream is = am.open(assetPath)) {
                try (FileOutputStream fos = new FileOutputStream(targetDir)) {
                    byte[] buf = new byte[8192];
                    int len;
                    while ((len = is.read(buf)) > 0) fos.write(buf, 0, len);
                }
            } catch (IOException e) {
                // 不是文件，可能是 list() 返回空的目录
                // 尝试已知的子路径
                broadcastLog("DEBUG", "asset 不是文件: " + assetPath + ", 尝试作为目录");
            }
        }
    }

    /** 写入默认配置（首次启动），已存在则跳过 */
    private boolean writeDefaultConfig(File profileDir) {
        File cfgDir = new File(profileDir, "qBittorrent/config");
        cfgDir.mkdirs();
        File cfgFile = new File(cfgDir, "qBittorrent.conf");
        if (cfgFile.exists()) return false; // 已有配置
        String downloadPath = readDownloadPath();
        String cfg = "[BitTorrent]\n" +
                "Session\\Port=59342\n" +
                "Session\\QueueingSystemEnabled=false\n" +
                "Session\\ValidateHTTPSTrackerCertificate=false\n\n" +
                "[Meta]\n" +
                "MigrationVersion=6\n\n" +
                "[Preferences]\n" +
                "Downloads\\SavePath=" + downloadPath + "\n" +
                "WebUI\\LocalHostAuth=false\n" +
                "WebUI\\Username=admin\n" +
                "WebUI\\Port=" + readPort() + "\n" +
                "General\\Locale=zh_CN\n";
        try (FileWriter w = new FileWriter(cfgFile)) {
            w.write(cfg);
            return true;
        } catch (IOException e) {
            broadcastLog("WARN", "写入默认配置失败: " + e.getMessage());
            return false;
        }
    }

    /** 每次启动强制更新 config 中的关键设置 */
    private void updateConfig(File profileDir) {
        File cfgFile = new File(profileDir, "qBittorrent/config/qBittorrent.conf");
        if (!cfgFile.exists()) return;

        String altUIPath = new File(profileDir, "vuetorrent").getAbsolutePath();
        String downloadPath = readDownloadPath();
        int port = readPort();
        boolean useAltUI = "vuetorrent".equals(readWebUIPref());

        try {
            // 读取全部内容
            String content = readFile(cfgFile);
            if (content == null) return;

            // 替换 [BitTorrent] section 的值
            content = replaceConfigValue(content, "Session\\Port=", "Session\\Port=59342");

            // 替换 [Preferences] section 的值
            content = replaceConfigValue(content, "WebUI\\Port=", "WebUI\\Port=" + port);
            content = replaceConfigValue(content, "WebUI\\RootFolder=", "WebUI\\RootFolder=" + altUIPath);
            content = replaceConfigValue(content, "WebUI\\AlternativeUIEnabled=", "WebUI\\AlternativeUIEnabled=" + (useAltUI ? "true" : "false"));
            content = replaceConfigValue(content, "Downloads\\SavePath=", "Downloads\\SavePath=" + downloadPath);
            content = replaceConfigValue(content, "General\\Locale=", "General\\Locale=zh_CN");

            // 如果某个 key 不存在，在合适的位置追加
            if (!content.contains("WebUI\\RootFolder=")) {
                content = content.replace("WebUI\\Port=" + port, "WebUI\\Port=" + port + "\nWebUI\\RootFolder=" + altUIPath);
            }
            if (!content.contains("WebUI\\AlternativeUIEnabled=")) {
                content = content.replace("WebUI\\RootFolder=" + altUIPath, "WebUI\\RootFolder=" + altUIPath + "\nWebUI\\AlternativeUIEnabled=" + (useAltUI ? "true" : "false"));
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

            // 写回文件
            try (FileWriter w = new FileWriter(cfgFile)) {
                w.write(content);
            }
            broadcastLog("INFO", "config 强制更新: port=" + port + " path=" + downloadPath + " altUI=" + useAltUI);
        } catch (IOException e) {
            broadcastLog("WARN", "更新 config 失败: " + e.getMessage());
        }
    }

    /** 替换 config 中的某个 key=value */
    private String replaceConfigValue(String content, String keyPrefix, String newLine) {
        // keyPrefix 例如 "WebUI\Port=" (Java string: "WebUI\\Port=")
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

    /** 读取配置文件内容 */
    private String readFile(File f) {
        StringBuilder sb = new StringBuilder();
        try (BufferedReader r = new BufferedReader(new FileReader(f))) {
            String line;
            while ((line = r.readLine()) != null) sb.append(line).append("\n");
        } catch (IOException ignored) {}
        return sb.toString();
    }

    /** 通过 API 配置下载路径（每次启动都执行） */
    private void configureSavePath() {
        String downloadPath = readDownloadPath();
        int port = readPort();
        try {
            String json = "{\"save_path\":\"" + downloadPath.replace("\\", "\\\\") + "\"}";
            URL url = new URL("http://127.0.0.1:" + port + "/api/v2/app/setPreferences");
            HttpURLConnection conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("POST");
            conn.setDoOutput(true);
            conn.setConnectTimeout(3000);
            conn.setReadTimeout(3000);
            conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded");
            String params = "json=" + URLEncoder.encode(json, "UTF-8");
            try (OutputStream os = conn.getOutputStream()) {
                os.write(params.getBytes("UTF-8"));
            }
            int code = conn.getResponseCode();
            conn.disconnect();
            if (code == 200) {
                broadcastLog("INFO", "已设置下载路径: " + downloadPath);
            } else {
                broadcastLog("WARN", "设置下载路径失败，HTTP " + code);
            }
        } catch (Exception e) {
            broadcastLog("WARN", "设置下载路径失败: " + e.getMessage());
        }
    }

    /** 通过 API 配置 AlternativeUI（每次启动都执行，兼容已安装用户） */
    private void configureAlternativeUI(File profileDir) {
        // 读取 WebUI 偏好
        String uiPref = readWebUIPref();
        if (!"vuetorrent".equals(uiPref)) {
            broadcastLog("INFO", "用户选择默认 WebUI，跳过 VueTorrent 配置");
            return;
        }

        File altUIPath = new File(profileDir, "vuetorrent");
        if (!altUIPath.exists()) {
            broadcastLog("WARN", "VueTorrent 目录不存在，跳过配置");
            return;
        }
        int port = readPort();
        try {
            URL url = new URL("http://127.0.0.1:" + port + "/api/v2/app/setPreferences");
            HttpURLConnection conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("POST");
            conn.setDoOutput(true);
            conn.setConnectTimeout(3000);
            conn.setReadTimeout(3000);
            conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded");
            String json = "{\"alternative_webui_enabled\":true,\"alternative_webui_path\":\"" +
                    altUIPath.getAbsolutePath().replace("\\", "\\\\") + "\"}";
            String params = "json=" + URLEncoder.encode(json, "UTF-8");
            try (OutputStream os = conn.getOutputStream()) {
                os.write(params.getBytes("UTF-8"));
            }
            int code = conn.getResponseCode();
            conn.disconnect();
            if (code == 200) {
                broadcastLog("INFO", "已配置 VueTorrent 为默认 WebUI");
            } else {
                broadcastLog("WARN", "配置 VueTorrent 失败，HTTP " + code);
            }
        } catch (Exception e) {
            broadcastLog("WARN", "配置 VueTorrent 失败: " + e.getMessage());
        }
    }

    private String readWebUIPref() {
        try {
            File prefFile = new File(getFilesDir(), "webui_pref.txt");
            if (prefFile.exists()) {
                byte[] data = new byte[(int) prefFile.length()];
                try (FileInputStream fis = new FileInputStream(prefFile)) {
                    fis.read(data);
                }
                return new String(data, "UTF-8").trim();
            }
        } catch (IOException ignored) {}
        return "vuetorrent";
    }

    private int readPort() {
        try {
            File portFile = new File(getFilesDir(), "webui_port.txt");
            if (portFile.exists()) {
                byte[] data = new byte[(int) portFile.length()];
                try (FileInputStream fis = new FileInputStream(portFile)) {
                    fis.read(data);
                }
                return Integer.parseInt(new String(data, "UTF-8").trim());
            }
        } catch (Exception ignored) {}
        return 8080;
    }

    private String readDownloadPath() {
        try {
            File pathFile = new File(getFilesDir(), "download_path.txt");
            if (pathFile.exists()) {
                byte[] data = new byte[(int) pathFile.length()];
                try (FileInputStream fis = new FileInputStream(pathFile)) {
                    fis.read(data);
                }
                String path = new String(data, "UTF-8").trim();
                if (!path.isEmpty()) return path;
            }
        } catch (Exception ignored) {}
        return Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).getAbsolutePath();
    }

    /** WebUI 就绪后，首次启动时通过 API 设置密码并显示在日志中 */
    private void setInitialPassword(File profileDir) {
        File cfgFile = new File(profileDir, "qBittorrent/config/qBittorrent.conf");
        String content = readFile(cfgFile);
        if (content.contains("Password_PBKDF2")) {
            // 密码已设置，不重复显示
            broadcastLog("INFO", "WebUI 已有密码配置，跳过默认密码设置");
            return;
        }
        // 首次启动：通过 API 设置默认密码
        try {
            URL url = new URL("http://127.0.0.1:" + readPort() + "/api/v2/app/setPreferences");
            HttpURLConnection conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("POST");
            conn.setDoOutput(true);
            conn.setConnectTimeout(3000);
            conn.setReadTimeout(3000);
            conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded");
            String json = "{\"web_ui_password\":\"adminadmin\"}";
            String params = "json=" + URLEncoder.encode(json, "UTF-8");
            try (OutputStream os = conn.getOutputStream()) {
                os.write(params.getBytes("UTF-8"));
            }
            int code = conn.getResponseCode();
            conn.disconnect();
            if (code == 200) {
                broadcastLog("INFO", "========================================");
                broadcastLog("INFO", "WebUI 默认密码已设置");
                broadcastLog("INFO", "  用户名: admin");
                broadcastLog("INFO", "  密码: adminadmin");
                broadcastLog("INFO", "  (仅首次显示，后续启动不再提示)");
                broadcastLog("INFO", "========================================");
            } else {
                broadcastLog("WARN", "设置密码失败，HTTP " + code);
            }
        } catch (Exception e) {
            broadcastLog("WARN", "设置密码失败: " + e.getMessage());
        }
    }

    private void startQBittorrent() {
        try {
            String nativeLibDir = getNativeLibDir();
            broadcastLog("INFO", "nativeLibDir: " + nativeLibDir);

            // 列出 nativeLibDir 中的所有文件
            File libDirFile = new File(nativeLibDir);
            String[] files = libDirFile.list();
            if (files != null) {
                for (String f : files) {
                    File ff = new File(libDirFile, f);
                    broadcastLog("INFO", "  " + f + " (" + (ff.length() / 1024) + " KB)");
                }
            }

            broadcastLog("INFO", "正在启动 qBittorrent (JNI in-process)...");

            File configDir = new File(getFilesDir(), "config");
            File downloadsDir = new File(Environment.getExternalStoragePublicDirectory(
                    Environment.DIRECTORY_DOWNLOADS), "qBittorrent");
            configDir.mkdirs();
            downloadsDir.mkdirs();

            // 复制 qb-web 到数据目录
            copyQbWeb(configDir);

            // 首次启动写入默认配置（含中文语言）
            boolean firstRun = writeDefaultConfig(configDir);
            if (firstRun) {
                broadcastLog("INFO", "首次启动，已写入默认配置（中文界面）");
            }

            // 每次启动更新 config（端口/路径/AlternativeUI）
            updateConfig(configDir);

            // 复制系统 CA 证书到 app 目录（OpenSSL 需要）
            copyCACerts(configDir);

            broadcastLog("INFO", "配置目录: " + configDir.getAbsolutePath());
            broadcastLog("INFO", "下载目录: " + downloadsDir.getAbsolutePath());

            // Set environment variables for Qt5
            System.setProperty("HOME", configDir.getAbsolutePath());
            System.setProperty("TMPDIR", getCacheDir().getAbsolutePath());

            // Load Qt5 libraries first (triggers their JNI_OnLoad → sets JavaVM)
            broadcastLog("INFO", "Loading Qt5 libraries via System.loadLibrary...");
            System.loadLibrary("Qt5Core_arm64-v8a");
            broadcastLog("INFO", "  Qt5Core loaded");
            System.loadLibrary("Qt5Network_arm64-v8a");
            broadcastLog("INFO", "  Qt5Network loaded");
            System.loadLibrary("Qt5Xml_arm64-v8a");
            broadcastLog("INFO", "  Qt5Xml loaded");
            System.loadLibrary("Qt5Sql_arm64-v8a");
            broadcastLog("INFO", "  Qt5Sql loaded");

            // Load libtorrent
            System.loadLibrary("torrent-rasterbar");
            broadcastLog("INFO", "  libtorrent loaded");

            // Load qBittorrent (this has the JNI nativeMain function)
            System.loadLibrary("qbt");
            broadcastLog("INFO", "  libqbt loaded, calling nativeMain...");

            nativeMainRunning = true;
            broadcastLog("INFO", "进程已启动");

            // Build arguments
            final int webuiPort = readPort();
            String[] args = {
                    "qbittorrent-nox",
                    "--profile=" + configDir.getAbsolutePath(),
                    "--webui-port=" + webuiPort
            };
            broadcastLog("INFO", "启动命令: " + String.join(" ", args));

            // Run in a separate thread to avoid blocking the service
            new Thread(() -> {
                try {
                    int exitCode = nativeMain(args);
                    nativeMainRunning = false;
                    broadcastLog("WARN", "qBittorrent exited, exitCode=" + exitCode);
                } catch (UnsatisfiedLinkError e) {
                    nativeMainRunning = false;
                    broadcastLog("ERROR", "JNI error: " + e.getMessage());
                    Log.e(TAG, "JNI error", e);
                } catch (Exception e) {
                    nativeMainRunning = false;
                    broadcastLog("ERROR", "启动失败: " + e.getMessage());
                    Log.e(TAG, "Failed to start qBittorrent", e);
                }
            }).start();

            // Wait for WebUI port to be ready, then set password on first run
            final File profileDir = configDir;
            new Thread(() -> {
                for (int i = 0; i < 30; i++) {
                    try {
                        Thread.sleep(1000);
                        Socket s = new Socket("127.0.0.1", webuiPort);
                        s.close();
                        broadcastLog("INFO", "WebUI 就绪: http://localhost:" + webuiPort);
                        // 首次启动设置默认密码
                        try { Thread.sleep(500); } catch (InterruptedException ignored) {}
                        setInitialPassword(profileDir);
                        configureAlternativeUI(profileDir);
                        configureSavePath();
                        return;
                    } catch (Exception ignored) {}
                }
                broadcastLog("WARN", "WebUI 端口 " + webuiPort + " 未就绪（超时30秒）");
            }).start();

            broadcastLog("INFO", "qBittorrent 启动线程已创建");

        } catch (UnsatisfiedLinkError e) {
            broadcastLog("ERROR", "加载库失败: " + e.getMessage());
            Log.e(TAG, "Failed to load library", e);
        } catch (Exception e) {
            broadcastLog("ERROR", "启动失败: " + e.getMessage());
            Log.e(TAG, "Failed to start qBittorrent", e);
        }
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID,
                    "qBittorrent 下载服务",
                    NotificationManager.IMPORTANCE_LOW
            );
            channel.setDescription("保持 qBittorrent 后台运行");
            NotificationManager manager = getSystemService(NotificationManager.class);
            if (manager != null) {
                manager.createNotificationChannel(channel);
            }
        }
    }

    private Notification buildNotification() {
        Intent notificationIntent = new Intent(this, MainActivity.class);
        PendingIntent pendingIntent = PendingIntent.getActivity(this, 0,
                notificationIntent, PendingIntent.FLAG_IMMUTABLE);

        Notification.Builder builder;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder = new Notification.Builder(this, CHANNEL_ID);
        } else {
            builder = new Notification.Builder(this);
        }

        return builder
                .setContentTitle("qBittorrent")
                .setContentText("正在运行 - WebUI: http://localhost:" + readPort())
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentIntent(pendingIntent)
                .setOngoing(true)
                .build();
    }

    @Override
    public void onDestroy() {
        super.onDestroy();
        nativeMainRunning = false;
        broadcastLog("INFO", "服务已停止");
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
