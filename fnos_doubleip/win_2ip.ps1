# Windows 11 双IP网络配置脚本 (简化版)
# 管理员权限运行 PowerShell 后执行此脚本

# ==================== 配置变量区域 ====================
# 主网络配置（优先级高）
$PrimaryIP = "10.1.1.99"
$PrimarySubnet = "255.255.255.0"
$PrimaryGateway = "10.1.1.250"

# 辅助网络配置（用于访问其他终端）
$SecondaryIP = "192.168.70.99"
$SecondarySubnet = "255.255.255.0"
$SecondaryGateway = "192.168.70.1"

# DNS配置
$PrimaryDNS = "10.1.1.250"
$SecondaryDNS = "223.6.6.6"

# 全局变量
$SelectedInterface = $null
$SelectedInterfaceIndex = $null
# ==================== 配置变量区域结束 ====================

# 检查管理员权限
function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 列出并选择网络接口
function Select-NetworkInterface {
    Write-Host "=== 网络接口选择 ===" -ForegroundColor Green
    Write-Host ""
    
    # 获取所有网络适配器
    $adapters = Get-NetAdapter | Sort-Object Name
    
    if ($adapters.Count -eq 0) {
        Write-Host "未找到任何网络适配器！" -ForegroundColor Red
        return $false
    }
    
    Write-Host "可用的网络接口:" -ForegroundColor Yellow
    Write-Host "编号`t状态`t`t接口名称`t`t`t描述" -ForegroundColor Cyan
    Write-Host "----`t----`t`t--------`t`t`t----" -ForegroundColor Cyan
    
    for ($i = 0; $i -lt $adapters.Count; $i++) {
        $status = $adapters[$i].Status
        $statusColor = if ($status -eq "Up") { "Green" } else { "Red" }
        $name = $adapters[$i].Name.PadRight(20)
        $desc = $adapters[$i].InterfaceDescription
        
        Write-Host "$($i + 1)`t" -NoNewline
        Write-Host "$status`t`t" -ForegroundColor $statusColor -NoNewline
        Write-Host "$name`t" -NoNewline
        Write-Host "$desc"
    }
    
    Write-Host ""
    do {
        $selection = Read-Host "请选择要配置的网络接口编号 (1-$($adapters.Count))"
        try {
            $index = [int]$selection - 1
            if ($index -ge 0 -and $index -lt $adapters.Count) {
                $script:SelectedInterface = $adapters[$index].Name
                $script:SelectedInterfaceIndex = $adapters[$index].InterfaceIndex
                Write-Host "已选择接口: $($script:SelectedInterface) (索引: $($script:SelectedInterfaceIndex))" -ForegroundColor Green
                return $true
            } else {
                Write-Host "请输入有效的编号 (1-$($adapters.Count))" -ForegroundColor Red
            }
        }
        catch {
            Write-Host "请输入有效的数字" -ForegroundColor Red
        }
    } while ($true)
}

# 显示当前选择的接口信息
function Show-SelectedInterface {
    if ($null -eq $script:SelectedInterface) {
        Write-Host "未选择网络接口" -ForegroundColor Red
        return
    }
    
    Write-Host "当前选择的接口: $($script:SelectedInterface) (索引: $($script:SelectedInterfaceIndex))" -ForegroundColor Green
    
    # 显示当前IP配置
    try {
        $currentIPs = Get-NetIPAddress -InterfaceIndex $script:SelectedInterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($currentIPs) {
            Write-Host "当前IP地址:" -ForegroundColor Yellow
            foreach ($ip in $currentIPs) {
                Write-Host "  - $($ip.IPAddress)/$($ip.PrefixLength)" -ForegroundColor White
            }
        } else {
            Write-Host "当前无IP地址配置" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "无法获取当前IP配置" -ForegroundColor Yellow
    }
}

# 显示菜单
function Show-Menu {
    Clear-Host
    Write-Host "=== Windows 11 双IP网络配置工具 ===" -ForegroundColor Green
    Write-Host "目标配置:" -ForegroundColor Yellow
    Write-Host "主IP: $PrimaryIP/$PrimarySubnet (网关: $PrimaryGateway)"
    Write-Host "辅助IP: $SecondaryIP/$SecondarySubnet (网关: $SecondaryGateway)"
    Write-Host ""
    
    Show-SelectedInterface
    Write-Host ""
    
    Write-Host "请选择操作:" -ForegroundColor Cyan
    Write-Host "1. 选择网络接口"
    Write-Host "2. 配置双IP网络（主网络+辅助网络）"
    Write-Host "3. 删除主网络IP ($PrimaryIP)"
    Write-Host "4. 删除辅助网络IP ($SecondaryIP)"
    Write-Host "5. 查看当前网络配置"
    Write-Host "6. 重置网络为DHCP"
    Write-Host "0. 退出"
    Write-Host ""
}

# 配置双IP网络
function Set-DualIP {
    if ($null -eq $script:SelectedInterfaceIndex) {
        Write-Host "请先选择网络接口！" -ForegroundColor Red
        return
    }
    
    Write-Host "开始配置双IP网络..." -ForegroundColor Green
    Write-Host "接口: $($script:SelectedInterface) (索引: $($script:SelectedInterfaceIndex))"
    
    try {
        # 1. 清除现有IP配置
        Write-Host "1. 清除现有IP配置..."
        $existingIPs = Get-NetIPAddress -InterfaceIndex $script:SelectedInterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        foreach ($ip in $existingIPs) {
            Remove-NetIPAddress -InterfaceIndex $script:SelectedInterfaceIndex -IPAddress $ip.IPAddress -Confirm:$false -ErrorAction SilentlyContinue
        }
        
        # 清除现有路由
        $existingRoutes = Get-NetRoute -InterfaceIndex $script:SelectedInterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {$_.DestinationPrefix -ne "127.0.0.0/8"}
        foreach ($route in $existingRoutes) {
            Remove-NetRoute -InterfaceIndex $script:SelectedInterfaceIndex -DestinationPrefix $route.DestinationPrefix -Confirm:$false -ErrorAction SilentlyContinue
        }
        
        # 2. 配置主IP
        Write-Host "2. 配置主IP: $PrimaryIP"
        New-NetIPAddress -InterfaceIndex $script:SelectedInterfaceIndex -IPAddress $PrimaryIP -PrefixLength 24 -DefaultGateway $PrimaryGateway
        
        # 3. 配置辅助IP
        Write-Host "3. 配置辅助IP: $SecondaryIP"
        New-NetIPAddress -InterfaceIndex $script:SelectedInterfaceIndex -IPAddress $SecondaryIP -PrefixLength 24
        
        # 4. 添加辅助网关路由
        Write-Host "4. 配置辅助网关路由..."
        New-NetRoute -DestinationPrefix "192.168.70.0/24" -InterfaceIndex $script:SelectedInterfaceIndex -NextHop $SecondaryGateway -RouteMetric 10 -ErrorAction SilentlyContinue
        
        # 5. 配置DNS
        Write-Host "5. 配置DNS服务器..."
        Set-DnsClientServerAddress -InterfaceIndex $script:SelectedInterfaceIndex -ServerAddresses $PrimaryDNS, $SecondaryDNS
        
        Write-Host "双IP配置完成!" -ForegroundColor Green
        
    }
    catch {
        Write-Host "配置过程中出现错误: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# 删除主网络IP
function Remove-PrimaryIP {
    if ($null -eq $script:SelectedInterfaceIndex) {
        Write-Host "请先选择网络接口！" -ForegroundColor Red
        return
    }
    
    Write-Host "删除主网络IP: $PrimaryIP" -ForegroundColor Yellow
    
    try {
        Remove-NetIPAddress -InterfaceIndex $script:SelectedInterfaceIndex -IPAddress $PrimaryIP -Confirm:$false
        Write-Host "主网络IP删除成功!" -ForegroundColor Green
    }
    catch {
        Write-Host "删除主网络IP失败: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# 删除辅助网络IP
function Remove-SecondaryIP {
    if ($null -eq $script:SelectedInterfaceIndex) {
        Write-Host "请先选择网络接口！" -ForegroundColor Red
        return
    }
    
    Write-Host "删除辅助网络IP: $SecondaryIP" -ForegroundColor Yellow
    
    try {
        Remove-NetIPAddress -InterfaceIndex $script:SelectedInterfaceIndex -IPAddress $SecondaryIP -Confirm:$false
        Write-Host "辅助网络IP删除成功!" -ForegroundColor Green
    }
    catch {
        Write-Host "删除辅助网络IP失败: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# 查看当前网络配置
function Show-NetworkConfig {
    if ($null -eq $script:SelectedInterfaceIndex) {
        Write-Host "请先选择网络接口！" -ForegroundColor Red
        return
    }
    
    Write-Host "当前网络配置 (接口: $($script:SelectedInterface)):" -ForegroundColor Cyan
    
    Write-Host "`n--- IP地址配置 ---" -ForegroundColor Yellow
    try {
        $ips = Get-NetIPAddress -InterfaceIndex $script:SelectedInterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        foreach ($ip in $ips) {
            Write-Host "IP: $($ip.IPAddress)/$($ip.PrefixLength)" -ForegroundColor White
        }
    }
    catch {
        Write-Host "无法获取IP配置" -ForegroundColor Red
    }
    
    Write-Host "`n--- 路由表 ---" -ForegroundColor Yellow
    try {
        $routes = Get-NetRoute -InterfaceIndex $script:SelectedInterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        foreach ($route in $routes) {
            Write-Host "目标: $($route.DestinationPrefix) -> 网关: $($route.NextHop) (优先级: $($route.RouteMetric))" -ForegroundColor White
        }
    }
    catch {
        Write-Host "无法获取路由配置" -ForegroundColor Red
    }
    
    # 测试连通性
    Write-Host "`n--- 连通性测试 ---" -ForegroundColor Yellow
    Write-Host "测试主网关 ($PrimaryGateway):" -NoNewline
    $result1 = Test-NetConnection -ComputerName $PrimaryGateway -InformationLevel Quiet -WarningAction SilentlyContinue
    Write-Host " $(if($result1){'✓ 连通'}else{'✗ 失败'})" -ForegroundColor $(if($result1){'Green'}else{'Red'})
    
    Write-Host "测试辅助网关 ($SecondaryGateway):" -NoNewline
    $result2 = Test-NetConnection -ComputerName $SecondaryGateway -InformationLevel Quiet -WarningAction SilentlyContinue
    Write-Host " $(if($result2){'✓ 连通'}else{'✗ 失败'})" -ForegroundColor $(if($result2){'Green'}else{'Red'})
}

# 重置网络为DHCP
function Reset-ToDHCP {
    if ($null -eq $script:SelectedInterfaceIndex) {
        Write-Host "请先选择网络接口！" -ForegroundColor Red
        return
    }
    
    Write-Host "重置网络为DHCP模式..." -ForegroundColor Yellow
    
    try {
        # 清除所有静态IP配置
        $existingIPs = Get-NetIPAddress -InterfaceIndex $script:SelectedInterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        foreach ($ip in $existingIPs) {
            Remove-NetIPAddress -InterfaceIndex $script:SelectedInterfaceIndex -IPAddress $ip.IPAddress -Confirm:$false -ErrorAction SilentlyContinue
        }
        
        # 启用DHCP
        Set-NetIPInterface -InterfaceIndex $script:SelectedInterfaceIndex -Dhcp Enabled
        Set-DnsClientServerAddress -InterfaceIndex $script:SelectedInterfaceIndex -ResetServerAddresses
        
        # 重新获取IP
        Restart-NetAdapter -Name $script:SelectedInterface
        
        Write-Host "网络已重置为DHCP模式!" -ForegroundColor Green
    }
    catch {
        Write-Host "重置失败: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# 主程序
function Main {
    # 检查管理员权限
    if (-not (Test-Administrator)) {
        Write-Host "错误: 此脚本需要管理员权限运行!" -ForegroundColor Red
        Write-Host "请右键点击PowerShell，选择'以管理员身份运行'，然后重新执行此脚本。" -ForegroundColor Yellow
        Read-Host "按任意键退出"
        return
    }
    
    do {
        Show-Menu
        $choice = Read-Host "请输入选项 (0-6)"
        
        switch ($choice) {
            "1" { 
                Select-NetworkInterface
                Read-Host "`n按任意键继续"
            }
            "2" { 
                Set-DualIP
                Read-Host "`n按任意键继续"
            }
            "3" { 
                Remove-PrimaryIP
                Read-Host "`n按任意键继续"
            }
            "4" { 
                Remove-SecondaryIP
                Read-Host "`n按任意键继续"
            }
            "5" { 
                Show-NetworkConfig
                Read-Host "`n按任意键继续"
            }
            "6" { 
                Reset-ToDHCP
                Read-Host "`n按任意键继续"
            }
            "0" { 
                Write-Host "退出程序..." -ForegroundColor Green
                break
            }
            default { 
                Write-Host "无效选项，请重新选择!" -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    } while ($choice -ne "0")
}

# 启动主程序
Main
