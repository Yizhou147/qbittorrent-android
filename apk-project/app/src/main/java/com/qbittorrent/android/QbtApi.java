package com.qbittorrent.android;

import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;

/** 调用本机 qBittorrent WebUI API 的工具方法 */
final class QbtApi {

    private static final int TIMEOUT_MS = 5000;

    private QbtApi() {
    }

    /** POST /api/v2/app/setPreferences，返回 HTTP 状态码，网络异常返回 -1 */
    static int setPreferences(int port, String json) {
        try {
            URL url = new URL("http://127.0.0.1:" + port + "/api/v2/app/setPreferences");
            HttpURLConnection conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("POST");
            conn.setDoOutput(true);
            conn.setConnectTimeout(TIMEOUT_MS);
            conn.setReadTimeout(TIMEOUT_MS);
            conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded");
            String params = "json=" + URLEncoder.encode(json, "UTF-8");
            try (OutputStream os = conn.getOutputStream()) {
                os.write(params.getBytes("UTF-8"));
            }
            int code = conn.getResponseCode();
            conn.disconnect();
            return code;
        } catch (Exception e) {
            return -1;
        }
    }
}
