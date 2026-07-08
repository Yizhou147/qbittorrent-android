package com.qbittorrent.android;

import android.app.AlertDialog;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.content.ContextCompat;
import java.io.*;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;

public class SettingsActivity extends AppCompatActivity {

    private TextView tvCurrentUI;
    private Button btnSwitchUI;
    private EditText etPort;
    private Button btnSavePort;
    private EditText etDownloadPath;
    private Button btnSavePath;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        // 浅色状态栏
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR);
            getWindow().setStatusBarColor(0xFFFAFAFA);
        }

        setContentView(R.layout.activity_settings);

        tvCurrentUI = findViewById(R.id.tvCurrentUI);
        btnSwitchUI = findViewById(R.id.btnSwitchUI);
        etPort = findViewById(R.id.etPort);
        btnSavePort = findViewById(R.id.btnSavePort);
        etDownloadPath = findViewById(R.id.etDownloadPath);
        btnSavePath = findViewById(R.id.btnSavePath);

        updateCurrentUI();
        loadPort();
        loadDownloadPath();

        btnSwitchUI.setOnClickListener(v -> switchUI());
        btnSavePort.setOnClickListener(v -> savePort());
        btnSavePath.setOnClickListener(v -> saveDownloadPath());
    }

    private void updateCurrentUI() {
        SharedPreferences prefs = getSharedPreferences("qbt_prefs", MODE_PRIVATE);
        String uiType = prefs.getString("webui_type", "vuetorrent");
        String label = "vuetorrent".equals(uiType) ? "VueTorrent" : "默认 WebUI";
        tvCurrentUI.setText(label);
    }

    private void loadPort() {
        SharedPreferences prefs = getSharedPreferences("qbt_prefs", MODE_PRIVATE);
        int port = prefs.getInt("webui_port", 8080);
        etPort.setText(String.valueOf(port));
    }

    private void loadDownloadPath() {
        SharedPreferences prefs = getSharedPreferences("qbt_prefs", MODE_PRIVATE);
        String path = prefs.getString("download_path", "");
        if (path.isEmpty()) {
            path = android.os.Environment.getExternalStoragePublicDirectory(
                    android.os.Environment.DIRECTORY_DOWNLOADS).getAbsolutePath();
        }
        etDownloadPath.setText(path);
    }

    private void switchUI() {
        SharedPreferences prefs = getSharedPreferences("qbt_prefs", MODE_PRIVATE);
        String current = prefs.getString("webui_type", "vuetorrent");
        String newUI = "vuetorrent".equals(current) ? "default" : "vuetorrent";
        String newName = "vuetorrent".equals(newUI) ? "VueTorrent" : "默认 WebUI";

        new AlertDialog.Builder(this)
                .setTitle("切换 WebUI")
                .setMessage("切换为 " + newName + "，应用将重启")
                .setPositiveButton("确认", (dialog, which) -> {
                    // 1. 同步写入 SharedPreferences
                    prefs.edit().putString("webui_type", newUI).commit();

                    // 2. 写入 webui_pref.txt 供 Service 读取
                    File prefFile = new File(getFilesDir(), "webui_pref.txt");
                    try (FileOutputStream fos = new FileOutputStream(prefFile)) {
                        fos.write(newUI.getBytes("UTF-8"));
                    } catch (IOException ignored) {}

                    // 3. 更新 config 文件
                    boolean useAlt = "vuetorrent".equals(newUI);
                    String altPath = new File(getFilesDir(), "config/vuetorrent").getAbsolutePath();
                    updateQbtConfig("WebUI\\AlternativeUIEnabled=", "WebUI\\AlternativeUIEnabled=" + (useAlt ? "true" : "false"));
                    updateQbtConfig("WebUI\\RootFolder=", "WebUI\\RootFolder=" + altPath);

                    // 4. 等 API 切换完成后再杀进程重启
                    int port = prefs.getInt("webui_port", 8080);
                    new Thread(() -> {
                        try {
                            String json = useAlt
                                    ? "{\"alternative_webui_enabled\":true,\"alternative_webui_path\":\"" + altPath.replace("\\", "\\\\") + "\"}"
                                    : "{\"alternative_webui_enabled\":false}";
                            URL url = new URL("http://127.0.0.1:" + port + "/api/v2/app/setPreferences");
                            HttpURLConnection conn = (HttpURLConnection) url.openConnection();
                            conn.setRequestMethod("POST");
                            conn.setDoOutput(true);
                            conn.setConnectTimeout(5000);
                            conn.setReadTimeout(5000);
                            conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded");
                            String params = "json=" + URLEncoder.encode(json, "UTF-8");
                            try (OutputStream os = conn.getOutputStream()) {
                                os.write(params.getBytes("UTF-8"));
                            }
                            int code = conn.getResponseCode();
                            conn.disconnect();
                            // 等待 qBittorrent 处理完配置变更
                            Thread.sleep(1000);
                        } catch (Exception ignored) {}

                        // 5. API 完成后，杀进程重启
                        runOnUiThread(() -> {
                            Intent intent = getPackageManager().getLaunchIntentForPackage(getPackageName());
                            if (intent != null) {
                                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);
                                startActivity(intent);
                            }
                            android.os.Process.killProcess(android.os.Process.myPid());
                        });
                    }).start();
                })
                .setNegativeButton("取消", null)
                .show();
    }

    private void savePort() {
        String portStr = etPort.getText().toString().trim();
        if (portStr.isEmpty()) {
            Toast.makeText(this, "请输入端口号", Toast.LENGTH_SHORT).show();
            return;
        }
        int port;
        try {
            port = Integer.parseInt(portStr);
            if (port < 1024 || port > 65535) {
                Toast.makeText(this, "端口范围: 1024-65535", Toast.LENGTH_SHORT).show();
                return;
            }
        } catch (NumberFormatException e) {
            Toast.makeText(this, "无效端口号", Toast.LENGTH_SHORT).show();
            return;
        }

        SharedPreferences prefs = getSharedPreferences("qbt_prefs", MODE_PRIVATE);
        int oldPort = prefs.getInt("webui_port", 8080);
        prefs.edit().putInt("webui_port", port).apply();
        updateQbtConfig("WebUI\\Port=", "WebUI\\Port=" + port);

        // 写入文件供 Service 读取
        File portFile = new File(getFilesDir(), "webui_port.txt");
        try (FileOutputStream fos = new FileOutputStream(portFile)) {
            fos.write(String.valueOf(port).getBytes("UTF-8"));
        } catch (IOException ignored) {}

        final int newPort = port;
        new Thread(() -> {
            try {
                String json = "{\"web_ui_port\":" + newPort + "}";
                URL url = new URL("http://127.0.0.1:" + oldPort + "/api/v2/app/setPreferences");
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
                runOnUiThread(() -> {
                    if (code == 200) {
                        Toast.makeText(this, "端口已改为 " + newPort + "（重启后生效）", Toast.LENGTH_SHORT).show();
                    } else {
                        Toast.makeText(this, "保存失败 HTTP " + code, Toast.LENGTH_SHORT).show();
                    }
                });
            } catch (Exception e) {
                runOnUiThread(() -> Toast.makeText(this, "保存失败: " + e.getMessage(), Toast.LENGTH_SHORT).show());
            }
        }).start();
    }

    private void saveDownloadPath() {
        String path = etDownloadPath.getText().toString().trim();
        if (path.isEmpty()) {
            Toast.makeText(this, "请输入下载路径", Toast.LENGTH_SHORT).show();
            return;
        }

        SharedPreferences prefs = getSharedPreferences("qbt_prefs", MODE_PRIVATE);
        prefs.edit().putString("download_path", path).apply();
        updateQbtConfig("Downloads\\SavePath=", "Downloads\\SavePath=" + path);

        // 写入文件供 Service 读取
        File pathFile = new File(getFilesDir(), "download_path.txt");
        try (FileOutputStream fos = new FileOutputStream(pathFile)) {
            fos.write(path.getBytes("UTF-8"));
        } catch (IOException ignored) {}

        int port = prefs.getInt("webui_port", 8080);
        // 通过 API 设置
        new Thread(() -> {
            try {
                String json = "{\"save_path\":\"" + path.replace("\\", "\\\\") + "\"}";
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
                runOnUiThread(() -> {
                    if (code == 200) {
                        Toast.makeText(this, "下载路径已更新", Toast.LENGTH_SHORT).show();
                    } else {
                        Toast.makeText(this, "保存失败 HTTP " + code, Toast.LENGTH_SHORT).show();
                    }
                });
            } catch (Exception e) {
                runOnUiThread(() -> Toast.makeText(this, "保存失败: " + e.getMessage(), Toast.LENGTH_SHORT).show());
            }
        }).start();
    }

    /** 更新 qBittorrent.conf 中的某个 key */
    private void updateQbtConfig(String keyPrefix, String newLine) {
        File cfgFile = new File(getFilesDir(), "config/qBittorrent/config/qBittorrent.conf");
        if (!cfgFile.exists()) return;
        try {
            StringBuilder sb = new StringBuilder();
            boolean replaced = false;
            boolean inserted = false;
            try (BufferedReader br = new BufferedReader(new FileReader(cfgFile))) {
                String line;
                while ((line = br.readLine()) != null) {
                    if (!replaced && line.trim().startsWith(keyPrefix)) {
                        sb.append(newLine).append("\n");
                        replaced = true;
                    } else {
                        sb.append(line).append("\n");
                        // 如果 key 不存在，在 [Preferences] section 开头追加
                        if (!replaced && !inserted && line.trim().equals("[Preferences]")) {
                            // 标记下一个非空行前插入
                            inserted = true;
                        }
                    }
                }
            }
            if (!replaced) {
                if (inserted) {
                    // 在 [Preferences] 后面插入（通过重新构建）
                    String content = sb.toString();
                    content = content.replace("[Preferences]\n", "[Preferences]\n" + newLine + "\n");
                    try (FileWriter w = new FileWriter(cfgFile)) {
                        w.write(content);
                    }
                } else {
                    sb.append(newLine).append("\n");
                    try (FileWriter w = new FileWriter(cfgFile)) {
                        w.write(sb.toString());
                    }
                }
            } else {
                try (FileWriter w = new FileWriter(cfgFile)) {
                    w.write(sb.toString());
                }
            }
        } catch (IOException ignored) {}
    }
}
