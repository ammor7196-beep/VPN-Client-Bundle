package com.monkeyvpn;

import android.app.Activity;
import android.content.Intent;
import android.net.VpnService;
import android.os.Bundle;
import android.util.Base64;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONArray;
import org.json.JSONObject;
import org.json.JSONTokener;

import java.io.File;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.net.HttpURLConnection;
import java.net.InetSocketAddress;
import java.net.Proxy;
import java.net.URL;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

public class MainActivity extends Activity {

    static class Server {
        String name;
        String scheme;
        JSONObject outbound;
        Server(String n, String s, JSONObject o) { name = n; scheme = s; outbound = o; }
        public String toString() { return "[" + scheme + "] " + name; }
    }

    EditText urlBox;
    ListView listServers;
    Button btnLoad, btnConnect, btnDisconnect;
    TextView txtStatus, txtInfo;
    ArrayAdapter<String> adapter;
    List<Server> servers = new ArrayList<>();
    String savedUrl = "";
    boolean connected = false;

    static final int SOCKS_PORT = 10808;
    static final int HTTP_PORT  = 10809;
    Process xrayProc = null;
    static MainActivity instance = null;

    public static void notifyServiceState(boolean ok, String message) {
        MainActivity a = instance;
        if (a == null) return;
        a.runOnUiThread(() -> {
            if (ok) a.setStatus("Подключено! Весь трафик идёт через VPN.", 0xFF9BE79B);
            else a.setStatus("Ошибка VPN: " + message, 0xFFFFB4B4);
        });
    }

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        instance = this;
        savedUrl = getPreferences(MODE_PRIVATE).getString("url", "");

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(16);
        root.setPadding(pad, pad, pad, pad);
        root.setBackgroundColor(0xFF1E1E2E);

        TextView lblUrl = label("Ссылка на подписку Monkey VPN:", 16, 0xFFCCCCCC);
        root.addView(lblUrl);

        urlBox = new EditText(this);
        urlBox.setSingleLine(true);
        urlBox.setText(savedUrl);
        urlBox.setTextColor(0xFFFFFFFF);
        urlBox.setHintTextColor(0xFF666680);
        urlBox.setHint("https://sub.monkeyvpn.example/...");
        urlBox.setBackgroundColor(0xFF2B2B40);
        urlBox.setPadding(dp(8), dp(8), dp(8), dp(8));
        root.addView(urlBox, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        btnLoad = darkButton("Загрузить");
        btnLoad.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) { loadSubscription(); }
        });
        root.addView(btnLoad, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        TextView lblServers = label("Серверы:", 16, 0xFFCCCCCC);
        lblServers.setPadding(0, dp(12), 0, dp(4));
        root.addView(lblServers);

        adapter = new ArrayAdapter<>(this, android.R.layout.simple_list_item_1);
        listServers = new ListView(this);
        listServers.setAdapter(adapter);
        listServers.setBackgroundColor(0xFF2B2B40);
        listServers.setOnItemClickListener((p, v, pos, id) -> btnConnect.performClick());
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0);
        lp.weight = 1;
        root.addView(listServers, lp);

        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        btnConnect = darkButton("Подключить");
        btnConnect.setOnClickListener(v -> connectSelected());
        btnDisconnect = darkButton("Отключить");
        btnDisconnect.setOnClickListener(v -> disconnect());
        row.addView(btnConnect, rowParams());
        row.addView(btnDisconnect, rowParams());
        root.addView(row, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        txtStatus = label("Не подключено", 15, 0xFFFFB4B4);
        txtStatus.setPadding(0, dp(12), 0, 0);
        root.addView(txtStatus);

        txtInfo = label("SOCKS 127.0.0.1:" + SOCKS_PORT + " · HTTP 127.0.0.1:" + HTTP_PORT, 12, 0xFF8888A0);
        txtInfo.setPadding(0, dp(6), 0, 0);
        root.addView(txtInfo);

        setContentView(root);
    }

    TextView label(String text, int sp, int color) {
        TextView tv = new TextView(this);
        tv.setText(text);
        tv.setTextSize(sp);
        tv.setTextColor(color);
        return tv;
    }

    Button darkButton(String text) {
        Button b = new Button(this);
        b.setText(text);
        b.setTextColor(0xFFFFFFFF);
        b.setBackgroundColor(0xFF5B5BD6);
        return b;
    }

    LinearLayout.LayoutParams rowParams() {
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT);
        p.weight = 1;
        p.setMargins(dp(4), dp(12), dp(4), 0);
        return p;
    }

    int dp(int v) { return Math.round(v * getResources().getDisplayMetrics().density); }

    void setStatus(String text, int color) {
        txtStatus.setText(text);
        txtStatus.setTextColor(color);
    }

    void toast(String t) { Toast.makeText(this, t, Toast.LENGTH_SHORT).show(); }

    // ---------------- Subscription ----------------

    void loadSubscription() {
        final String url = urlBox.getText().toString().trim();
        if (url.isEmpty()) { setStatus("Вставь сначала ссылку на подписку.", 0xFFFFB4B4); return; }
        getPreferences(MODE_PRIVATE).edit().putString("url", url).apply();
        setStatus("Загружаю подписку...", 0xFFFFD48A);

        new Thread(() -> {
            try {
                String content = httpGet(url, null);
                String decoded = content;
                if (!decoded.contains("://")) {
                    try { decoded = b64ToString(content); } catch (Exception e) { decoded = content; }
                }
                final List<Server> parsed = parseContent(decoded);
                runOnUiThread(() -> {
                    servers = parsed;
                    adapter.clear();
                    adapter.notifyDataSetChanged();
                    for (Server s : servers) adapter.add(s.toString());
                    if (servers.isEmpty()) {
                        setStatus("Подписка получена, но серверы не распознаны.", 0xFFFFB4B4);
                    } else {
                        setStatus("Загружено серверов: " + servers.size() + ". Выбери сервер.", 0xFF9BE79B);
                    }
                });
            } catch (Exception e) {
                final String msg = e.getMessage();
                runOnUiThread(() -> setStatus("Ошибка загрузки подписки: " + msg, 0xFFFFB4B4));
            }
        }).start();
    }

    String httpGet(String url, Proxy proxy) throws Exception {
        URL u = new URL(url);
        HttpURLConnection conn = (HttpURLConnection) (proxy != null ? u.openConnection(proxy) : u.openConnection());
        conn.setInstanceFollowRedirects(true);
        conn.setConnectTimeout(15000);
        conn.setReadTimeout(30000);
        conn.setRequestProperty("User-Agent", "v2rayNG/1.9");
        int code = conn.getResponseCode();
        InputStream is = code >= 400 ? conn.getErrorStream() : conn.getInputStream();
        StringBuilder sb = new StringBuilder();
        if (is != null) {
            InputStreamReader r = new InputStreamReader(is, StandardCharsets.UTF_8);
            char[] buf = new char[4096];
            int n;
            while ((n = r.read(buf)) > 0) sb.append(buf, 0, n);
            r.close();
        }
        conn.disconnect();
        if (code >= 400) throw new Exception("HTTP " + code);
        return sb.toString();
    }

    String b64ToString(String s) {
        String t = s.replaceAll("\\s", "").replace('-', '+').replace('_', '/');
        int pad = (4 - (t.length() % 4)) % 4;
        for (int i = 0; i < pad; i++) t += "=";
        return new String(Base64.decode(t, Base64.DEFAULT), StandardCharsets.UTF_8);
    }

    // ---------------- Parsing ----------------

    List<Server> parseContent(String content) {
        List<Server> out = new ArrayList<>();
        for (String raw : content.split("\n")) {
            String link = raw.trim();
            if (link.isEmpty() || !link.contains("://")) continue;
            try {
                if (link.startsWith("vmess://")) addVmess(out, link);
                else if (link.startsWith("vless://")) addVless(out, link);
                else if (link.startsWith("trojan://")) addTrojan(out, link);
                else if (link.startsWith("ss://")) addSs(out, link);
            } catch (Exception e) { }
        }
        return out;
    }

    void addVmess(List<Server> out, String link) throws Exception {
        JSONObject j = new JSONObject(new JSONTokener(b64ToString(link.substring(8))));
        JSONObject settings = new JSONObject();
        JSONObject user = new JSONObject();
        user.put("id", j.getString("id"));
        user.put("alterId", j.optInt("aid", 0));
        user.put("security", j.optString("scy", "auto"));
        user.put("level", 0);
        JSONObject vnext = new JSONObject();
        vnext.put("address", j.getString("add"));
        vnext.put("port", j.getInt("port"));
        vnext.put("users", new JSONArray().put(user));
        settings.put("vnext", new JSONArray().put(vnext));

        String net = j.optString("net", "tcp");
        String sec = "tls".equals(j.optString("tls")) ? "tls" : "";
        JSONObject stream = buildStream(net, sec, null, j.optString("sni"), j.optString("host"), j.optString("path"), "");
        JSONObject ob = new JSONObject().put("tag", "proxy").put("protocol", "vmess").put("settings", settings).put("streamSettings", stream);
        out.add(new Server(j.optString("ps", "vmess"), "vmess", ob));
    }

    void addVless(List<Server> out, String link) throws Exception {
        String rest = link.substring("vless://".length());
        int sharp = rest.indexOf('#');
        String name = "vless";
        if (sharp >= 0) { name = URLDecoder.decode(rest.substring(sharp + 1), "UTF-8"); rest = rest.substring(0, sharp); }
        int at = rest.indexOf('@');
        String id = URLDecoder.decode(rest.substring(0, at), "UTF-8");
        String hostportqs = rest.substring(at + 1);
        String[] hpQ = splitQuery(hostportqs);
        String hostPort = hpQ[0];
        java.util.Map<String, String> q = parseQuery(hpQ[1]);
        int colon = hostPort.indexOf(':');
        String host = hostPort.substring(0, colon);
        int port = Integer.parseInt(hostPort.substring(colon + 1).split("/")[0]);

        JSONObject settings = new JSONObject();
        JSONObject user = new JSONObject();
        user.put("id", id);
        user.put("encryption", "none");
        String flow = qopt(q, "flow", "");
        if (!flow.isEmpty()) user.put("flow", flow);
        JSONObject vnext = new JSONObject();
        vnext.put("address", host);
        vnext.put("port", port);
        vnext.put("users", new JSONArray().put(user));
        settings.put("vnext", new JSONArray().put(vnext));

        String net = qopt(q, "type", "tcp");
        if (net.equals("raw")) net = "tcp";
        String sec = qopt(q, "security", "");
        if (sec.equals("none")) sec = "";
        JSONObject stream = buildStream(net, sec, q, qopt(q, "sni", ""), qopt(q, "host", ""), qopt(q, "path", ""), qopt(q, "serviceName", ""));
        JSONObject ob = new JSONObject().put("tag", "proxy").put("protocol", "vless").put("settings", settings).put("streamSettings", stream);
        out.add(new Server(name, "vless", ob));
    }

    void addTrojan(List<Server> out, String link) throws Exception {
        String rest = link.substring("trojan://".length());
        int sharp = rest.indexOf('#');
        String name = "trojan";
        if (sharp >= 0) { name = URLDecoder.decode(rest.substring(sharp + 1), "UTF-8"); rest = rest.substring(0, sharp); }
        int at = rest.indexOf('@');
        String password = URLDecoder.decode(rest.substring(0, at), "UTF-8");
        String[] hpQ = splitQuery(rest.substring(at + 1));
        java.util.Map<String, String> q = parseQuery(hpQ[1]);
        String hostPort = hpQ[0];
        int colon = hostPort.indexOf(':');
        String host = hostPort.substring(0, colon);
        int port = Integer.parseInt(hostPort.substring(colon + 1).split("/")[0]);

        JSONObject settings = new JSONObject();
        JSONObject srv = new JSONObject();
        srv.put("address", host);
        srv.put("port", port);
        srv.put("password", password);
        settings.put("servers", new JSONArray().put(srv));
        JSONObject stream = buildStream(qopt(q, "type", "tcp"), "tls", q, qopt(q, "sni", ""), qopt(q, "host", ""), qopt(q, "path", ""), "");
        JSONObject ob = new JSONObject().put("tag", "proxy").put("protocol", "trojan").put("settings", settings).put("streamSettings", stream);
        out.add(new Server(name, "trojan", ob));
    }

    void addSs(List<Server> out, String link) throws Exception {
        String body = link.substring(5);
        String tag = "ss";
        int sharp = body.indexOf('#');
        if (sharp >= 0) { tag = URLDecoder.decode(body.substring(sharp + 1), "UTF-8"); body = body.substring(0, sharp); }

        String method = null, password = null, host = null; int port = -1;
        int at = body.indexOf('@');
        if (at >= 0) {
            String userinfo = URLDecoder.decode(body.substring(0, at), "UTF-8");
            String hostPart = body.substring(at + 1);
            try {
                String plain = b64ToString(userinfo);
                if (plain.contains(":")) {
                    int c = plain.indexOf(':');
                    method = plain.substring(0, c); password = plain.substring(c + 1);
                }
            } catch (Exception e) { }
            if (method == null) {
                int c = userinfo.indexOf(':');
                method = userinfo.substring(0, c);
                password = userinfo.substring(c + 1);
            }
            int colon = hostPart.indexOf(':');
            host = hostPart.substring(0, colon);
            port = Integer.parseInt(hostPart.substring(colon + 1).split("/")[0]);
        } else {
            String plain = b64ToString(URLDecoder.decode(body, "UTF-8"));
            if (plain.matches("(?s)[^@:]+:[^@]+@[^:]+:\\d+")) {
                int c1 = plain.indexOf(':');
                int at2 = plain.indexOf('@');
                int c2 = plain.lastIndexOf(':');
                method = plain.substring(0, c1);
                password = plain.substring(c1 + 1, at2);
                host = plain.substring(at2 + 1, c2);
                port = Integer.parseInt(plain.substring(c2 + 1));
            }
        }
        if (method == null || password == null || host == null || port <= 0) return;

        JSONObject settings = new JSONObject();
        JSONObject srv = new JSONObject();
        srv.put("address", host);
        srv.put("port", port);
        srv.put("method", method);
        srv.put("password", password);
        settings.put("servers", new JSONArray().put(srv));
        JSONObject ob = new JSONObject().put("tag", "proxy").put("protocol", "shadowsocks").put("settings", settings);
        out.add(new Server(tag, "ss", ob));
    }

    String[] splitQuery(String s) {
        int q = s.indexOf('?');
        if (q >= 0) return new String[] { s.substring(0, q), s.substring(q + 1) };
        int slash = s.indexOf('/');
        if (slash >= 0) return new String[] { s.substring(0, slash), "" };
        return new String[] { s, "" };
    }

    java.util.Map<String, String> parseQuery(String qs) {
        java.util.Map<String, String> m = new java.util.HashMap<>();
        if (qs == null || qs.isEmpty()) return m;
        if (qs.startsWith("?")) qs = qs.substring(1);
        for (String pair : qs.split("&")) {
            if (pair.isEmpty()) continue;
            int eq = pair.indexOf('=');
            String k = eq < 0 ? pair : pair.substring(0, eq);
            String v = eq < 0 ? "" : pair.substring(eq + 1);
            try {
                m.put(URLDecoder.decode(k, "UTF-8").toLowerCase(), URLDecoder.decode(v, "UTF-8"));
            } catch (Exception e) { }
        }
        return m;
    }

    String qopt(java.util.Map<String, String> q, String key, String def) {
        if (q == null) return def;
        String v = q.get(key);
        return v == null ? def : v;
    }

    JSONObject buildStream(String net, String sec, java.util.Map<String, String> q, String sni, String host, String path, String service) throws Exception {
        JSONObject st = new JSONObject().put("network", net).put("security", sec == null || sec.isEmpty() ? "none" : sec);
        switch (net) {
            case "ws": {
                JSONObject ws = new JSONObject();
                ws.put("path", path == null || path.isEmpty() ? "/" : path);
                if (host != null && !host.isEmpty()) ws.put("headers", new JSONObject().put("Host", host));
                st.put("wsSettings", ws);
                break;
            }
            case "http":
            case "h2":
            case "tcp": {
                if (("http".equals(net) || "h2".equals(net)) && path != null && !path.isEmpty()) {
                    JSONObject h = new JSONObject().put("path", path);
                    if (host != null && !host.isEmpty()) h.put("host", new JSONArray().put(host));
                    st.put("httpSettings", h);
                }
                break;
            }
            case "grpc": {
                JSONObject g = new JSONObject().put("serviceName", service == null ? "" : service);
                if (q != null && "multi".equals(qopt(q, "mode", ""))) g.put("multiMode", true);
                st.put("grpcSettings", g);
                break;
            }
            case "kcp": {
                JSONObject kcp = new JSONObject()
                        .put("mtu", 1350).put("tti", 50)
                        .put("uplinkCapacity", 12).put("downlinkCapacity", 100)
                        .put("congestion", false);
                kcp.put("header", new JSONObject().put("type", qopt(q, "type", "none")));
                st.put("kcpSettings", kcp);
                break;
            }
        }
        if ("tls".equals(sec)) {
            JSONObject tls = new JSONObject();
            tls.put("serverName", sni == null || sni.isEmpty() ? (host == null ? "" : host) : sni);
            if (q != null && qopt(q, "fp", "") != null && !qopt(q, "fp", "").isEmpty()) tls.put("fingerprint", qopt(q, "fp", ""));
            if (q != null && "1".equals(qopt(q, "allowInsecure", ""))) tls.put("allowInsecure", true);
            st.put("tlsSettings", tls);
        } else if ("reality".equals(sec)) {
            JSONObject r = new JSONObject();
            String rSni = qopt(q, "sni", "");
            r.put("serverName", rSni.isEmpty() ? (sni == null || sni.isEmpty() ? host : sni) : rSni);
            r.put("publicKey", qopt(q, "pbk", ""));
            r.put("shortId", qopt(q, "sid", ""));
            if (!qopt(q, "fp", "").isEmpty()) r.put("fingerprint", qopt(q, "fp", ""));
            if (!qopt(q, "spx", "").isEmpty()) r.put("spiderX", qopt(q, "spx", ""));
            st.put("realitySettings", r);
        }
        return st;
    }

    // ---------------- Xray core ----------------

    String xrayBinaryPath() {
        return getApplicationInfo().nativeLibraryDir + "/libxray.so";
    }

    File assetsDir() {
        // Xray ищет geoip.dat/geosite.dat рядом (XRAY_LOCATION_ASSET)
        File dir = new File(getFilesDir(), "assets");
        if (!dir.exists()) dir.mkdirs();
        copyIfMissing("geoip.dat", dir);
        copyIfMissing("geosite.dat", dir);
        return dir;
    }

    void copyIfMissing(String name, File toDir) {
        File f = new File(toDir, name);
        if (f.exists() && f.length() > 0) return;
        try (InputStream in = getAssets().open(name);
             java.io.OutputStream out = new java.io.FileOutputStream(f)) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
        } catch (Exception e) { }
    }

    File configPath() { return new File(getFilesDir(), "config.json"); }

    void connectSelected() {
        if (servers.isEmpty()) { setStatus("Сначала загрузи подписку.", 0xFFFFB4B4); return; }
        int pos = listServers.getCheckedItemPosition();
        if (pos < 0 || pos >= servers.size()) pos = 0;
        final Server server = servers.get(pos);

        // Спросить разрешение у системы на VPN (один раз)
        try {
            Intent prep = VpnService.prepare(this);
            if (prep != null) { startActivityForResult(prep, 1); return; }
        } catch (Exception e) {
            setStatus("Не удалось запросить разрешение VPN: " + e.getMessage(), 0xFFFFB4B4);
            return;
        }
        startVpn(server);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == 1) {
            if (resultCode == RESULT_OK) {
                int pos = listServers.getCheckedItemPosition();
                if (pos < 0 || pos >= servers.size()) pos = 0;
                startVpn(servers.get(pos));
            } else {
                setStatus("Разрешение VPN не выдано.", 0xFFFFB4B4);
            }
        }
    }

    void startVpn(Server server) {
        setStatus("Подключаюсь к " + server + " ...", 0xFFFFD48A);
        try {
            String config = buildConfig(server).toString();
            Intent it = new Intent(this, MonkeyVpnService.class)
                    .setAction(MonkeyVpnService.ACTION_CONNECT)
                    .putExtra("config", config)
                    .putExtra("name", server.name);
            startService(it);
        } catch (Exception e) {
            setStatus("Ошибка: " + e.getMessage(), 0xFFFFB4B4);
        }
    }

    void disconnect() {
        startService(new Intent(this, MonkeyVpnService.class)
                .setAction(MonkeyVpnService.ACTION_STOP));
        setStatus("Не подключено.", 0xFFCCCCCC);
        txtInfo.setText("SOCKS 127.0.0.1:" + SOCKS_PORT + " · HTTP 127.0.0.1:" + HTTP_PORT);
    }

    JSONObject buildConfig(Server server) throws Exception {
        JSONArray inbounds = new JSONArray();
        JSONObject sniff = new JSONObject()
                .put("enabled", true)
                .put("destOverride", new JSONArray().put("http").put("tls"));
        JSONObject socksIn = new JSONObject()
                .put("tag", "socks-in").put("listen", "127.0.0.1").put("port", SOCKS_PORT)
                .put("protocol", "socks")
                .put("sniffing", sniff)
                .put("settings", new JSONObject().put("auth", "noauth").put("udp", true));
        JSONObject httpIn = new JSONObject()
                .put("tag", "http-in").put("listen", "127.0.0.1").put("port", HTTP_PORT)
                .put("protocol", "http")
                .put("settings", new JSONObject().put("auth", "noauth").put("udp", true));
        inbounds.put(socksIn).put(httpIn);

        JSONArray outbounds = new JSONArray();
        outbounds.put(server.outbound);
        outbounds.put(new JSONObject().put("tag", "direct").put("protocol", "freedom").put("settings", new JSONObject()));
        outbounds.put(new JSONObject().put("tag", "block").put("protocol", "blackhole").put("settings", new JSONObject()));

        JSONObject rule1 = new JSONObject().put("type", "field")
                .put("domain", new JSONArray().put("geosite:private")).put("outboundTag", "direct");
        JSONObject rule2 = new JSONObject().put("type", "field")
                .put("ip", new JSONArray().put("geoip:private")).put("outboundTag", "direct");
        JSONObject routing = new JSONObject()
                .put("domainStrategy", "AsIs")
                .put("rules", new JSONArray().put(rule1).put(rule2));

        JSONObject log = new JSONObject().put("loglevel", "warning").put("access", "none").put("error", "none");
        return new JSONObject()
                .put("log", log)
                .put("inbounds", inbounds)
                .put("outbounds", outbounds)
                .put("routing", routing);
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
    }
}
