package com.qbittorrent.android;

import android.Manifest;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.provider.Settings;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import androidx.appcompat.app.AppCompatActivity;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;
import androidx.localbroadcastmanager.content.LocalBroadcastManager;

import java.io.File;
import java.io.FileWriter;
import java.io.IOException;
import java.io.InputStream;
import java.io.FileOutputStream;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

public class MainActivity extends AppCompatActivity {

    private static final int REQUEST_PERMISSION = 100;
    private static final int REQUEST_MANAGE_STORAGE = 101;
    private static final int REQUEST_FILE_CHOOSER = 102;

    private WebView webView;
    private TextView tvLog;
    private TextView tvStatus;
    private ScrollView scrollView;
    private Button btnWebUI;
    private Button btnExportLog;
    private boolean serviceStarted = false;
    private boolean showingWebView = false;
    private ValueCallback<Uri[]> fileUploadCallback;
    private final StringBuilder logBuffer = new StringBuilder();

    private final BroadcastReceiver logReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            String message = intent.getStringExtra(QBittorrentService.EXTRA_MESSAGE);
            String level = intent.getStringExtra(QBittorrentService.EXTRA_LEVEL);
            if (message != null && level != null) {
                appendLog(level, message);
            }
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        tvStatus = findViewById(R.id.tvStatus);
        tvLog = findViewById(R.id.tvLog);
        scrollView = findViewById(R.id.scrollView);
        btnWebUI = findViewById(R.id.btnWebUI);
        btnExportLog = findViewById(R.id.btnExportLog);
        webView = findViewById(R.id.webView);

        btnWebUI.setOnClickListener(v -> toggleWebView());
        btnExportLog.setOnClickListener(v -> exportLog());

        // 注册日志接收器
        LocalBroadcastManager.getInstance(this).registerReceiver(
                logReceiver, new IntentFilter(QBittorrentService.ACTION_LOG));

        // 检查权限并启动
        if (checkPermissions()) {
            startQBittorrent();
        } else {
            requestPermissions();
        }

        // 处理外部传入的 intent（.torrent 文件或 magnet 链接）
        handleIncomingIntent(getIntent());
    }

    private void appendLog(String level, String message) {
        String timestamp = new SimpleDateFormat("HH:mm:ss", Locale.US).format(new Date());
        String line = timestamp + " [" + level + "] " + message + "\n";
        logBuffer.append(line);
        runOnUiThread(() -> {
            tvLog.append(line);
            // 自动滚动到底部
            scrollView.post(() -> scrollView.fullScroll(ScrollView.FOCUS_DOWN));
            // 如果进程启动成功，启用 WebUI 按钮
            if (message.contains("进程已启动") || message.contains("WebUI 就绪")) {
                tvStatus.setText("qBittorrent 已启动");
                tvStatus.setTextColor(Color.parseColor("#4CAF50"));
                btnWebUI.setEnabled(true);
            } else if (message.contains("已在运行")) {
                tvStatus.setText("qBittorrent 已在运行");
                tvStatus.setTextColor(Color.parseColor("#4CAF50"));
                btnWebUI.setEnabled(true);
            } else if (level.equals("ERROR")) {
                tvStatus.setText("启动出错，请查看日志");
                tvStatus.setTextColor(Color.parseColor("#F44336"));
            }
        });
    }

    private void toggleWebView() {
        if (showingWebView) {
            // 切回日志视图
            webView.setVisibility(android.view.View.GONE);
            scrollView.setVisibility(android.view.View.VISIBLE);
            btnWebUI.setText("打开 WebUI");
            showingWebView = false;
        } else {
            // 切换到 WebView
            setupWebView();
            webView.loadUrl("http://localhost:8080");
            webView.setVisibility(android.view.View.VISIBLE);
            scrollView.setVisibility(android.view.View.GONE);
            btnWebUI.setText("查看日志");
            showingWebView = true;
        }
    }

    private void exportLog() {
        try {
            File exportDir = Environment.getExternalStoragePublicDirectory(
                    Environment.DIRECTORY_DOWNLOADS);
            String timestamp = new SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(new Date());
            File logFile = new File(exportDir, "qbittorrent_log_" + timestamp + ".txt");

            FileWriter writer = new FileWriter(logFile);
            writer.write(logBuffer.toString());
            writer.close();

            Toast.makeText(this, "日志已导出: " + logFile.getAbsolutePath(), Toast.LENGTH_LONG).show();
        } catch (IOException e) {
            Toast.makeText(this, "导出失败: " + e.getMessage(), Toast.LENGTH_LONG).show();
        }
    }

    private void setupWebView() {
        if (webView == null) return;
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(true);
        settings.setAllowContentAccess(true);
        settings.setCacheMode(WebSettings.LOAD_DEFAULT);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_ALWAYS_ALLOW);
        settings.setSupportZoom(true);
        settings.setBuiltInZoomControls(true);
        settings.setDisplayZoomControls(false);
        settings.setUseWideViewPort(true);
        settings.setLoadWithOverviewMode(true);

        webView.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri uri = request.getUrl();
                if ("magnet".equals(uri.getScheme())) {
                    addMagnetLink(uri.toString());
                    return true;
                }
                return false;
            }
        });
        webView.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onShowFileChooser(WebView webView,
                    ValueCallback<Uri[]> filePathCallback,
                    FileChooserParams fileChooserParams) {
                if (fileUploadCallback != null) {
                    fileUploadCallback.onReceiveValue(null);
                }
                fileUploadCallback = filePathCallback;
                Intent intent = new Intent(Intent.ACTION_GET_CONTENT);
                intent.addCategory(Intent.CATEGORY_OPENABLE);
                intent.setType("*/*");
                startActivityForResult(Intent.createChooser(intent, "选择文件"), REQUEST_FILE_CHOOSER);
                return true;
            }
        });
    }

    private void addMagnetLink(String magnetUri) {
        String encodedUri = Uri.encode(magnetUri);
        String url = "http://localhost:8080/api/v2/torrents/add?urls=" + encodedUri;
        webView.loadUrl("javascript:fetch('" + url + "', {method: 'POST', credentials: 'include'})");
        Toast.makeText(this, "已添加到下载队列", Toast.LENGTH_SHORT).show();
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        handleIncomingIntent(intent);
    }

    private void handleIncomingIntent(Intent intent) {
        if (intent == null) return;
        String action = intent.getAction();
        Uri data = intent.getData();

        if (Intent.ACTION_VIEW.equals(action) && data != null) {
            String scheme = data.getScheme();
            if ("magnet".equals(scheme)) {
                addMagnetLinkDelayed(data.toString());
            } else if ("content".equals(scheme) || "file".equals(scheme)) {
                importTorrentFile(data);
            }
        }
    }

    private void addMagnetLinkDelayed(String magnetUri) {
        new Thread(() -> {
            for (int i = 0; i < 60; i++) {
                try {
                    Thread.sleep(1000);
                    java.net.Socket s = new java.net.Socket();
                    s.connect(new java.net.InetSocketAddress("127.0.0.1", 8080), 1000);
                    s.close();
                    break;
                } catch (Exception ignored) {}
            }
            runOnUiThread(() -> {
                if (showingWebView) {
                    addMagnetLink(magnetUri);
                } else {
                    toggleWebView();
                    webView.postDelayed(() -> addMagnetLink(magnetUri), 2000);
                }
            });
        }).start();
    }

    private void importTorrentFile(Uri torrentUri) {
        new Thread(() -> {
            try {
                InputStream is = getContentResolver().openInputStream(torrentUri);
                if (is == null) return;
                File tmpFile = new File(getCacheDir(), "import_" + System.currentTimeMillis() + ".torrent");
                FileOutputStream fos = new FileOutputStream(tmpFile);
                byte[] buf = new byte[8192];
                int len;
                while ((len = is.read(buf)) > 0) {
                    fos.write(buf, 0, len);
                }
                fos.close();
                is.close();

                for (int i = 0; i < 60; i++) {
                    try {
                        Thread.sleep(1000);
                        java.net.Socket s = new java.net.Socket();
                        s.connect(new java.net.InetSocketAddress("127.0.0.1", 8080), 1000);
                        s.close();
                        break;
                    } catch (Exception ignored) {}
                }

                java.net.HttpURLConnection conn = (java.net.HttpURLConnection) new java.net.URL("http://127.0.0.1:8080/api/v2/torrents/add").openConnection();
                conn.setRequestMethod("POST");
                conn.setDoOutput(true);
                String boundary = "----FormBoundary" + System.currentTimeMillis();
                conn.setRequestProperty("Content-Type", "multipart/form-data; boundary=" + boundary);

                java.io.OutputStream os = conn.getOutputStream();
                String header = "--" + boundary + "\r\n" +
                        "Content-Disposition: form-data; name=\"torrents\"; filename=\"" + tmpFile.getName() + "\"\r\n" +
                        "Content-Type: application/x-bittorrent\r\n\r\n";
                os.write(header.getBytes("UTF-8"));
                java.io.FileInputStream fis = new java.io.FileInputStream(tmpFile);
                byte[] buf2 = new byte[8192];
                int len2;
                while ((len2 = fis.read(buf2)) > 0) {
                    os.write(buf2, 0, len2);
                }
                fis.close();
                os.write(("\r\n--" + boundary + "--\r\n").getBytes("UTF-8"));
                os.flush();
                os.close();

                int code = conn.getResponseCode();
                conn.disconnect();
                tmpFile.delete();

                String msg = (code == 200) ? "种子文件已导入" : "导入失败，HTTP " + code;
                runOnUiThread(() -> Toast.makeText(this, msg, Toast.LENGTH_SHORT).show());

                if (showingWebView) {
                    runOnUiThread(() -> webView.loadUrl("javascript:location.reload()"));
                }
            } catch (Exception e) {
                runOnUiThread(() -> Toast.makeText(this, "导入失败: " + e.getMessage(), Toast.LENGTH_SHORT).show());
            }
        }).start();
    }

    private boolean checkPermissions() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return Environment.isExternalStorageManager();
        }
        return ContextCompat.checkSelfPermission(this,
                Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED;
    }

    private void requestPermissions() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                Intent intent = new Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION);
                intent.setData(Uri.parse("package:" + getPackageName()));
                startActivityForResult(intent, REQUEST_MANAGE_STORAGE);
            } catch (Exception e) {
                Intent intent = new Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION);
                startActivityForResult(intent, REQUEST_MANAGE_STORAGE);
            }
        } else {
            ActivityCompat.requestPermissions(this,
                    new String[]{
                            Manifest.permission.WRITE_EXTERNAL_STORAGE,
                            Manifest.permission.READ_EXTERNAL_STORAGE
                    },
                    REQUEST_PERMISSION);
        }
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQUEST_PERMISSION) {
            if (grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                startQBittorrent();
            } else {
                Toast.makeText(this, "需要存储权限才能下载文件", Toast.LENGTH_LONG).show();
                finish();
            }
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQUEST_MANAGE_STORAGE) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && Environment.isExternalStorageManager()) {
                startQBittorrent();
            } else {
                Toast.makeText(this, "需要存储权限才能下载文件", Toast.LENGTH_LONG).show();
                finish();
            }
        } else if (requestCode == REQUEST_FILE_CHOOSER) {
            if (fileUploadCallback != null) {
                Uri[] result = null;
                if (resultCode == RESULT_OK && data != null) {
                    String dataString = data.getDataString();
                    if (dataString != null) {
                        result = new Uri[]{Uri.parse(dataString)};
                    }
                }
                fileUploadCallback.onReceiveValue(result);
                fileUploadCallback = null;
            }
        }
    }

    private void startQBittorrent() {
        appendLog("INFO", "正在启动 qBittorrent 服务...");
        tvStatus.setText("正在启动...");

        if (!serviceStarted) {
            serviceStarted = true;
            Intent serviceIntent = new Intent(this, QBittorrentService.class);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(serviceIntent);
            } else {
                startService(serviceIntent);
            }
        }
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        LocalBroadcastManager.getInstance(this).unregisterReceiver(logReceiver);
        if (webView != null) {
            webView.destroy();
        }
    }

    @Override
    public void onBackPressed() {
        if (showingWebView) {
            if (webView.canGoBack()) {
                webView.goBack();
            } else {
                toggleWebView();
            }
        } else {
            super.onBackPressed();
        }
    }
}
