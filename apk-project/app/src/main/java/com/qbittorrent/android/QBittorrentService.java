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
import java.net.Socket;

public class QBittorrentService extends Service {

    private static final String TAG = "QBittorrentService";
    public static final String ACTION_LOG = "com.qbittorrent.android.LOG";
    public static final String EXTRA_MESSAGE = "message";
    public static final String EXTRA_LEVEL = "level";
    private static final String CHANNEL_ID = "qbittorrent_service";
    private static final int NOTIFICATION_ID = 1;

    private static volatile boolean nativeMainRunning = false;
    private static final Object START_LOCK = new Object();

    @Override
    public void onCreate() {
        super.onCreate();
        createNotificationChannel();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        Notification notification = buildNotification();
        startForeground(NOTIFICATION_ID, notification);
        boolean shouldStart = false;
        synchronized (START_LOCK) {
            if (!nativeMainRunning) {
                nativeMainRunning = true;
                shouldStart = true;
            }
        }
        if (shouldStart) {
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

    private String getNativeLibDir() {
        // 标准 API: 系统解压原生库的位置，避免对 APK 路径结构的猜测
        return getApplicationInfo().nativeLibraryDir;
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

    /** 通过 API 配置下载路径（每次启动都执行） */
    private void configureSavePath() {
        String downloadPath = readDownloadPath();
        int port = readPort();
        String json = "{\"save_path\":\"" + downloadPath.replace("\\", "\\\\") + "\"}";
        int code = QbtApi.setPreferences(port, json);
        if (code == 200) {
            broadcastLog("INFO", "已设置下载路径: " + downloadPath);
        } else {
            broadcastLog("WARN", "设置下载路径失败，HTTP " + code);
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
        String json = "{\"alternative_webui_enabled\":true,\"alternative_webui_path\":\"" +
                altUIPath.getAbsolutePath().replace("\\", "\\\\") + "\"}";
        int code = QbtApi.setPreferences(readPort(), json);
        if (code == 200) {
            broadcastLog("INFO", "已配置 VueTorrent 为默认 WebUI");
        } else {
            broadcastLog("WARN", "配置 VueTorrent 失败，HTTP " + code);
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
        String content = QbtConfig.readFile(cfgFile);
        if (content.contains("Password_PBKDF2")) {
            // 密码已设置，不重复显示
            broadcastLog("INFO", "WebUI 已有密码配置，跳过默认密码设置");
            return;
        }
        // 首次启动：通过 API 设置默认密码
        int code = QbtApi.setPreferences(readPort(), "{\"web_ui_password\":\"adminadmin\"}");
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
            boolean firstRun = QbtConfig.writeDefaultConfig(configDir, readPort(), readDownloadPath());
            if (firstRun) {
                broadcastLog("INFO", "首次启动，已写入默认配置（中文界面）");
            }

            // 每次启动更新 config（端口/路径/AlternativeUI）
            String uiPref = readWebUIPref();
            boolean cfgOk = QbtConfig.updateConfig(configDir, readPort(), readDownloadPath(),
                    new File(configDir, "vuetorrent").getAbsolutePath(), "vuetorrent".equals(uiPref));
            if (cfgOk) {
                broadcastLog("INFO", "config 强制更新: port=" + readPort() + " path=" + readDownloadPath()
                        + " altUI=" + uiPref);
            } else {
                broadcastLog("WARN", "更新 config 失败");
            }

            // 复制系统 CA 证书到 app 目录（OpenSSL 需要）
            copyCACerts(configDir);

            broadcastLog("INFO", "配置目录: " + configDir.getAbsolutePath());
            broadcastLog("INFO", "下载目录: " + downloadsDir.getAbsolutePath());

            // Load Qt libraries first (their JNI_OnLoad sets the JavaVM pointer).
            // The library names differ between the Qt5 and Qt6 builds, so load
            // whatever libQt*_arm64-v8a.so files are present in the APK.
            broadcastLog("INFO", "Loading Qt libraries via System.loadLibrary...");
            String[] qtLibs = libDirFile.list((dir, name) ->
                    name.startsWith("libQt") && name.endsWith("_arm64-v8a.so"));
            if (qtLibs != null) {
                java.util.Arrays.sort(qtLibs);
                for (String f : qtLibs) {
                    System.loadLibrary(f.substring(3, f.length() - 3)); // strip "lib" / ".so"
                    broadcastLog("INFO", "  " + f + " loaded");
                }
            } else {
                throw new UnsatisfiedLinkError("No Qt libraries found in " + nativeLibDir);
            }

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
            nativeMainRunning = false;
            broadcastLog("ERROR", "加载库失败: " + e.getMessage());
            Log.e(TAG, "Failed to load library", e);
        } catch (Exception e) {
            nativeMainRunning = false;
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
        // 注意: native 层的 qBittorrent 线程无法在此安全终止, 进程内仍在运行,
        // 因此 nativeMainRunning 保持 true, 避免重启服务时产生第二个实例
        broadcastLog("INFO", "服务已停止 (qBittorrent 继续在进程内运行)");
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
