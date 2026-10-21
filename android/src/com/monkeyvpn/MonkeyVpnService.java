package com.monkeyvpn;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Intent;
import android.net.VpnService;
import android.os.ParcelFileDescriptor;

import org.json.JSONObject;

import java.io.File;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;

public class MonkeyVpnService extends VpnService {

    static Process xrayProc = null;
    static Process tunProc = null;
    static ParcelFileDescriptor tun = null;

    static final String ACTION_CONNECT = "com.monkeyvpn.CONNECT";
    static final String ACTION_STOP = "com.monkeyvpn.STOP";
    static final int MTU = 8500;

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_STOP.equals(intent.getAction())) {
            stopAll();
            stopSelf();
            return START_NOT_STICKY;
        }
        if (intent != null && ACTION_CONNECT.equals(intent.getAction())) {
            final String config = intent.getStringExtra("config");
            foreground();
            new Thread(() -> {
                try {
                    start(config);
                    MainActivity.notifyServiceState(true, null);
                } catch (Exception e) {
                    MainActivity.notifyServiceState(false, e.getMessage());
                }
            }).start();
        }
        return START_NOT_STICKY;
    }

    void start(String configJson) throws Exception {
        stopAll();

        // 1. Пишем конфиг Xray
        File cfg = new File(getFilesDir(), "config.json");
        OutputStreamWriter w = new OutputStreamWriter(new java.io.FileOutputStream(cfg), StandardCharsets.UTF_8);
        w.write(configJson);
        w.close();

        // 2. Запускаем локальный прокси Xray (SOCKS 127.0.0.1:10808)
        String libDir = getApplicationInfo().nativeLibraryDir;
        File assetsDir = new File(getFilesDir(), "assets");
        if (!assetsDir.exists()) assetsDir.mkdirs();
        copyAssetIfMissing("geoip.dat", assetsDir);
        copyAssetIfMissing("geosite.dat", assetsDir);

        ProcessBuilder pb = new ProcessBuilder(libDir + "/libxray.so", "run", "-c", cfg.getAbsolutePath());
        pb.redirectErrorStream(true);
        pb.environment().put("XRAY_LOCATION_ASSET", assetsDir.getAbsolutePath());
        xrayProc = pb.start();
        Thread.sleep(1500);
        if (!xrayProc.isAlive()) {
            xrayProc = null;
            throw new Exception("Xray завершился с ошибкой.");
        }

        // 3. Создаём TUN-интерфейс
        Builder b = new Builder()
                .setSession("Monkey VPN")
                .addAddress("198.18.0.1", 32)
                .addRoute("0.0.0.0", 0)
                .addDnsServer("1.1.1.1")
                .setMtu(MTU);
        try {
            // Трафик нашего приложения (Xray outbound) идёт мимо VPN - без петли
            b.addDisallowedApplication(getPackageName());
        } catch (Exception e) { }

        tun = b.establish();
        if (tun == null) {
            throw new Exception("Не удалось создать VPN-интерфейс (проверь разрешение).");
        }
        int fd = tun.getFd();

        // 4. Снимаем CLOEXEC, чтобы fd унаследовал дочерний процесс
        try {
            android.system.Os.fcntlInt(tun.getFileDescriptor(), android.system.OsConstants.F_SETFD, 0);
        } catch (Exception e) { }

        // 5. Запускаем tun2socks: TUN -> SOCKS5 (локальный Xray)
        ProcessBuilder tpb = new ProcessBuilder(
                libDir + "/libtun2socks.so",
                "-device", "fd://" + fd,
                "-proxy", "socks5://127.0.0.1:10808",
                "-mtu", String.valueOf(MTU),
                "-loglevel", "warning");
        tpb.redirectErrorStream(true);
        tunProc = tpb.start();
        Thread.sleep(1200);
        if (!tunProc.isAlive()) {
            tunProc = null;
            throw new Exception("tun2socks не стартовал (неожиданно завершился).");
        }

        MainActivity.notifyServiceState(true, null);
    }

    void stopAll() {
        if (tunProc != null) {
            try { tunProc.destroy(); } catch (Exception e) { }
            try { tunProc.waitFor(); } catch (Exception e) { }
            tunProc = null;
        }
        // На случай, если остался процесс от старого запуска приложения
        try {
            new ProcessBuilder("pkill", "-f", "libxray.so").start();
        } catch (Exception e) { }
        if (xrayProc != null) {
            try { xrayProc.destroy(); } catch (Exception e) { }
            try { xrayProc.waitFor(); } catch (Exception e) { }
            xrayProc = null;
        }
        if (tun != null) {
            try { tun.close(); } catch (Exception e) { }
            tun = null;
        }
    }

    void copyAssetIfMissing(String name, File toDir) {
        File f = new File(toDir, name);
        if (f.exists() && f.length() > 0) return;
        try (java.io.InputStream in = getAssets().open(name);
             java.io.OutputStream out = new java.io.FileOutputStream(f)) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
        } catch (Exception e) { }
    }

    void foreground() {
        try {
            NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
            String id = "monkey";
            NotificationChannel ch = new NotificationChannel(id, "Monkey VPN", NotificationManager.IMPORTANCE_LOW);
            nm.createNotificationChannel(ch);
            Notification n = new Notification.Builder(this, id)
                    .setContentTitle("Monkey VPN")
                    .setContentText("VPN активен")
                    .setSmallIcon(android.R.drawable.ic_lock_lock)
                    .build();
            startForeground(1, n);
        } catch (Exception e) { }
    }

    @Override
    public void onRevoke() {
        stopAll();
        stopSelf();
        MainActivity.notifyServiceState(false, "VPN отключён системой.");
    }
}
