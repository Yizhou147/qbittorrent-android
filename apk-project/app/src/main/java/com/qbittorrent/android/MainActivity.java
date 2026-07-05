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
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

public class MainActivity extends AppCompatActivity {

    private static final int REQUEST_PERMISSION = 100;
    private static final int REQUEST_MANAGE_STORAGE = 101;

    private WebView webView;
    private TextView tvLog;
    private TextView tvStatus;
    private ScrollView scrollView;
    private Button btnWebUI;
    private Button btnExportLog;
    private boolean serviceStarted = false;
    private boolean showingWebView = false;
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
        webView.setWebChromeClient(new WebChromeClient());
    }

    private void addMagnetLink(String magnetUri) {
        String encodedUri = Uri.encode(magnetUri);
        String url = "http://localhost:8080/api/v2/torrents/add?urls=" + encodedUri;
        webView.loadUrl("javascript:fetch('" + url + "', {method: 'POST', credentials: 'include'})");
        Toast.makeText(this, "已添加到下载队列", Toast.LENGTH_SHORT).show();
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
