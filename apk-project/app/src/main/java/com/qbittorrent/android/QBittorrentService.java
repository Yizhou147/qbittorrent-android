package com.qbittorrent.android;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.os.Build;
import android.os.Environment;
import android.os.IBinder;
import android.util.Log;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;

public class QBittorrentService extends Service {

    private static final String TAG = "QBittorrentService";
    private static final String CHANNEL_ID = "qbittorrent_service";
    private static final int NOTIFICATION_ID = 1;

    private Process qbtProcess;
    private File binaryFile;
    private File configDir;
    private File downloadsDir;

    @Override
    public void onCreate() {
        super.onCreate();
        createNotificationChannel();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // 前台服务通知
        Notification notification = buildNotification();
        startForeground(NOTIFICATION_ID, notification);

        // 在后台线程启动 qBittorrent
        new Thread(this::startQBittorrent).start();

        return START_STICKY;
    }

    private void startQBittorrent() {
        try {
            // 准备目录
            File dataDir = getFilesDir();
            configDir = new File(dataDir, "config");
            downloadsDir = new File(Environment.getExternalStoragePublicDirectory(
                    Environment.DIRECTORY_DOWNLOADS), "qBittorrent");

            configDir.mkdirs();
            downloadsDir.mkdirs();

            // 释放 native binary
            binaryFile = new File(dataDir, "qbittorrent-nox");
            if (!binaryFile.exists()) {
                extractBinary();
            }
            binaryFile.setExecutable(true);

            // 构建启动命令
            String[] cmd = {
                    binaryFile.getAbsolutePath(),
                    "--profile=" + configDir.getAbsolutePath(),
                    "--save-path=" + downloadsDir.getAbsolutePath(),
                    "--webui-port=8080",
                    "--daemon"
            };

            Log.i(TAG, "Starting qBittorrent: " + String.join(" ", cmd));

            // 启动进程
            ProcessBuilder pb = new ProcessBuilder(cmd);
            pb.environment().put("HOME", configDir.getAbsolutePath());
            pb.environment().put("TMPDIR", getCacheDir().getAbsolutePath());
            pb.redirectErrorStream(true);
            qbtProcess = pb.start();

            // 读取输出 (后台)
            new Thread(() -> {
                try (BufferedReader reader = new BufferedReader(
                        new InputStreamReader(qbtProcess.getInputStream()))) {
                    String line;
                    while ((line = reader.readLine()) != null) {
                        Log.d(TAG, "qBittorrent: " + line);
                    }
                } catch (IOException e) {
                    Log.e(TAG, "Error reading output", e);
                }
            }).start();

            // 等待进程退出
            int exitCode = qbtProcess.waitFor();
            Log.w(TAG, "qBittorrent exited with code: " + exitCode);

            // 如果异常退出，尝试重启
            if (exitCode != 0) {
                Log.i(TAG, "Restarting in 5 seconds...");
                Thread.sleep(5000);
                startQBittorrent();
            }

        } catch (Exception e) {
            Log.e(TAG, "Failed to start qBittorrent", e);
        }
    }

    private void extractBinary() throws IOException {
        Log.i(TAG, "Extracting qBittorrent binary...");

        // 从 assets 复制
        InputStream is = getAssets().open("qbittorrent-nox");
        OutputStream os = new FileOutputStream(binaryFile);
        byte[] buffer = new byte[8192];
        int read;
        while ((read = is.read(buffer)) != -1) {
            os.write(buffer, 0, read);
        }
        os.close();
        is.close();

        Log.i(TAG, "Binary extracted to: " + binaryFile.getAbsolutePath());
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
                .setContentText("正在运行 - WebUI: http://localhost:8080")
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentIntent(pendingIntent)
                .setOngoing(true)
                .build();
    }

    @Override
    public void onDestroy() {
        super.onDestroy();
        if (qbtProcess != null) {
            qbtProcess.destroy();
        }
        Log.i(TAG, "Service destroyed");
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
