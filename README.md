# VPN-Client-Bundle

Клиентские приложения для VPN-сервиса **Monkey VPN** на открытом ядре [Xray-core](https://github.com/XTLS/Xray-core) (V2Ray).

- 🖥 **windows/** — приложение для Windows (PowerShell + WPF GUI)
- 📱 **android/** — приложение для Android (APK, VpnService + tun2socks)

## Возможности

- Вставь ссылку на подписку →getLocale список серверов → подключение одним кликом
- Поддержка протоколов: **vmess, vless (TLS/REALITY), trojan, shadowsocks**
- Автоматическое включение системного VPN/прокси
- Отображение твоего IP и страны после подключения

## Windows

Всё уже готово: скопируй папку `windows/`, в ней лежит `Core/xray.exe`. Запусти **`Monkey VPN.bat`**.
Подробнее: [windows/README.md](windows/README.md)

## Android

Готовый APK в `android/MonkeyVPN.apk` (+ см. Releases) — просто перебрось на телефон и установи.
Сборку можно повторить: `powershell android/build.ps1` (нужны JDK 17 и Android SDK, пути без кириллицы).
Подробнее: [android/README.md](android/README.md)

## Сборка Android из исходников

```
powershell android/build.ps1
```

Скрипт: javac → d8 → aapt2 → zip → apksigner (без Gradle). Пути сборки прописаны в `build.ps1` (C:\Users\user\MonkeyBuild и C:\Users\user\MonkeyProj).

## Дисклеймер

- Приложение приватно для личного использования, не публикуй свою ссылку на подписку.
- VPN не делает трафик анонимным на 100%.

Лицензия: MIT (только собственный код; Xray-core и tun2socks — под их лицензиями)
