package com.qbittorrent.android;

import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.os.Environment;
import android.view.View;
import android.view.animation.AlphaAnimation;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;
import androidx.appcompat.app.AppCompatActivity;

public class WelcomeActivity extends AppCompatActivity {

    private EditText etPort;
    private EditText etPath;
    private LinearLayout cardVuetorrent;
    private LinearLayout cardDefault;
    private String selectedUI = "vuetorrent";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        SharedPreferences prefs = getSharedPreferences("qbt_prefs", MODE_PRIVATE);
        if (prefs.getBoolean("setup_done", false)) {
            startActivity(new Intent(this, MainActivity.class));
            finish();
            return;
        }

        setContentView(R.layout.activity_welcome);

        TextView title = findViewById(R.id.tvWelcomeTitle);
        AlphaAnimation fadeIn = new AlphaAnimation(0f, 1f);
        fadeIn.setDuration(800);
        title.startAnimation(fadeIn);

        etPort = findViewById(R.id.etWelcomePort);
        etPath = findViewById(R.id.etWelcomePath);
        cardVuetorrent = findViewById(R.id.cardVuetorrent);
        cardDefault = findViewById(R.id.cardDefault);

        // 默认下载路径
        etPath.setText(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).getAbsolutePath());

        cardVuetorrent.setOnClickListener(v -> {
            selectedUI = "vuetorrent";
            cardVuetorrent.setBackgroundResource(R.drawable.card_selected_bg);
            cardDefault.setBackgroundResource(R.drawable.card_bg);
        });
        cardDefault.setOnClickListener(v -> {
            selectedUI = "default";
            cardDefault.setBackgroundResource(R.drawable.card_selected_bg);
            cardVuetorrent.setBackgroundResource(R.drawable.card_bg);
        });

        // 默认选中 VueTorrent
        cardVuetorrent.setBackgroundResource(R.drawable.card_selected_bg);

        findViewById(R.id.btnStart).setOnClickListener(v -> startApp());
    }

    private void startApp() {
        String portStr = etPort.getText().toString().trim();
        String path = etPath.getText().toString().trim();

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

        if (path.isEmpty()) {
            Toast.makeText(this, "请输入下载路径", Toast.LENGTH_SHORT).show();
            return;
        }

        SharedPreferences prefs = getSharedPreferences("qbt_prefs", MODE_PRIVATE);
        prefs.edit()
                .putString("webui_type", selectedUI)
                .putInt("webui_port", port)
                .putString("download_path", path)
                .putBoolean("setup_done", true)
                .apply();

        startActivity(new Intent(this, MainActivity.class));
        overridePendingTransition(android.R.anim.fade_in, android.R.anim.fade_out);
        finish();
    }
}
