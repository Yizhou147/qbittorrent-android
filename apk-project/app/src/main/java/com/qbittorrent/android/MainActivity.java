package com.qbittorrent.android;

import android.Manifest;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.net.http.SslError;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.webkit.SslErrorHandler;
import androidx.activity.OnBackPressedCallback;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.LinearLayout;
import android.widget.TextView;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;
import androidx.localbroadcastmanager.content.LocalBroadcastManager;
import android.content.pm.ShortcutInfo;
import android.content.pm.ShortcutManager;
import android.graphics.drawable.Icon;
import com.google.android.material.floatingactionbutton.FloatingActionButton;
import java.util.Arrays;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.net.Socket;

public class MainActivity extends AppCompatActivity {

    private static final int REQUEST_PERMISSION = 1001;
    private static final int REQUEST_FILE_CHOOSER = 1002;
    // 与服务端 QBittorrentService 的 240 秒就绪窗口保持一致
    private static final int POLL_INTERVAL_MS = 2000;
    private static final int POLL_MAX_RETRIES = 120;
    private static final int LOG_TAIL_LINES = 8;

    private WebView webView;
    private TextView tvStatus;
    private TextView tvDetail;
    private LinearLayout loadingLayout;
    private FloatingActionButton fabRefresh;
    private boolean serviceStarted = false;
    private BroadcastReceiver logReceiver;
    private ValueCallback<Uri[]> fileUploadCallback;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private boolean webUILoaded = false;
    private boolean polling = false;
    private volatile boolean startupFailed = false;
    private final java.util.ArrayDeque<String> logTail = new java.util.ArrayDeque<>();

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        webView = findViewById(R.id.webView);
        tvStatus = findViewById(R.id.tvStatus);
        tvDetail = findViewById(R.id.tvDetail);
        loadingLayout = findViewById(R.id.loadingLayout);
        fabRefresh = findViewById(R.id.fabRefresh);

        // 刷新按钮点击事件
        fabRefresh.setOnClickListener(v -> reloadWebUI());

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, "android.permission.POST_NOTIFICATIONS") != PackageManager.PERMISSION_GRANTED) {
                ActivityCompat.requestPermissions(this, new String[]{"android.permission.POST_NOTIFICATIONS"}, REQUEST_PERMISSION);
            }
        }

        requestStoragePermission();
        setupLogReceiver();
        startQbittorrentService();
        setupWebView();
        setupLongPressShortcut();
    }

    private void setupLongPressShortcut() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N_MR1) {
            ShortcutManager shortcutManager = getSystemService(ShortcutManager.class);
            if (shortcutManager != null) {
                ShortcutInfo shortcut = new ShortcutInfo.Builder(this, "settings")
                        .setShortLabel("设置")
                        .setLongLabel("打开 qBittorrent 设置")
                        .setIcon(Icon.createWithResource(this, android.R.drawable.ic_menu_preferences))
                        .setIntent(new Intent(this, SettingsActivity.class).setAction(Intent.ACTION_VIEW))
                        .build();
                shortcutManager.setDynamicShortcuts(Arrays.asList(shortcut));
            }
        }
    }

    private void startQbittorrentService() {
        if (serviceStarted) return;
        serviceStarted = true;

        SharedPreferences prefs = getSharedPreferences("qbt_prefs", MODE_PRIVATE);
        String uiType = prefs.getString("webui_type", "vuetorrent");
        int port = prefs.getInt("webui_port", 8080);
        String downloadPath = prefs.getString("download_path", "");
        writeWebUIPref(uiType);
        writePortPref(port);
        writeDownloadPathPref(downloadPath);

        Intent intent = new Intent(this, QBittorrentService.class);
        ContextCompat.startForegroundService(this, intent);
    }

    private void writeWebUIPref(String uiType) {
        File prefFile = new File(getFilesDir(), "webui_pref.txt");
        try (FileOutputStream fos = new FileOutputStream(prefFile)) {
            fos.write(uiType.getBytes("UTF-8"));
        } catch (IOException e) { }
    }

    private void writePortPref(int port) {
        File portFile = new File(getFilesDir(), "webui_port.txt");
        try (FileOutputStream fos = new FileOutputStream(portFile)) {
            fos.write(String.valueOf(port).getBytes("UTF-8"));
        } catch (IOException e) { }
    }

    private void writeDownloadPathPref(String path) {
        if (path == null || path.isEmpty()) return;
        File pathFile = new File(getFilesDir(), "download_path.txt");
        try (FileOutputStream fos = new FileOutputStream(pathFile)) {
            fos.write(path.getBytes("UTF-8"));
        } catch (IOException e) { }
    }

    private String getWebUIUrl() {
        SharedPreferences prefs = getSharedPreferences("qbt_prefs", MODE_PRIVATE);
        int port = prefs.getInt("webui_port", 8080);
        return "http://localhost:" + port;
    }

    private void setupWebView() {
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(true);
        settings.setUseWideViewPort(true);
        settings.setLoadWithOverviewMode(true);
        settings.setSupportZoom(true);
        settings.setBuiltInZoomControls(true);
        settings.setDisplayZoomControls(false);
        settings.setCacheMode(WebSettings.LOAD_DEFAULT);

        webView.setWebViewClient(new WebViewClient() {
            @Override
            public void onReceivedSslError(WebView view, SslErrorHandler handler, SslError error) {
                handler.proceed();
            }

            @Override
            public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                super.onReceivedError(view, request, error);
                // 主页面加载失败时显示刷新按钮
                if (request.isForMainFrame()) {
                    handler.post(() -> {
                        fabRefresh.setVisibility(android.view.View.VISIBLE);
                        tvStatus.setText("WebUI 加载失败，点击右下角按钮重试");
                        loadingLayout.setVisibility(android.view.View.VISIBLE);
                    });
                }
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                webUILoaded = true;
                loadingLayout.setVisibility(android.view.View.GONE);
                webView.setVisibility(android.view.View.VISIBLE);
                fabRefresh.setVisibility(android.view.View.VISIBLE);
            }
        });

        webView.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onShowFileChooser(WebView webView, ValueCallback<Uri[]> filePathCallback,
                                            FileChooserParams fileChooserParams) {
                fileUploadCallback = filePathCallback;
                Intent intent = fileChooserParams.createIntent();
                startActivityForResult(intent, REQUEST_FILE_CHOOSER);
                return true;
            }
        });

        // WebView 可后退时优先后退，否则退出 Activity
        getOnBackPressedDispatcher().addCallback(this, new OnBackPressedCallback(true) {
            @Override
            public void handleOnBackPressed() {
                if (webView != null && webView.canGoBack()) {
                    webView.goBack();
                } else {
                    finish();
                }
            }
        });

        // 不立即加载，等端口就绪后再加载
        startPortPolling();
    }

    private void startPortPolling() {
        if (polling) return;
        polling = true;
        startupFailed = false;
        synchronized (logTail) {
            logTail.clear();
        }
        showLoading("正在启动 qBittorrent...");
        tvDetail.setText("");
        tvDetail.setVisibility(android.view.View.GONE);

        new Thread(() -> {
            SharedPreferences prefs = getSharedPreferences("qbt_prefs", MODE_PRIVATE);
            int port = prefs.getInt("webui_port", 8080);
            boolean ready = false;

            for (int i = 0; i < POLL_MAX_RETRIES && !startupFailed; i++) {
                try {
                    Socket s = new Socket("127.0.0.1", port);
                    s.close();
                    ready = true;
                    break;
                } catch (Exception e) {
                    // 端口还没就绪，等待后重试
                    try {
                        Thread.sleep(POLL_INTERVAL_MS);
                        final int attempt = i + 1;
                        handler.post(() -> tvStatus.setText("正在启动 qBittorrent... (" + attempt + ")"));
                    } catch (InterruptedException ignored) {
                        break;
                    }
                }
            }

            final boolean isReady = ready;
            if (isReady) {
                // 端口就绪后，先配置 WebUI 类型，再加载页面
                handler.post(() -> tvStatus.setText("正在配置 WebUI..."));
                configureWebUI(port);
            }

            handler.post(() -> {
                polling = false;
                if (isReady) {
                    showLoading("正在加载 WebUI...");
                    webView.clearCache(true);
                    webView.loadUrl(getWebUIUrl());
                } else if (startupFailed) {
                    // 具体错误已由服务端日志广播显示，这里只保证重试入口可见
                    loadingLayout.setVisibility(android.view.View.VISIBLE);
                    webView.setVisibility(android.view.View.GONE);
                    fabRefresh.setVisibility(android.view.View.VISIBLE);
                } else {
                    int seconds = POLL_MAX_RETRIES * POLL_INTERVAL_MS / 1000;
                    tvStatus.setText("qBittorrent 启动超时（已等待 " + seconds + " 秒），点击右下角按钮重试");
                    showLogTail();
                    fabRefresh.setVisibility(android.view.View.VISIBLE);
                }
            });
        }).start();
    }

    /** 记录服务端最近的广播，启动失败/超时时展示给用户 */
    private void rememberLog(String level, String message) {
        String line = (level == null ? "INFO" : level) + " " + message;
        synchronized (logTail) {
            logTail.addLast(line);
            while (logTail.size() > LOG_TAIL_LINES) logTail.removeFirst();
        }
    }

    private String recentLog() {
        StringBuilder sb = new StringBuilder();
        synchronized (logTail) {
            for (String line : logTail) {
                if (sb.length() > 0) sb.append('\n');
                sb.append(line);
            }
        }
        return sb.toString();
    }

    private void showLogTail() {
        String detail = recentLog();
        if (detail.isEmpty()) return;
        tvDetail.setText(detail);
        tvDetail.setVisibility(android.view.View.VISIBLE);
    }

    /** 服务端已无法启动（native 加载失败 / qb 退出 / 端口等待超时） */
    private boolean isFatalStartupMessage(String level, String message) {
        if ("ERROR".equals(level)) return true;
        return message.contains("加载库失败")
                || message.contains("启动失败")
                || message.contains("JNI error")
                || message.contains("qBittorrent exited")
                || (message.contains("WebUI 端口") && message.contains("未就绪"));
    }

    private void showStartupFailure(String message) {
        // WebUI 已经打开后才出问题，不要覆盖用户正在用的界面
        if (webUILoaded) return;
        loadingLayout.setVisibility(android.view.View.VISIBLE);
        webView.setVisibility(android.view.View.GONE);
        fabRefresh.setVisibility(android.view.View.VISIBLE);
        tvStatus.setText("启动失败：" + message);
        showLogTail();
    }

    /** 端口就绪后，通过 API 配置 WebUI 类型 */
    private void configureWebUI(int port) {
        SharedPreferences prefs = getSharedPreferences("qbt_prefs", MODE_PRIVATE);
        String uiType = prefs.getString("webui_type", "vuetorrent");
        boolean useAlt = "vuetorrent".equals(uiType);

        String altPath = new File(getFilesDir(), "config/vuetorrent").getAbsolutePath();
        String json;
        if (useAlt) {
            json = "{\"alternative_webui_enabled\":true,\"alternative_webui_path\":\"" +
                    altPath.replace("\\", "\\\\") + "\"}";
        } else {
            json = "{\"alternative_webui_enabled\":false}";
        }
        QbtApi.setPreferences(port, json);
    }

    private void reloadWebUI() {
        webUILoaded = false;
        webView.setVisibility(android.view.View.GONE);
        fabRefresh.setVisibility(android.view.View.GONE);
        webView.stopLoading();
        webView.clearCache(true);
        // 上一次可能是 native 加载失败 (nativeMainRunning 已复位)，重试时一并重新拉起服务；
        // 若 qb 仍在运行，Service 会直接忽略，不会产生第二个实例。
        serviceStarted = false;
        startQbittorrentService();
        startPortPolling();
    }

    private void showLoading(String message) {
        loadingLayout.setVisibility(android.view.View.VISIBLE);
        webView.setVisibility(android.view.View.GONE);
        tvStatus.setText(message);
    }

    private void setupLogReceiver() {
        logReceiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                String message = intent.getStringExtra(QBittorrentService.EXTRA_MESSAGE);
                if (message == null) return;
                String level = intent.getStringExtra(QBittorrentService.EXTRA_LEVEL);
                rememberLog(level, message);

                if (isFatalStartupMessage(level, message)) {
                    startupFailed = true;
                    handler.post(() -> showStartupFailure(message));
                    return;
                }
                if (message.contains("WebUI") && message.contains("就绪")) {
                    if (!webUILoaded && !polling && !startupFailed) {
                        handler.post(() -> startPortPolling());
                    }
                }
            }
        };
        // 使用 LocalBroadcastManager 接收，与 Service 发送方式匹配
        LocalBroadcastManager.getInstance(this).registerReceiver(
                logReceiver, new IntentFilter(QBittorrentService.ACTION_LOG));
    }

    private void requestStoragePermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Android 11+: 需要 MANAGE_EXTERNAL_STORAGE
            if (!android.os.Environment.isExternalStorageManager()) {
                try {
                    Intent intent = new Intent(android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                            Uri.parse("package:" + getPackageName()));
                    startActivity(intent);
                } catch (Exception e) {
                    Intent intent = new Intent(android.provider.Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION);
                    startActivity(intent);
                }
            }
        } else {
            // Android 6-10: WRITE_EXTERNAL_STORAGE
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
                ActivityCompat.requestPermissions(this, new String[]{
                        Manifest.permission.WRITE_EXTERNAL_STORAGE,
                        Manifest.permission.READ_EXTERNAL_STORAGE
                }, REQUEST_PERMISSION);
            }
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQUEST_FILE_CHOOSER) {
            if (fileUploadCallback == null) return;
            Uri[] results = null;
            if (resultCode == RESULT_OK) {
                if (data != null) {
                    // 优先检查 ClipData（某些文件选择器返回多个文件）
                    if (data.getClipData() != null) {
                        int count = data.getClipData().getItemCount();
                        results = new Uri[count];
                        for (int i = 0; i < count; i++) {
                            results[i] = data.getClipData().getItemAt(i).getUri();
                        }
                    } else if (data.getData() != null) {
                        // 单文件选择
                        results = new Uri[]{data.getData()};
                    } else if (data.getDataString() != null) {
                        results = new Uri[]{Uri.parse(data.getDataString())};
                    }
                }
                // 如果 data 为 null 但 resultCode 为 OK，某些设备需要特殊处理
                // 此时 results 保持 null，WebView 会收到取消通知
            }
            fileUploadCallback.onReceiveValue(results);
            fileUploadCallback = null;
        }
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (logReceiver != null) LocalBroadcastManager.getInstance(this).unregisterReceiver(logReceiver);
        if (webView != null) webView.destroy();
    }
}
