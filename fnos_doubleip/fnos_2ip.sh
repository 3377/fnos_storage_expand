#!/bin/bash
# 飞牛系统网络配置管理脚本 v2.2 - 优化显示
# 功能：双IP配置、单IP恢复、状态查看

# ==================== 配置变量 ====================
PRIMARY_IP="10.1.1.66"
PRIMARY_NETMASK="24"
PRIMARY_GATEWAY="10.1.1.250"
PRIMARY_DNS="10.1.1.250"
SECONDARY_DNS="223.5.5.5"

SECONDARY_IP="192.168.70.66"
SECONDARY_NETMASK="24"
SECONDARY_GATEWAY="192.168.70.1"

INTERFACE="ens192"
CONN_NAME="fnos-network"

# sudo命令前缀（root用户为空，普通用户为"sudo"）
USE_SUDO=""
# ==================================================

# 输出函数（不使用颜色）
print_header() {
    echo "========================================"
    echo "$1"
    echo "========================================"
}

print_section() {
    echo "-------- $1 --------"
}

print_info() {
    echo "[信息] $1"
}

print_success() {
    echo "[成功] $1"
}

print_warning() {
    echo "[警告] $1"
}

print_error() {
    echo "[错误] $1"
}

# 检测实际网络接口
detect_interface() {
    local detected=$(${USE_SUDO} ip link show 2>/dev/null | grep -E "^[0-9]+: (eth|ens|enp)" | head -1 | cut -d: -f2 | tr -d ' ')
    if [ -n "$detected" ]; then
        INTERFACE=$detected
    fi
}

# 清理旧的后台服务和定时任务
cleanup_old_services() {
    print_info "清理旧的后台服务..."
    
    # 停止并删除systemd服务
    ${USE_SUDO} systemctl stop force-ip-order.service 2>/dev/null || true
    ${USE_SUDO} systemctl disable force-ip-order.service 2>/dev/null || true
    ${USE_SUDO} rm -f /etc/systemd/system/force-ip-order.service
    ${USE_SUDO} rm -f /usr/local/bin/force-ip-order.sh
    ${USE_SUDO} rm -f /usr/local/bin/check-ip-order.sh
    
    # 清理crontab中的定时任务
    ${USE_SUDO} crontab -l 2>/dev/null | grep -v "check-ip-order.sh" | ${USE_SUDO} crontab - 2>/dev/null || true
    
    # 清理日志文件
    ${USE_SUDO} rm -f /var/log/force-ip-order.log /var/log/ip-order-check.log
    
    # 解锁resolv.conf
    ${USE_SUDO} chattr -i /etc/resolv.conf 2>/dev/null || true
    
    ${USE_SUDO} systemctl daemon-reload 2>/dev/null
    print_success "清理完成"
}

# 清理旧的NetworkManager连接
cleanup_nm_connections() {
    print_info "清理旧的网络连接..."
    
    # 删除所有以primary开头的旧连接
    for conn in $(${USE_SUDO} nmcli -t -f NAME connection show 2>/dev/null | grep -E "^primary-"); do
        ${USE_SUDO} nmcli connection delete "$conn" 2>/dev/null || true
    done
    
    # 删除我们的固定连接名
    ${USE_SUDO} nmcli connection delete "$CONN_NAME" 2>/dev/null || true
    
    print_success "清理完成"
}

# 配置双IP模式
configure_dual_ip() {
    clear
    print_header "配置双IP模式"
    echo ""
    
    detect_interface
    print_info "使用网络接口: ${INTERFACE}"
    echo ""
    
    cleanup_old_services
    cleanup_nm_connections
    
    print_info "创建双IP网络连接..."
    
    # 创建包含两个IP的NetworkManager连接
    ${USE_SUDO} nmcli connection add \
        type ethernet \
        con-name "$CONN_NAME" \
        ifname $INTERFACE \
        ipv4.addresses "${PRIMARY_IP}/${PRIMARY_NETMASK},${SECONDARY_IP}/${SECONDARY_NETMASK}" \
        ipv4.gateway ${PRIMARY_GATEWAY} \
        ipv4.dns "${PRIMARY_DNS},${SECONDARY_DNS}" \
        ipv4.method manual \
        ipv4.route-metric 100 \
        connection.autoconnect yes \
        connection.autoconnect-priority 100 \
        ipv4.may-fail no
    
    # 添加到192.168.70.x网段的静态路由
    ${USE_SUDO} nmcli connection modify "$CONN_NAME" +ipv4.routes "192.168.70.0/24 ${SECONDARY_GATEWAY} 200"
    
    print_info "激活网络连接..."
    sleep 2
    
    # 激活连接
    if ${USE_SUDO} nmcli connection up "$CONN_NAME" 2>/dev/null; then
        print_success "网络连接激活成功"
    else
        print_warning "NetworkManager激活失败，尝试手动配置..."
        ${USE_SUDO} ip addr flush dev $INTERFACE
        ${USE_SUDO} ip link set $INTERFACE down
        sleep 1
        ${USE_SUDO} ip link set $INTERFACE up
        sleep 2
        ${USE_SUDO} ip addr add ${PRIMARY_IP}/${PRIMARY_NETMASK} dev $INTERFACE
        ${USE_SUDO} ip addr add ${SECONDARY_IP}/${SECONDARY_NETMASK} dev $INTERFACE
        ${USE_SUDO} ip route add default via ${PRIMARY_GATEWAY} dev $INTERFACE metric 100
        ${USE_SUDO} ip route add 192.168.70.0/24 via ${SECONDARY_GATEWAY} dev $INTERFACE metric 200
        print_success "手动配置完成"
    fi
    
    # 配置DNS
    ${USE_SUDO} bash -c "cat > /etc/resolv.conf" <<EOF
# DNS配置 - 由ip.sh生成
nameserver ${PRIMARY_DNS}
nameserver ${SECONDARY_DNS}
EOF
    
    # 刷新DNS缓存
    ${USE_SUDO} systemctl restart systemd-resolved 2>/dev/null || true
    
    echo ""
    print_header "双IP配置完成"
    echo ""
    
    verify_configuration
    
    echo ""
    read -p "按回车键返回主菜单..."
}

# 配置单IP模式（恢复）
configure_single_ip() {
    clear
    print_header "恢复单IP模式"
    echo ""
    
    detect_interface
    print_info "使用网络接口: ${INTERFACE}"
    echo ""
    
    cleanup_old_services
    cleanup_nm_connections
    
    print_info "创建单IP网络连接..."
    
    # 创建只包含主IP的NetworkManager连接
    ${USE_SUDO} nmcli connection add \
        type ethernet \
        con-name "$CONN_NAME" \
        ifname $INTERFACE \
        ipv4.addresses "${PRIMARY_IP}/${PRIMARY_NETMASK}" \
        ipv4.gateway ${PRIMARY_GATEWAY} \
        ipv4.dns "${PRIMARY_DNS},${SECONDARY_DNS}" \
        ipv4.method manual \
        ipv4.route-metric 100 \
        connection.autoconnect yes \
        connection.autoconnect-priority 100 \
        ipv4.may-fail no
    
    print_info "激活网络连接..."
    sleep 2
    
    # 激活连接
    if ${USE_SUDO} nmcli connection up "$CONN_NAME" 2>/dev/null; then
        print_success "网络连接激活成功"
    else
        print_warning "NetworkManager激活失败，尝试手动配置..."
        ${USE_SUDO} ip addr flush dev $INTERFACE
        ${USE_SUDO} ip link set $INTERFACE down
        sleep 1
        ${USE_SUDO} ip link set $INTERFACE up
        sleep 2
        ${USE_SUDO} ip addr add ${PRIMARY_IP}/${PRIMARY_NETMASK} dev $INTERFACE
        ${USE_SUDO} ip route add default via ${PRIMARY_GATEWAY} dev $INTERFACE metric 100
        print_success "手动配置完成"
    fi
    
    # 配置DNS
    ${USE_SUDO} bash -c "cat > /etc/resolv.conf" <<EOF
# DNS配置 - 由ip.sh生成
nameserver ${PRIMARY_DNS}
nameserver ${SECONDARY_DNS}
EOF
    
    # 刷新DNS缓存
    ${USE_SUDO} systemctl restart systemd-resolved 2>/dev/null || true
    
    echo ""
    print_header "单IP配置完成"
    echo ""
    
    verify_configuration
    
    echo ""
    read -p "按回车键返回主菜单..."
}

# 验证当前配置
verify_configuration() {
    detect_interface
    
    print_section "当前网络配置状态"
    
    echo ""
    echo "【IP地址配置】"
    ${USE_SUDO} ip addr show $INTERFACE 2>/dev/null | grep "inet " | while read -r line; do
        echo "  $line"
    done
    
    echo ""
    echo "【路由配置】"
    ${USE_SUDO} ip route show 2>/dev/null | grep -E "(default|192.168)" | while read -r line; do
        echo "  $line"
    done
    
    echo ""
    echo "【DNS配置】"
    cat /etc/resolv.conf 2>/dev/null | grep nameserver | while read -r line; do
        echo "  $line"
    done
    
    echo ""
    echo "【NetworkManager连接状态】"
    local conn_status=$(${USE_SUDO} nmcli connection show --active 2>/dev/null | grep "$CONN_NAME")
    if [ -n "$conn_status" ]; then
        echo "  [√] 连接已激活: $CONN_NAME"
    else
        echo "  [X] 连接未激活"
    fi
    
    echo ""
    echo "【连接测试】"
    # 测试主网络
    if ${USE_SUDO} ping -c 1 -W 2 ${PRIMARY_GATEWAY} >/dev/null 2>&1; then
        echo "  [√] 主网络连接正常 (${PRIMARY_GATEWAY})"
    else
        echo "  [X] 主网络连接失败"
    fi
    
    # 测试192.168.70网段（如果配置了双IP）
    local has_secondary=$(${USE_SUDO} ip addr show $INTERFACE 2>/dev/null | grep "$SECONDARY_IP")
    if [ -n "$has_secondary" ]; then
        if ${USE_SUDO} ping -c 1 -W 2 ${SECONDARY_GATEWAY} >/dev/null 2>&1; then
            echo "  [√] 辅助网络连接正常 (${SECONDARY_GATEWAY})"
        else
            echo "  [!] 辅助网络连接失败或未配置"
        fi
    fi
    
    echo ""
    echo "----------------------------------------"
}

# 查看当前状态
view_status() {
    clear
    print_header "网络配置状态"
    echo ""
    
    verify_configuration
    
    echo ""
    echo "提示："
    echo "  • 主IP (${PRIMARY_IP}) 用于主网络通信"
    echo "  • 辅助IP (${SECONDARY_IP}) 用于访问192.168.70.x网段"
    echo "  • 查看详细配置: ${USE_SUDO} nmcli connection show ${CONN_NAME}"
    echo ""
    
    read -p "按回车键返回主菜单..."
}

# 显示主菜单
show_menu() {
    while true; do
        clear
        print_header "飞牛系统网络配置管理 v2.2"
        echo ""
        echo "当前配置信息："
        echo "  主IP: ${PRIMARY_IP}/${PRIMARY_NETMASK}"
        echo "  主网关: ${PRIMARY_GATEWAY}"
        echo "  辅助IP: ${SECONDARY_IP}/${SECONDARY_NETMASK}"
        echo "  辅助网关: ${SECONDARY_GATEWAY}"
        echo ""
        echo "请选择操作："
        echo ""
        echo "  1) 配置双IP模式"
        echo "     └─ 同时使用两个IP，访问10.1.1.x和192.168.70.x网段"
        echo ""
        echo "  2) 恢复单IP模式"
        echo "     └─ 仅使用主IP ${PRIMARY_IP}"
        echo ""
        echo "  3) 查看当前网络状态"
        echo ""
        echo "  4) 退出"
        echo ""
        echo "----------------------------------------"
        read -p "请输入选项 [1-4]: " choice
        
        case $choice in
            1)
                configure_dual_ip
                ;;
            2)
                configure_single_ip
                ;;
            3)
                view_status
                ;;
            4)
                clear
                echo "感谢使用！再见！"
                echo ""
                exit 0
                ;;
            *)
                print_error "无效选项，请重新选择"
                sleep 2
                ;;
        esac
    done
}

# 主程序入口
main() {
    # 权限检查和处理
    if [ "$EUID" -eq 0 ]; then
        # 运行在root模式下
        print_info "检测到root权限，直接运行..."
        USE_SUDO=""
    else
        # 运行在普通用户模式下，检查sudo权限
        print_info "检测到普通用户，检查sudo权限..."
        if ! sudo -v 2>/dev/null; then
            print_error "需要sudo权限才能运行此脚本"
            echo "请使用以下方式运行："
            echo "  sudo ./ip.sh"
            echo "或："
            echo "  su -c './ip.sh'"
            exit 1
        fi
        USE_SUDO="sudo"
        print_success "sudo权限检查通过"
    fi
    
    # 显示欢迎信息
    clear
    print_header "飞牛系统网络配置管理 v2.2"
    echo ""
    echo "正在初始化..."
    sleep 1
    
    # 进入主菜单
    show_menu
}

# 运行主程序
main
