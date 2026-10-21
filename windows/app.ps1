# ============================================================
# Monkey VPN - приложение для подключения к VPN-сервису
#  Вставь ссылку на подписку - подключайся одним кликом.
# ============================================================

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$AppRoot      = Split-Path -Parent $MyInvocation.MyCommand.Path
$XrayExe      = Join-Path $AppRoot 'Core\xray.exe'
$SettingsPath = Join-Path $AppRoot 'settings.json'
$ConfigPath   = Join-Path $AppRoot 'config.json'
$LogFile      = Join-Path $AppRoot 'xray.log'

$SocksPort = 10808
$HttpPort  = 10809

$script:XrayProc = $null

# ---------------------- Settings ----------------------
function Get-Settings {
    if (Test-Path $SettingsPath) {
        try { return (Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
    }
    return [PSCustomObject]@{ SubscriptionUrl = ''; ServerIndex = 0; AutoProxy = $true }
}
function Save-Settings ($s) {
    $s | ConvertTo-Json | Set-Content -Path $SettingsPath -Encoding UTF8
}

# ---------------------- Subscription ----------------------
function Expand-Base64 ([string]$s, [bool]$UrlSafe = $false) {
    $t = ($s -replace '\s', '').Replace('-', '+').Replace('_', '/')
    $pad = (4 - ($t.Length % 4)) % 4
    $t = $t + ('=' * $pad)
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($t))
}

function Get-SubscriptionContent ([string]$Url) {
    $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30 -UserAgent 'v2rayNG/1.9'
    $c = [string]$resp.Content
    if ($c -match '://') { return $c }
    # Похоже на base64 - пробуем раскодировать
    try {
        $decoded = Expand-Base64 $c
        if ($decoded -match '://') { return $decoded }
    } catch { }
    throw 'Не удалось раскодировать подписку (не ссылка и не base64).'
}

# ---------------------- Link parsing ----------------------
function New-ServerObject {
    param([string]$Name, [string]$Scheme, [hashtable]$Outbound)
    [PSCustomObject]@{ Name = $Name; Scheme = $Scheme; Outbound = $Outbound }
}

function Build-StreamSettings {
    param([string]$Network, [string]$Security, [hashtable]$Query, [string]$Sni, [string]$Host_, [string]$Path, [string]$ServiceName)

    $st = @{ network = $Network; security = if ($Security) { $Security } else { 'none' } }

    switch ($Network) {
        'ws' {
            $ws = @{ path = if ($Path) { $Path } else { '/' } }
            if ($Host_) { $ws.headers = @{ Host = $Host_ } }
            $st.wsSettings = $ws
        }
        'http' {
            $h = @{ path = '/' }
            if ($Path) { $h.path = $Path }
            if ($Host_) { $h.host = @($Host_) }
            $st.httpSettings = $h
        }
        'h2' {
            $h = @{ path = '/' }
            if ($Path) { $h.path = $Path }
            if ($Host_) { $h.host = @($Host_) }
            $st.httpSettings = $h
        }
        'grpc' {
            $g = @{ serviceName = if ($ServiceName) { $ServiceName } else { '' } }
            if ($Query.ContainsKey('mode')) { $g.multiMode = ($Query['mode'] -eq 'multi') }
            $st.grpcSettings = $g
        }
        'kcp' {
            $st.kcpSettings = @{ mtu = 1350; tti = 50; uplinkCapacity = 12; downlinkCapacity = 100; congestion = $false; header = @{ type = if ($Query.ContainsKey('type')) { $Query['type'] } else { 'none' } } }
        }
        default { } # tcp / raw - ничего дополнительно
    }

    if ($Security -eq 'tls') {
        $tls = @{ serverName = if ($Sni) { $Sni } else { $Host_ } }
        if ($Query.ContainsKey('fp')) { $tls.fingerprint = $Query['fp'] }
        $insecure = $Query.ContainsKey('allowInsecure') -and $Query['allowInsecure'] -match '^1|true$'
        if ($insecure) { $tls.allowInsecure = $true }
        $st.tlsSettings = $tls
    }
    elseif ($Security -eq 'reality') {
        $r = @{
            serverName = if ($Query.ContainsKey('sni')) { $Query['sni'] } elseif ($Sni) { $Sni } else { $Host_ }
            publicKey  = if ($Query.ContainsKey('pbk')) { $Query['pbk'] } else { '' }
            shortId    = if ($Query.ContainsKey('sid')) { $Query['sid'] } else { '' }
        }
        if ($Query.ContainsKey('fp')) { $r.fingerprint = $Query['fp'] }
        if ($Query.ContainsKey('spx')) { $r.spiderX = $Query['spx'] }
        $st.realitySettings = $r
    }
    return $st
}

function Parse-Query ([string]$QueryString) {
    $q = @{}
    if (-not $QueryString) { return $q }
    $qs = $QueryString.TrimStart('?')
    foreach ($pair in ($qs -split '&')) {
        if (-not $pair) { continue }
        $idx = $pair.IndexOf('=')
        if ($idx -lt 0) { $key = $pair; $val = '' } else { $key = $pair.Substring(0, $idx); $val = $pair.Substring($idx + 1) }
        $q[[uri]::UnescapeDataString($key).ToLower()] = [uri]::UnescapeDataString($val)
    }
    return $q
}

function Convert-Link ([string]$Link) {
    if ($Link -match '^vmess://[^/]') {
        try {
            $json = Expand-Base64 $Link.Substring(8) | ConvertFrom-Json
            $out = @{
                tag      = 'proxy'
                protocol = 'vmess'
                settings = @{ vnext = @(
                        @{ address = "$($json.add)"
                           port    = [int]$json.port
                           users   = @(@{ id = "$($json.id)"; alterId = if ($json.aid) { [int]$json.aid } else { 0 }; security = if ($json.scy) { "$($json.scy)" } else { 'auto' } })
                        })
                    }
            }
            $net = if ($json.net) { "$($json.net)" } else { 'tcp' }
            $secure = if ($json.tls -eq 'tls') { 'tls' } else { '' }
            $out.streamSettings = Build-StreamSettings -Network $net -Security $secure -Query @{} -Sni "$($json.sni)" -Host_ "$($json.host)" -Path "$($json.path)"
            return New-ServerObject "$($json.ps)" 'vmess' $out
        } catch { Write-Verbose "vmess parse error: $_"; return $null }
    }

    if ($Link -match '^vless://') {
        try {
            $uri  = [System.Uri]($Link + $null)
            $frag = [uri]::UnescapeDataString($uri.Fragment.TrimStart('#'))
            $q    = Parse-Query $uri.Query
            $uid  = [uri]::UnescapeDataString($uri.UserInfo)
            $flow = if ($q.ContainsKey('flow')) { $q['flow'] } else { '' }
            $out = @{
                tag      = 'proxy'
                protocol = 'vless'
                settings = @{ vnext = @(
                        @{ address = $uri.Host
                           port    = if ($uri.IsDefaultPort) { 443 } else { $uri.Port }
                           users   = @(@{ id = $uid; flow = $flow; encryption = 'none' })
                        })
                    }
            }
            $net = if ($q.ContainsKey('type')) { $q['type'] } else { 'tcp' }
            if ($net -eq 'raw') { $net = 'tcp' }
            $sec = if ($q.ContainsKey('security')) { $q['security'] } else { '' }
            if ($sec -eq 'none') { $sec = '' }
            $sni       = if ($q.ContainsKey('sni')) { $q['sni'] } else { '' }
            $hostv     = if ($q.ContainsKey('host')) { $q['host'] } else { '' }
            $path      = if ($q.ContainsKey('path')) { $q['path'] } else { '' }
            $svc       = if ($q.ContainsKey('serviceName')) { $q['serviceName'] } else { '' }
            $out.streamSettings = Build-StreamSettings -Network $net -Security $sec -Query $q -Sni $sni -Host_ $hostv -Path $path -ServiceName $svc
            $name = if ($frag) { $frag } else { "vless-$($uri.Host)" }
            return New-ServerObject $name 'vless' $out
        } catch { Write-Verbose "vless parse error: $_"; return $null }
    }

    if ($Link -match '^trojan://') {
        try {
            $uri  = [System.Uri]$Link
            $frag = [uri]::UnescapeDataString($uri.Fragment.TrimStart('#'))
            $q    = Parse-Query $uri.Query
            $out = @{
                tag      = 'proxy'
                protocol = 'trojan'
                settings = @{ servers = @(
                        @{ address = $uri.Host
                           port    = if ($uri.IsDefaultPort) { 443 } else { $uri.Port }
                           password = [uri]::UnescapeDataString($uri.UserInfo)
                        })
                    }
            }
            $net = if ($q.ContainsKey('type')) { $q['type'] } else { 'tcp' }
            $sni = if ($q.ContainsKey('sni')) { $q['sni'] } else { '' }
            $hostv = if ($q.ContainsKey('host')) { $q['host'] } else { '' }
            $path  = if ($q.ContainsKey('path')) { $q['path'] } else { '' }
            $out.streamSettings = Build-StreamSettings -Network $net -Security 'tls' -Query $q -Sni $sni -Host_ $hostv -Path $path
            $name = if ($frag) { $frag } else { "trojan-$($uri.Host)" }
            return New-ServerObject $name 'trojan' $out
        } catch { Write-Verbose "trojan parse error: $_"; return $null }
    }

    if ($Link -match '^ss://') {
        try {
            $body = $Link.Substring(5)
            $tag = $null
            $hidx = $body.IndexOf('#')
            if ($hidx -ge 0) { $tag = [uri]::UnescapeDataString($body.Substring($hidx + 1)); $body = $body.Substring(0, $hidx) }
            $method = $null; $password = $null; $address = $null; $port = $null

            $aidx = $body.IndexOf('@')
            if ($aidx -ge 0) {
                $userinfo = [uri]::UnescapeDataString($body.Substring(0, $aidx))
                $hostpart = $body.Substring($aidx + 1)
                try {
                    $plain = Expand-Base64 $userinfo $true
                    if ($plain -match ':') { $sp = $plain.IndexOf(':'); $method = $plain.Substring(0, $sp); $password = $plain.Substring($sp + 1) }
                } catch { }
                if (-not $method) {
                    $sp = $userinfo.IndexOf(':')
                    $method = $userinfo.Substring(0, $sp)
                    $password = $userinfo.Substring($sp + 1)
                }
                # host:port(/?(обфускация))
                if ($hostpart -match '([\w\-\.\[\]:\u4e00-\u9fff]+):(\d+)') {
                    $address = $Matches[1]; $port = [int]$Matches[2]
                }
            } else {
                $plain = Expand-Base64 ([uri]::UnescapeDataString($body))
                if ($plain -match '^(?<m>[^@:]+):(?<pass>[^@]+)@(?<h>[^:]+):(?<p>\d+)') {
                    $method = $Matches.m
                    $password = $Matches.pass
                    $address = $Matches.h; $port = [int]$Matches.p
                }
            }
            if (-not $method -or -not $password -or -not $address) { return $null }

            $out = @{
                tag      = 'proxy'
                protocol = 'shadowsocks'
                settings = @{ servers = @(@{ address = $address; port = $port; method = $method; password = $password }) }
            }
            $name = if ($tag) { $tag } else { "ss-$address" }
            return New-ServerObject $name 'ss' $out
        } catch { Write-Verbose "ss parse error: $_"; return $null }
    }

    if ($Link -match '^socks://|^ssr://') { Write-Verbose "unsupported: $Link"; return $null }
    return $null
}

function Parse-Subscription ([string]$Content) {
    $servers = New-Object System.Collections.Generic.List[object]
    foreach ($raw in ($Content -split "`n")) {
        $link = $raw.Trim()
        if (-not $link -or -not $link.Contains('://')) { continue }
        $s = Convert-Link $link
        if ($s) { $servers.Add($s) }
    }
    return $servers
}

# ---------------------- Config ----------------------
function Build-XrayConfig ($Server) {
    $outbounds = @(
        $Server.Outbound,
        @{ tag = 'direct'; protocol = 'freedom'; settings = @{ } },
        @{ tag = 'block'; protocol = 'blackhole'; settings = @{ } }
    )
    $cfg = @{
        log       = @{ loglevel = 'warning'; access = 'none'; error = 'none' }
        inbounds  = @(
            @{ tag = 'socks-in'; listen = '127.0.0.1'; port = $SocksPort; protocol = 'socks'
               sniffing = @{ enabled = $true; destOverride = @('http', 'tls'); routeOnly = $false }
               settings = @{ auth = 'noauth'; udp = $true } },
            @{ tag = 'http-in'; listen = '127.0.0.1'; port = $HttpPort; protocol = 'http'
               settings = @{ auth = 'noauth'; udp = $true } }
        )
        outbounds = $outbounds
        routing   = @{ domainStrategy = 'AsIs'; rules = @(
                @{ type = 'field'; domain = @('geosite:private'); outboundTag = 'direct' },
                @{ type = 'field'; ip = @('geoip:private'); outboundTag = 'direct' }
            )
        }
    }
    return $cfg
}

function Test-PrivateIp ([string]$ip) {
    # проверяет приватный адрес, чтобы не проксировать локальные сети
    if ($ip -match '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.|localhost)') { return $true }
    if ($ip -eq '::1') { return $true }
    return $false
}

# ---------------------- Connect / Disconnect ----------------------
function Start-Connection ($Server) {
    Stop-Connection | Out-Null
    $cfg = Build-XrayConfig $Server
    # JSON без BOM (иначе Xray не сможет прочитать конфиг)
    [IO.File]::WriteAllText($ConfigPath, ($cfg | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding $false))

    $StdPath = Join-Path $AppRoot 'xray.log'
    $ErrPath = Join-Path $AppRoot 'xray-err.log'
    Remove-Item $StdPath, $ErrPath -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $XrayExe -ArgumentList @('run', '-c', "`"$ConfigPath`"") `
        -WorkingDirectory $AppRoot -WindowStyle Hidden `
        -RedirectStandardOutput $StdPath -RedirectStandardError $ErrPath -PassThru
    Start-Sleep -Milliseconds 1500
    $script:XrayProc = $p
    if ($p.HasExited) {
        $tail = ''
        foreach ($lf in @((Join-Path $AppRoot 'xray.log'), (Join-Path $AppRoot 'xray-err.log'))) {
            if (Test-Path $lf) { $tail += ((Get-Content $lf -Tail 5 -Encoding UTF8) -join "`n") + "`n" }
        }
        throw "Xray завершился с ошибкой. Лог:`n$tail"
    }
    return $p
}

function Stop-Connection {
    if ($script:XrayProc -and -not $script:XrayProc.HasExited) {
        try { $script:XrayProc.Kill() } catch { }
        $script:XrayProc.WaitForExit(3000) | Out-Null
    }
    $script:XrayProc = $null
    Get-Process -Name 'xray' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $XrayExe } | Stop-Process -ErrorAction SilentlyContinue
}

function Set-SystemProxy ([bool]$On) {
    $reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if ($On) {
        Set-ItemProperty $reg -Name ProxyServer -Value "127.0.0.1:$HttpPort"
        Set-ItemProperty $reg -Name ProxyEnable -Value 1
    } else {
        Set-ItemProperty $reg -Name ProxyEnable -Value 0
    }
    try {
        Add-Type -TypeDefinition @'
namespace WinInet {
using System;
using System.Runtime.InteropServices;
public static class Utils {
    [DllImport("wininet.dll", SetLastError = true)]
    public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
}
}
'@ -ErrorAction SilentlyContinue
        $INTERNET_OPTION_SETTINGS_CHANGED = 39
        $INTERNET_OPTION_REFRESH          = 37
        [WinInet.Utils]::InternetSetOption([IntPtr]::Zero, $INTERNET_OPTION_SETTINGS_CHANGED, [IntPtr]::Zero, 0) | Out-Null
        [WinInet.Utils]::InternetSetOption([IntPtr]::Zero, $INTERNET_OPTION_REFRESH, [IntPtr]::Zero, 0) | Out-Null
    } catch { }
}


# ---------------------- Self-test mode ----------------------
if ($env:VPNAPP_TEST -eq '1') {
    $samp = @"
vmess://eyJ2IjoiMiIsInBzIjoi0KLQtdGB0YLQvtCy0YvQuSDRgdC10YDQstC10Y AiLCJhZGQiOiJleGFtcGxlLmNvbSIsInBvcnQiOiI0NDMiLCJpZCI6IjU5MWI0YjM2LTJmNGMtNDFkYS1hNzAyLWQ3MDIzNGQ0M2I1NyIsImFpZCI6IjAiLCJzY3kiOiJhdXRvIiwibmV0Ijoid3MiLCJob3N0IjoiY2QuZXhhbXBsZS5jb20iLCJwYXRoIjoiL3RlIiwidGxzIjoidGxzIn0K
vless://591b4b36-2f4c-41da-a702-d70234d43b57@example.com:443?security=tls&sni=cdn.example.com&fp=chrome&type=ws&host=cdn.example.com&path=%2Ftea#VLESS%20Test
trojan://SuperSecret%21@trojan.example.com:443?sni=trojan.example.com&type=tcp#Trojan%20Server
ss://YWVzLTI1Ni1nY206cGFzcw%3D%3D@example1.com:8388#SS%20Old
ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ%3D@example2.com:1234#SSPlain
"@
    $list = Parse-Subscription $samp
    Write-Host "Parsed: $($list.Count)"
    $list | ForEach-Object { Write-Host " - [$($_.Scheme)] $($_.Name)"; $_.Outbound | ConvertTo-Json -Depth 6 | Write-Host }
    return
}

if ($env:VPNAPP_TEST -eq '2') {
    # Проверка: генерируем конфиг и убеждаемся, что Xray его принимает
    $fake = Convert-Link 'vless://591b4b36-2f4c-41da-a702-d70234d43b57@example.com:443?security=tls&sni=cdn.example.com&type=tcp#FakeTest'
    $p = Start-Connection $fake
    Start-Sleep -Seconds 3
    if ($p.HasExited) {
        Write-Host "FAIL: xray exited. Logs:"; Get-Content (Join-Path $AppRoot 'xray.log'), (Join-Path $AppRoot 'xray-err.log') -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
        exit 1
    } else {
        Write-Host "OK: xray is running (PID $($p.Id)) with ports $SocksPort/$HttpPort"
        # Проверим, что порт слушается
        $net = netstat -an | Select-String "127.0.0.1:$SocksPort.*LISTENING"
        if ($net) { Write-Host "OK: SOCKS port $SocksPort listening" } else { Write-Host "WARN: SOCKS port not listening"; exit 1 }
        Stop-Connection
        Write-Host "OK: stopped"
        exit 0
    }
}

# ---------------------- GUI ----------------------
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Monkey VPN" Height="560" Width="460"
        WindowStartupLocation="CenterScreen" ResizeMode="CanMinimize"
        Background="#1E1E2E">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="Background" Value="#5B5BD6"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="Cursor" Value="Hand"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#2B2B40"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="#454560"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="4"/>
        </Style>
        <Style TargetType="ListBox">
            <Setter Property="Background" Value="#2B2B40"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="#454560"/>
            <Setter Property="BorderThickness" Value="1"/>
        </Style>
        <Style TargetType="ListBoxItem">
            <Setter Property="Padding" Value="8,6"/>
        </Style>
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="#CCCCCC"/>
        </Style>
    </Window.Resources>
    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Orientation="Vertical" Margin="0,0,0,10">
            <TextBlock Text="Ссылка на подписку:" FontSize="14" Margin="0,0,0,6"/>
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBox Grid.Column="0" x:Name="BoxUrl" />
                <Button Grid.Column="1" x:Name="BtnLoad" Content="Загрузить" Margin="8,0,0,0" MinWidth="110"/>
            </Grid>
        </StackPanel>

        <StackPanel Grid.Row="1" Orientation="Vertical" Margin="0,0,0,8">
            <TextBlock Text="Серверы:" FontSize="14" Margin="0,0,0,6"/>
            <ListBox x:Name="ListServers" Height="150"/>
        </StackPanel>

        <StackPanel Grid.Row="2" Orientation="Vertical"/>

        <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,12,0,0">
            <Button x:Name="BtnConnect"   Content="Подключить"     MinWidth="130" Margin="4"/>
            <Button x:Name="BtnDisconnect" Content="Отключить"     MinWidth="130" Margin="4"/>
        </StackPanel>

        <StackPanel Grid.Row="4" Orientation="Vertical" Margin="0,12,0,0">
            <TextBlock x:Name="TxtStatus" Text="Не подключено" FontSize="14" Foreground="#FFB4B4" TextWrapping="Wrap"/>
            <TextBlock x:Name="TxtInfo"   Text="Локальный прокси: SOCKS 127.0.0.1:10808 · HTTP 127.0.0.1:10809" FontSize="11" Foreground="#8888A0" Margin="0,6,0,0" TextWrapping="Wrap"/>
        </StackPanel>
    </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$window.Title = 'Monkey VPN'

$BoxUrl      = $window.FindName('BoxUrl')
$BtnLoad     = $window.FindName('BtnLoad')
$ListServers = $window.FindName('ListServers')
$BtnConnect  = $window.FindName('BtnConnect')
$BtnDisconnect = $window.FindName('BtnDisconnect')
$TxtStatus   = $window.FindName('TxtStatus')
$TxtInfo     = $window.FindName('TxtInfo')

function Show-Status ([string]$Text, [string]$Color = '#CCCCCC') {
    $TxtStatus.Text = $Text
    $TxtStatus.Foreground = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($Color))
}

function Update-ServerList ($servers) {
    $ListServers.ItemsSource = $null
    $items = New-Object System.Collections.ObjectModel.ObservableCollection[string]
    foreach ($s in $servers) { $items.Add("[$($s.Scheme)] $($s.Name)") }
    $ListServers.ItemsSource = $items
}

# --- Load settings & initial subscription fetch
$settings = Get-Settings
$BoxUrl.Text = $settings.SubscriptionUrl
$script:Servers = New-Object System.Collections.Generic.List[object]

$BtnLoad.Add_Click({
    $url = $BoxUrl.Text.Trim()
    if (-not $url) { Show-Status 'Вставь сначала ссылку на подписку.' '#FFB4B4'; return }
    $settings.SubscriptionUrl = $url
    Save-Settings $settings

    $BtnLoad.IsEnabled = $false
    Show-Status 'Загружаю подписку...' '#FFD48A'
    $window.Dispatcher.Invoke([Action]{ }, [Windows.Threading.DispatcherPriority]::Background) | Out-Null
    try {
        $content = Get-SubscriptionContent $url
        $script:Servers = Parse-Subscription $content
        if ($script:Servers.Count -eq 0) {
            Show-Status 'Подписка получена, но серверы не распознаны (vmess/vless/ss/trojan).' '#FFB4B4'
        } else {
            Update-ServerList $script:Servers
            $ListServers.SelectedIndex = [Math]::Min($settings.ServerIndex, $script:Servers.Count - 1)
            Show-Status "Загружено серверов: $($script:Servers.Count). Выбери сервер и нажми Подключить." '#9BE79B'
        }
    } catch {
        Show-Status "Ошибка загрузки подписки: $($_.Exception.Message)" '#FFB4B4'
    } finally {
        $BtnLoad.IsEnabled = $true
    }
})

function Connect-Selected {
    if ($script:Servers.Count -eq 0) { Show-Status 'Сначала загрузи подписку.' '#FFB4B4'; return }
    if (-not $ListServers.SelectedItem) {
        $ListServers.SelectedIndex = 0
        if (-not $ListServers.SelectedItem) { return }
        # Fallback: если ItemsSource другой тип - возьми 0
        $idx = 0
    } else {
        $idx = $ListServers.SelectedIndex
    }
    $server = $script:Servers[$idx]
    if (-not $server) { Show-Status 'Не удалось определить выбранный сервер.' '#FFB4B4'; return }

    $settings.ServerIndex = $idx
    Save-Settings $settings

    $BtnConnect.IsEnabled = $false
    Show-Status "Подключаюсь к [$($server.Scheme)] $($server.Name) ..." '#FFD48A'
    $window.Dispatcher.Invoke([Action]{ }, [Windows.Threading.DispatcherPriority]::Background) | Out-Null
    try {
        Start-Connection $server | Out-Null
        if ($settings.AutoProxy -ne $false) { Set-SystemProxy $true }
        Show-Status "Подключено! [$($server.Scheme)] $($server.Name). Прокси: 127.0.0.1:10809" '#9BE79B'
        # Проверим, кто мы теперь (не критично)
        $window.Dispatcher.Invoke([Action]{ }, [Windows.Threading.DispatcherPriority]::Background) | Out-Null
        try {
            $resp = Invoke-WebRequest -Uri 'http://ip-api.com/json/?fields=query,country,countryCode' -Proxy "http://127.0.0.1:$HttpPort" -UseBasicParsing -TimeoutSec 10
            $ip = ($resp.Content | ConvertFrom-Json)
            $TxtInfo.Text = "Ваш IP: $($ip.query) · $($ip.country) ($($ip.countryCode))   |   Прокси: SOCKS 127.0.0.1:10808 · HTTP 127.0.0.1:10809"
        } catch { }
    } catch {
        Show-Status "Ошибка подключения: $($_.Exception.Message)" '#FFB4B4'
    } finally {
        $BtnConnect.IsEnabled = $true
    }
}

$BtnConnect.Add_Click({ Connect-Selected })

$BtnDisconnect.Add_Click({
    Show-Status 'Отключаюсь...' '#FFD48A'
    try {
        Stop-Connection
        Set-SystemProxy $false
        Show-Status 'Не подключено.' '#CCCCCC'
        $TxtInfo.Text = "Локальный прокси: SOCKS 127.0.0.1:10808 · HTTP 127.0.0.1:10809"
    } catch {
        Show-Status "Ошибка отключения: $($_.Exception.Message)" '#FFB4B4'
    }
})

$ListServers.Add_MouseDoubleClick({ Connect-Selected })

$window.Add_Closing({
    Stop-Connection
    Set-SystemProxy $false
})

if (Test-Path $ConfigPath) { Show-Status "Файл настроек: $ConfigPath`n(смотри находки в xray.log при ошибках)" '#8888A0' }
Show-Status 'Не подключено. Вставь ссылку на подписку и нажми Загрузить.' '#CCCCCC'
$window.ShowDialog() | Out-Null
