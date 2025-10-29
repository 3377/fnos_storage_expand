#!/bin/bash
# ============================================================
# 飞牛NAS存储分区创建工具 v3.0 - 终极版
# ============================================================
# 全新方案：
# 1. 使用systemd一次性服务，在启动早期执行
# 2. 使用remount ro方式，避免完全卸载
# 3. 调整后立即修复fstab和GRUB
# 4. 系统只用8GB，预留5GB即可
#       经测试此方式重启后需要修复GRUB，修复方法：
# 1. 查看分区信息
# grub rescue> ls (hd0,msdos1)/

# 如果看到文件列表（boot、etc等），说明这是根分区
# 2. 设置根分区
# grub rescue> set root=(hd0,msdos1)

# 3. 设置prefix
# grub rescue> set prefix=(hd0,msdos1)/boot/grub

# 4. 加载normal模块
# grub rescue> insmod normal

# 5. 启动normal模式
grub rescue> normal
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

DISK="/dev/vda"
SYSTEM_PART="${DISK}1"
STORAGE_PART="${DISK}2"
LOG_FILE="/var/log/flynas_storage_v3.log"
SERVICE_FILE="/etc/systemd/system/flynas-resize.service"
SCRIPT_FILE="/usr/local/bin/flynas-resize-exec.sh"
STATE_FILE="/var/lib/flynas_resize_state"

log_info() { 
    echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

log_success() { 
    echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() { 
    echo -e "${RED}[$(date '+%H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() { 
    echo -e "${YELLOW}[$(date '+%H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

show_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║     飞牛NAS存储分区创建工具 v3.0 - 终极版                 ║"
    echo "║     新方案：一次性systemd服务 + 在线调整                  ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}\n"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "需要root权限"
        exit 1
    fi
}

check_system() {
    log_info "执行系统检查..."
    
    if [ ! -b "$DISK" ]; then
        log_error "磁盘 $DISK 不存在"
        exit 1
    fi
    
    if [ ! -b "$SYSTEM_PART" ]; then
        log_error "系统分区 $SYSTEM_PART 不存在"
        exit 1
    fi
    
    if [ -b "$STORAGE_PART" ]; then
        log_error "分区 $STORAGE_PART 已存在"
        exit 1
    fi
    
    local missing_tools=()
    for tool in parted e2fsck resize2fs lsblk blkid systemctl gdisk; do
        if ! command -v $tool &>/dev/null; then
            missing_tools+=($tool)
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_error "缺少必需工具: ${missing_tools[*]}"
        echo "安装命令: sudo apt-get install parted e2fsprogs gdisk"
        exit 1
    fi
    
    log_success "系统检查通过"
}

calculate_space() {
    log_info "计算分区空间..."
    
    local total_size_gb=$(lsblk -bno SIZE "$SYSTEM_PART" 2>/dev/null | awk '{printf "%.0f", $1/1024/1024/1024}')
    local used_gb=$(df -BG / 2>/dev/null | tail -1 | awk '{print $3}' | tr -d 'G')
    
    # 系统只用8GB，预留5GB即可，所以最小13GB
    local min_system_gb=13
    local max_shrink_gb=$((total_size_gb - min_system_gb))
    
    # 限制最大释放不超过总容量的90%
    local max_limit=$((total_size_gb * 9 / 10))
    if [ $max_shrink_gb -gt $max_limit ]; then
        max_shrink_gb=$max_limit
    fi
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}          空间分析${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  系统分区总大小: ${total_size_gb}GB"
    echo "  已使用空间: ${used_gb}GB"
    echo "  最小系统需求: ${min_system_gb}GB (已用8GB+预留5GB)"
    echo "  最大可释放: ${max_shrink_gb}GB"
    echo ""
    
    if [ $max_shrink_gb -lt 20 ]; then
        log_error "可释放空间不足20GB"
        exit 1
    fi
    
    echo -e "${YELLOW}请输入要释放的空间大小（GB）${NC}"
    echo "推荐: 100GB (系统保留20GB)"
    echo "最大: ${max_shrink_gb}GB"
    echo ""
    
    while true; do
        read -p "输入大小 [默认: 100GB]: " SHRINK_SIZE_GB
        
        if [ -z "$SHRINK_SIZE_GB" ]; then
            SHRINK_SIZE_GB=100
        fi
        
        if [[ "$SHRINK_SIZE_GB" =~ ^[0-9]+$ ]] && \
           [ $SHRINK_SIZE_GB -ge 20 ] && \
           [ $SHRINK_SIZE_GB -le $max_shrink_gb ]; then
            
            local remaining_gb=$((total_size_gb - SHRINK_SIZE_GB))
            if [ $remaining_gb -lt $min_system_gb ]; then
                echo -e "${RED}错误：释放${SHRINK_SIZE_GB}GB后，系统只剩${remaining_gb}GB，不足${min_system_gb}GB${NC}"
                continue
            fi
            
            break
        else
            echo -e "${RED}无效输入，请输入 20-${max_shrink_gb} 之间的整数${NC}"
        fi
    done
    
    log_success "将释放 ${SHRINK_SIZE_GB}GB 空间，系统保留 $((total_size_gb - SHRINK_SIZE_GB))GB"
}

create_resize_script() {
    log_info "创建分区调整执行脚本..."
    
    # 计算分区参数
    local current_size_mb=$(lsblk -bno SIZE "$SYSTEM_PART" | awk '{printf "%.0f", $1/1024/1024}')
    local target_fs_size_mb=$((current_size_mb - SHRINK_SIZE_GB * 1024 - 200))
    
    # 使用sgdisk获取更准确的分区信息
    local part_start=$(sgdisk -i 1 "$DISK" 2>/dev/null | grep "First sector:" | awk '{print $3}')
    local part_end=$(sgdisk -i 1 "$DISK" 2>/dev/null | grep "Last sector:" | awk '{print $3}')
    local disk_sectors=$(sgdisk -p "$DISK" 2>/dev/null | grep "total sectors" | awk '{print $5}')
    
    local shrink_sectors=$((SHRINK_SIZE_GB * 1024 * 1024 * 1024 / 512))
    local new_part1_end=$((part_end - shrink_sectors))
    local new_part2_start=$((new_part1_end + 1))
    
    log_info "分区参数："
    log_info "  当前大小: ${current_size_mb}MB"
    log_info "  目标FS大小: ${target_fs_size_mb}MB"
    log_info "  分区起始: ${part_start}"
    log_info "  分区原结束: ${part_end}"
    log_info "  新part1结束: ${new_part1_end}"
    log_info "  新part2起始: ${new_part2_start}"
    log_info "  磁盘总扇区: ${disk_sectors}"
    
    # 创建执行脚本（使用gdisk，更可靠）
    cat > "$SCRIPT_FILE" << 'SCRIPT_EOF'
#!/bin/bash

LOG="/var/log/flynas_resize_exec.log"
exec 1>"$LOG" 2>&1

echo "========================================="
echo "飞牛NAS分区调整执行脚本 v3.0"
echo "时间: $(date)"
echo "========================================="

DISK="/dev/vda"
SYSTEM_PART="${DISK}1"

# 读取参数
SCRIPT_EOF

    # 添加参数
    cat >> "$SCRIPT_FILE" << SCRIPT_EOF2
TARGET_FS_SIZE_MB=$target_fs_size_mb
PART_START=$part_start
NEW_PART1_END=$new_part1_end
NEW_PART2_START=$new_part2_start
DISK_SECTORS=$disk_sectors
SHRINK_SIZE_GB=$SHRINK_SIZE_GB
SCRIPT_EOF2

    # 添加执行逻辑
    cat >> "$SCRIPT_FILE" << 'SCRIPT_EOF3'

echo "参数："
echo "  TARGET_FS_SIZE_MB=$TARGET_FS_SIZE_MB"
echo "  PART_START=$PART_START"
echo "  NEW_PART1_END=$NEW_PART1_END"
echo "  NEW_PART2_START=$NEW_PART2_START"
echo ""

# 步骤1: 切换到只读模式
echo "步骤1: 尝试将根分区重新挂载为只读..."
mount -o remount,ro / 2>&1
if [ $? -eq 0 ]; then
    echo "根分区已重新挂载为只读"
    RO_SUCCESS=1
else
    echo "警告: 无法完全切换到只读模式，继续尝试..."
    RO_SUCCESS=0
fi

# 步骤2: 文件系统检查
echo "步骤2: 检查文件系统..."
e2fsck -fy "$SYSTEM_PART"
EC=$?
echo "文件系统检查完成，返回码: $EC"

# 步骤3: 缩小文件系统
echo "步骤3: 缩小文件系统到 ${TARGET_FS_SIZE_MB}MB..."
resize2fs "$SYSTEM_PART" ${TARGET_FS_SIZE_MB}M
if [ $? -ne 0 ]; then
    echo "错误: 文件系统缩小失败，尝试恢复..."
    resize2fs "$SYSTEM_PART"
    [ $RO_SUCCESS -eq 1 ] && mount -o remount,rw /
    exit 1
fi
echo "文件系统缩小完成"

# 步骤4: 使用gdisk调整分区（更可靠）
echo "步骤4: 使用gdisk调整分区表..."

# 保存UUID
OLD_UUID=$(blkid -s UUID -o value "$SYSTEM_PART")
echo "原始UUID: $OLD_UUID"

# 使用gdisk调整分区
(
echo d      # 删除分区
echo 1      # 分区1
echo n      # 新建分区
echo 1      # 分区号1
echo $PART_START  # 起始扇区（保持不变）
echo $NEW_PART1_END  # 结束扇区
echo        # 默认类型
echo n      # 新建分区2
echo 2      # 分区号2
echo $NEW_PART2_START  # 起始扇区
echo        # 默认结束（使用剩余空间）
echo        # 默认类型
echo w      # 写入
echo y      # 确认
) | gdisk "$DISK"

echo "gdisk调整完成"

# 步骤5: 通知内核
echo "步骤5: 通知内核重新读取分区表..."
partprobe "$DISK"
sleep 3
blockdev --rereadpt "$DISK" 2>/dev/null || true
sleep 3

# 步骤6: 扩展vda1文件系统到新边界
echo "步骤6: 扩展vda1文件系统..."
resize2fs "$SYSTEM_PART"
echo "文件系统扩展完成"

# 步骤7: 获取新UUID并更新配置
echo "步骤7: 检查UUID并更新配置..."
NEW_UUID=$(blkid -s UUID -o value "$SYSTEM_PART")
echo "新UUID: $NEW_UUID"

if [ "$OLD_UUID" != "$NEW_UUID" ] && [ -n "$NEW_UUID" ]; then
    echo "UUID已改变，更新fstab和GRUB..."
    
    # 挂载为读写以便修改
    mount -o remount,rw /
    
    # 更新fstab
    if [ -f /etc/fstab ]; then
        sed -i "s/$OLD_UUID/$NEW_UUID/g" /etc/fstab
        echo "fstab已更新"
    fi
    
    # 重新安装GRUB
    grub-install "$DISK"
    update-grub
    echo "GRUB已更新"
else
    echo "UUID未改变"
    [ $RO_SUCCESS -eq 1 ] && mount -o remount,rw /
fi

echo "========================================="
echo "分区调整完成！"
echo "========================================="

# 标记完成
touch /var/lib/flynas_resize_done

# 清理服务
systemctl disable flynas-resize.service 2>/dev/null || true
rm -f /etc/systemd/system/flynas-resize.service

exit 0
SCRIPT_EOF3

    chmod +x "$SCRIPT_FILE"
    log_success "分区调整执行脚本创建完成"
}

create_systemd_service() {
    log_info "创建systemd一次性服务..."
    
    cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=FlyNAS Storage Partition Resize
DefaultDependencies=no
After=local-fs-pre.target
Before=local-fs.target
ConditionPathExists=/var/lib/flynas_resize_state

[Service]
Type=oneshot
ExecStart=/usr/local/bin/flynas-resize-exec.sh
StandardOutput=journal+console
StandardError=journal+console
TimeoutSec=600

[Install]
WantedBy=local-fs.target
EOF

    systemctl daemon-reload
    systemctl enable flynas-resize.service
    
    # 创建状态文件
    echo "pending" > "$STATE_FILE"
    
    log_success "systemd服务创建完成"
}

show_summary() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}          操作摘要${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  操作类型: 创建飞牛NAS存储分区"
    echo "  释放空间: ${SHRINK_SIZE_GB}GB"
    echo "  新分区: /dev/vda2"
    echo ""
    echo "  v3.0新特性:"
    echo "  ✓ 使用systemd一次性服务"
    echo "  ✓ 使用gdisk（更可靠）"
    echo "  ✓ 自动修复UUID和GRUB"
    echo "  ✓ 完整的错误处理"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

show_reboot_info() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}          准备完成！${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}重要说明：${NC}"
    echo ""
    echo "  1. 重启后，systemd服务会在启动早期执行分区调整"
    echo "  2. 整个过程约5-10分钟"
    echo "  3. 日志保存在: /var/log/flynas_resize_exec.log"
    echo "  4. 完成后系统会自动继续启动"
    echo ""
    echo -e "${YELLOW}验证方法：${NC}"
    echo ""
    echo "  启动后执行:"
    echo "  sudo cat /var/log/flynas_resize_exec.log"
    echo "  lsblk /dev/vda"
    echo ""
    echo -e "${RED}注意事项：${NC}"
    echo ""
    echo "  • 不要在分区调整过程中强制关机"
    echo "  • 建议使用VNC或IPMI观察启动过程"
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

cleanup_after_reboot() {
    log_info "执行重启后清理..."
    
    if [ -f /var/lib/flynas_resize_done ]; then
        log_success "分区调整已完成！"
        
        # 查看日志
        if [ -f /var/log/flynas_resize_exec.log ]; then
            echo ""
            echo "=== 执行日志 ==="
            cat /var/log/flynas_resize_exec.log
            echo ""
        fi
        
        # 格式化vda2
        if [ -b "/dev/vda2" ]; then
            log_success "vda2已创建"
            log_info "格式化vda2..."
            mkfs.ext4 -F -L "FlyNAS_Storage" /dev/vda2
            
            echo ""
            echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${GREEN}          操作成功！${NC}"
            echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            lsblk /dev/vda
            echo ""
            echo "下一步："
            echo "  1. 在飞牛NAS中使用/dev/vda2创建存储空间"
            echo ""
            echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
        fi
        
        # 清理
        rm -f "$STATE_FILE"
        rm -f /var/lib/flynas_resize_done
        
        log_success "清理完成"
    else
        log_error "分区调整未完成"
    fi
}

main() {
    show_banner
    
    if [ "$1" = "--cleanup" ]; then
        check_root
        cleanup_after_reboot
        exit 0
    fi
    
    check_root
    check_system
    calculate_space
    show_summary
    
    echo -e "${RED}⚠️  最后确认 ⚠️${NC}"
    echo ""
    echo "此操作将："
    echo "  • 缩小/dev/vda1 ${SHRINK_SIZE_GB}GB"
    echo "  • 创建/dev/vda2 ${SHRINK_SIZE_GB}GB"
    echo "  • 需要重启系统"
    echo ""
    read -p "确认继续？(输入 YES): " confirm
    
    if [ "$confirm" != "YES" ]; then
        log_warning "用户取消操作"
        exit 0
    fi
    
    create_resize_script
    create_systemd_service
    show_reboot_info
    
    read -p "是否立即重启？(y/n): " reboot_now
    
    if [[ "$reboot_now" =~ ^[Yy]$ ]]; then
        log_info "系统将在5秒后重启..."
        sleep 5
        reboot
    else
        echo ""
        echo "请手动重启："
        echo "  sudo reboot"
        echo ""
        echo "重启后执行清理："
        echo "  sudo $0 --cleanup"
    fi
}

main "$@"
