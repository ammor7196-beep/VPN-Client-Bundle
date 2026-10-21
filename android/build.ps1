# Сборка Monkey VPN APK без Gradle
$proj = Split-Path -Parent $MyInvocation.MyCommand.Path
$build = "C:\Users\user\MonkeyBuild"
$sdk = "$build\android-sdk"
$env:JAVA_HOME = "$build\jdk-17.0.20.1+1"
$env:Path = "$env:JAVA_HOME\bin;$sdk\build-tools\34.0.0;$env:Path"

$platform = "$sdk\platforms\android-34\android.jar"
$bt = "$sdk\build-tools\34.0.0"
$out = "$proj\build-out"
Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$out\classes", "$out\dex" | Out-Null

# 1. Компиляция Java
Write-Host "== javac =="
javac --release 8 -encoding UTF-8 -cp $platform -d "$out\classes" `
    "$proj\src\com\monkeyvpn\MainActivity.java" "$proj\src\com\monkeyvpn\MonkeyVpnService.java"
if ($LASTEXITCODE -ne 0) { throw "javac failed" }

# 2. DEX
Write-Host "== d8 =="
java -cp "$bt\lib\d8.jar" com.android.tools.r8.D8 --release --lib $platform `
    --output "$out\dex" (Get-ChildItem "$out\classes" -Recurse -Filter *.class | ForEach-Object { $_.FullName })
if ($LASTEXITCODE -ne 0) { throw "d8 failed" }

# 3. Базовый APK (манифест + assets)
Write-Host "== aapt2 =="
& "$bt\aapt2.exe" link -o "$out\base.apk" -I $platform --manifest "$proj\AndroidManifest.xml" -A "$proj\assets" --auto-add-overlay
if ($LASTEXITCODE -ne 0) { throw "aapt2 link failed" }

# 4. Внедряем classes.dex и нативные библиотеки через Zip API
Write-Host "== zip =="
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
Copy-Item "$out\base.apk" "$out\MonkeyVPN.apk" -Force
$apk = [System.IO.Compression.ZipFile]::Open("$out\MonkeyVPN.apk", 'Update')

function Add-ZipEntry($zip, $path, $file, $useUTF8 = $true) {
    $entry = $zip.CreateEntry($path, [System.IO.Compression.CompressionLevel]::Optimal)
    $stream = $entry.Open()
    $bytes = [System.IO.File]::ReadAllBytes($file)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()
}
Add-ZipEntry $apk "classes.dex" "$out\dex\classes.dex"
Add-ZipEntry $apk "lib/arm64-v8a/libxray.so" "$proj\jniLibs\arm64-v8a\libxray.so"
Add-ZipEntry $apk "lib/x86_64/libxray.so" "$proj\jniLibs\x86_64\libxray.so"
Add-ZipEntry $apk "lib/arm64-v8a/libtun2socks.so" "$proj\jniLibs\arm64-v8a\libtun2socks.so"
Add-ZipEntry $apk "lib/x86_64/libtun2socks.so" "$proj\jniLibs\x86_64\libtun2socks.so"
$apk.Dispose()

# 5. Подпись (debug-ключ, для личного использования)
Write-Host "== keytool =="
$keystore = "$out\monkey.keystore"
if (-not (Test-Path $keystore)) {
    keytool -genkeypair -v -keystore $keystore -alias monkey -storepass monkey123 `
        -keypass monkey123 -keyalg RSA -keysize 2048 -validity 10000 `
        -dname "CN=Monkey VPN, OU=Personal, O=Monkey, L=Internet, S=Web, C=RU"
    if ($LASTEXITCODE -ne 0) { throw "keytool failed" }
}

Write-Host "== apksigner =="
& "$bt\apksigner.bat" sign --ks $keystore --ks-pass pass:monkey123 --key-pass pass:monkey123 `
    --out "$proj\MonkeyVPN.apk" "$out\MonkeyVPN.apk"
if ($LASTEXITCODE -ne 0) { throw "apksigner failed" }

& "$bt\apksigner.bat" verify --print-certs "$proj\MonkeyVPN.apk"
Write-Host ""
$size = [math]::Round((Get-Item "$proj\MonkeyVPN.apk").Length/1MB,1)
Write-Host "GOTOVO: $proj\MonkeyVPN.apk ($size MB)"
