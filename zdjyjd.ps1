#Requires -RunAsAdministrator

param()

$TitleName = "中德有线ZDJYJD分流"
$Host.UI.RawUI.WindowTitle = $TitleName
$Host.UI.RawUI.WindowSize = @{Width=80; Height=50}

$script:EthName = "以太网"
$EthMask = "255.255.248.0"
$EthGateway = "172.23.7.254"
$EthDNS1 = "192.168.11.150"
$EthDNS2 = "192.168.11.158"
$WiFiGateway = "172.16.191.254"
$EthIPPrefix = "172.23"

$WiFiName = "ZDJYJD"
$WiFiPassword = "zdjyjd@123"

function Get-NICInfo {
    Write-Host "所有已连接的网络连接信息" -ForegroundColor Cyan
    Write-Host "未插网线不会显示在下方:" -ForegroundColor Gray
    Write-Host ""

    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
    $i = 0

    foreach ($adapter in $adapters) {
        $i++
        $ipConfig = Get-NetIPConfiguration -InterfaceIndex $adapter.InterfaceIndex -ErrorAction SilentlyContinue
        $dns = Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue

        Write-Host "No.$i           : $($adapter.Name)"
        Write-Host "  描述         : $($adapter.InterfaceDescription)"
        Write-Host "  MAC 物理地址 : $($adapter.MacAddress)"
        Write-Host "  IPv4 地址    : $($ipConfig.IPv4Address.IPAddress)"
        Write-Host "  子网掩码     : $($ipConfig.IPv4Address.PrefixLength)"
        Write-Host "  默认网关     : $($ipConfig.IPv4DefaultGateway.NextHop)"
        Write-Host "  DNS 服务器   : $($dns.ServerAddresses -join ', ')"
        Write-Host "  INDEX        : $($adapter.InterfaceIndex)"
        Write-Host "----------------"
    }

    Write-Host "已连接的网络连接数量: $i"
}

function Get-MatchingIP {
    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
    foreach ($adapter in $adapters) {
        $ipConfig = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        foreach ($ip in $ipConfig) {
            if ($ip.IPAddress -like "$EthIPPrefix.*") {
                return $ip.IPAddress
            }
        }
    }
    return $null
}

function Set-Metric-Silent {
    $ethAdapter = Get-NetAdapter | Where-Object { $_.Name -eq $script:EthName }
    $wifiAdapter = Get-NetAdapter | Where-Object { $_.Name -eq "WLAN" -or $_.InterfaceDescription -match "Wi-Fi" }

    if ($ethAdapter) {
        Set-NetIPInterface -InterfaceIndex $ethAdapter.InterfaceIndex -InterfaceMetric 10 -AddressFamily IPv4 -ErrorAction SilentlyContinue
    }
    if ($wifiAdapter) {
        Set-NetIPInterface -InterfaceIndex $wifiAdapter.InterfaceIndex -InterfaceMetric 20 -AddressFamily IPv4 -ErrorAction SilentlyContinue
    }
}

function Add-Routes-Silent {
    $ethAdapter = Get-NetAdapter | Where-Object { $_.Name -eq $script:EthName }
    $wifiAdapter = Get-NetAdapter | Where-Object { $_.Name -eq "WLAN" -or $_.InterfaceDescription -match "Wi-Fi" }

    if ($ethAdapter) {
        Remove-NetRoute -DestinationPrefix "192.168.0.0/16" -InterfaceIndex $ethAdapter.InterfaceIndex -Confirm:$false -ErrorAction SilentlyContinue
        Remove-NetRoute -DestinationPrefix "172.23.0.0/16" -InterfaceIndex $ethAdapter.InterfaceIndex -Confirm:$false -ErrorAction SilentlyContinue
    }

    $wifiIdx = if ($wifiAdapter) { $wifiAdapter.InterfaceIndex } else { (Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "Wi-Fi" } | Select-Object -First 1).InterfaceIndex }

    Remove-NetRoute -DestinationPrefix "0.0.0.0/0" -InterfaceIndex $wifiIdx -Confirm:$false -ErrorAction SilentlyContinue

    if ($ethAdapter) {
        New-NetRoute -DestinationPrefix "172.23.0.0/16" -InterfaceIndex $ethAdapter.InterfaceIndex -NextHop $EthGateway -PolicyStore ActiveStore -ErrorAction SilentlyContinue
        New-NetRoute -DestinationPrefix "192.168.0.0/16" -InterfaceIndex $ethAdapter.InterfaceIndex -NextHop $EthGateway -PolicyStore ActiveStore -ErrorAction SilentlyContinue
    }

    if ($wifiIdx) {
        New-NetRoute -DestinationPrefix "0.0.0.0/0" -InterfaceIndex $wifiIdx -NextHop $WiFiGateway -PolicyStore ActiveStore -ErrorAction SilentlyContinue
    }
}

function Test-DNS {
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host "           验证DNS解析（仅IPv4）" -ForegroundColor Cyan
    Write-Host "=============================================="

    Write-Host "测试内网域名jac.net解析..." -ForegroundColor Yellow
    nslookup -type=A jac.net 2>&1 | Select-Object -First 10

    Write-Host ""
    Write-Host "测试外网域名baidu.com解析..." -ForegroundColor Yellow
    nslookup -type=A baidu.com 2>&1 | Select-Object -First 10

    Write-Host ""
    Write-Host "DNS解析测试完成" -ForegroundColor Green
}

function Verify-Config {
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host "           验证网络连通性（仅IPv4）" -ForegroundColor Cyan
    Write-Host "=============================================="

    Write-Host "关键路由信息：" -ForegroundColor Yellow
    Get-NetRoute -AddressFamily IPv4 | Where-Object { $_.DestinationPrefix -like "172.23*" -or $_.DestinationPrefix -like "192.168*" -or $_.DestinationPrefix -eq "0.0.0.0/0" } |
        Format-Table DestinationPrefix, NextHop, InterfaceAlias, RouteMetric -AutoSize

    Write-Host ""
    Write-Host "测试内网172.23网段连通性（ping $EthGateway）..." -ForegroundColor Yellow
    Test-Connection -ComputerName $EthGateway -Count 4 -ErrorAction SilentlyContinue |
        Select-Object Address, Status, ResponseTime | Format-Table -AutoSize

    Write-Host "测试内网192.168网段连通性（ping 192.168.11.150）..." -ForegroundColor Yellow
    Test-Connection -ComputerName "192.168.11.150" -Count 4 -ErrorAction SilentlyContinue |
        Select-Object Address, Status, ResponseTime | Format-Table -AutoSize

    Write-Host "测试外网连通性（ping 8.8.8.8）..." -ForegroundColor Yellow
    Test-Connection -ComputerName "8.8.8.8" -Count 4 -ErrorAction SilentlyContinue |
        Select-Object Address, Status, ResponseTime | Format-Table -AutoSize

    Write-Host ""
    Write-Host "连通性测试完成" -ForegroundColor Green
}

function Connect-WiFiProfile {
    param([string]$Name, [string]$Password)

    $xmlPath = "$env:TEMP\$Name.xml"

    $xmlContent = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
    <name>$Name</name>
    <SSIDConfig>
        <SSID>
            <name>$Name</name>
        </SSID>
    </SSIDConfig>
    <connectionType>ESS</connectionType>
    <connectionMode>auto</connectionMode>
    <MSM>
        <security>
            <authEncryption>
                <authentication>WPA2PSK</authentication>
                <encryption>AES</encryption>
                <useOneX>false</useOneX>
            </authEncryption>
            <sharedKey>
                <keyType>passPhrase</keyType>
                <protected>false</protected>
                <keyMaterial>$Password</keyMaterial>
            </sharedKey>
        </security>
    </MSM>
</WLANProfile>
"@

    $xmlContent | Out-File -FilePath $xmlPath -Encoding UTF8
    netsh wlan add profile filename="$xmlPath"
    $result = netsh wlan connect name="$Name" ssid="$Name"
    Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue

    return $LASTEXITCODE -eq 0
}

function One-Key-Setup {
    Clear-Host
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host "           正在执行一键设置..." -ForegroundColor Cyan
    Write-Host "=============================================="

    Write-Host "连接WiFi $WiFiName..." -ForegroundColor Yellow
    $wifiConnected = Connect-WiFiProfile -Name $WiFiName -Password $WiFiPassword

    if ($wifiConnected) {
        Write-Host "WiFi $WiFiName 连接成功！" -ForegroundColor Green
        Start-Sleep -Seconds 10
    } else {
        Write-Host "WiFi $WiFiName 连接失败，请检查名称、密码或网络环境。" -ForegroundColor Red
    }

    Write-Host "1. 配置网卡优先级（有线优先）..." -ForegroundColor Yellow
    Set-Metric-Silent
    Write-Host "1. 完成" -ForegroundColor Green

    Write-Host ""
    Write-Host "2. 添加静态路由（内网走有线，外网走无线）..." -ForegroundColor Yellow
    Add-Routes-Silent
    Write-Host "2. 完成" -ForegroundColor Green

    Write-Host ""
    Write-Host "3. 验证DNS解析（仅IPv4）..." -ForegroundColor Yellow
    Test-DNS
    Write-Host "3. 完成" -ForegroundColor Green

    Write-Host ""
    Write-Host "4. 验证配置连通性..." -ForegroundColor Yellow
    Verify-Config
    Write-Host "4. 完成" -ForegroundColor Green

    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Green
    Write-Host "一键设置全部完成！" -ForegroundColor Green
    Write-Host "=============================================="

    Start-Sleep -Seconds 3
}

function Restore-Default {
    Clear-Host
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host "           还原初始IPv4网络设置" -ForegroundColor Cyan
    Write-Host "=============================================="

    $ethAdapter = Get-NetAdapter | Where-Object { $_.Name -eq $script:EthName }
    $wifiAdapter = Get-NetAdapter | Where-Object { $_.Name -eq "WLAN" -or $_.InterfaceDescription -match "Wi-Fi" }
    $ethIP = Get-MatchingIP

    Write-Host "1. 删除静态路由..." -ForegroundColor Yellow
    Get-NetRoute | Where-Object {
        $_.DestinationPrefix -in @("192.168.0.0/16", "172.23.0.0/16", "0.0.0.0/0")
    } | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "2. 恢复网卡默认跃点..." -ForegroundColor Yellow
    if ($ethAdapter) {
        Remove-NetIPAddress -InterfaceIndex $ethAdapter.InterfaceIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        Remove-NetRoute -InterfaceIndex $ethAdapter.InterfaceIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
    if ($wifiAdapter) {
        Remove-NetIPAddress -InterfaceIndex $wifiAdapter.InterfaceIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        Remove-NetRoute -InterfaceIndex $wifiAdapter.InterfaceIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }

    Write-Host ""
    Write-Host "3. 重新配置以太网（确保网关存在）..." -ForegroundColor Yellow
    if ($ethAdapter -and $ethIP) {
        $prefixLength = (Get-NetIPAddress -InterfaceIndex $ethAdapter.InterfaceIndex -AddressFamily IPv4).PrefixLength
        if (-not $prefixLength) { $prefixLength = 23 }

        $currentIP = Get-NetIPAddress -InterfaceIndex $ethAdapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($currentIP) {
            Remove-NetIPAddress -InterfaceIndex $ethAdapter.InterfaceIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
            Remove-NetRoute -InterfaceIndex $ethAdapter.InterfaceIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        }

        New-NetIPAddress -InterfaceIndex $ethAdapter.InterfaceIndex -IPAddress $ethIP -PrefixLength $prefixLength -DefaultGateway $EthGateway -ErrorAction SilentlyContinue
        Set-DnsClientServerAddress -InterfaceIndex $ethAdapter.InterfaceIndex -ServerAddresses ($EthDNS1, $EthDNS2) -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host "4. 刷新无线配置和DNS缓存..." -ForegroundColor Yellow
    if ($wifiAdapter) {
        Restart-NetAdapter -Name $wifiAdapter.Name -Confirm:$false -ErrorAction SilentlyContinue
    }
    Clear-DnsClientCache -ErrorAction SilentlyContinue

    Write-Host "5. 断开无线WIFI（全部）" -ForegroundColor Yellow
    netsh wlan disconnect | Out-Null

    Write-Host ""
    Write-Host "还原完成！以太网配置：" -ForegroundColor Green
    Write-Host "- IP：$ethIP  掩码：$EthMask"
    Write-Host "- 网关：$EthGateway"
    Write-Host "- DNS：$EthDNS1、$EthDNS2"
    Write-Host ""

    Get-NICInfo

    Start-Sleep -Seconds 10
}

function Show-Menu {
    Clear-Host
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host "          $TitleName" -ForegroundColor Cyan
    Write-Host "==============================================" -ForegroundColor Cyan

    Get-NICInfo
    Write-Host ""

    $ethIP = Get-MatchingIP
    Write-Host "查找的IP前缀：$EthIPPrefix"
    if ($ethIP) {
        Write-Host "找到匹配的IP：$ethIP" -ForegroundColor Green
    } else {
        Write-Host "未找到以$EthIPPrefix开头的IP地址" -ForegroundColor Red
    }
    Write-Host ""

    Write-Host "1. 一键设置（自动配置并验证内外网分流）同时连 LAN、WIFI"
    Write-Host "2. 还原初始设置（保留以太网网关和IP）只连 LAN"
    Write-Host "3. 退出"
    Write-Host "=============================================="
}

do {
    Show-Menu
    $choice = Read-Host "请输入选项 [1-3]"

    switch ($choice) {
        "1" { One-Key-Setup }
        "2" { Restore-Default }
        "3" { exit }
    }
} while ($true)
