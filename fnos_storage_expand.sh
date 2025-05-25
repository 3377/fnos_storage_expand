#!/bin/bash

# =============================================================================
# 飞牛OS存储空间自动化扩容脚本
# 适用于ESXi虚拟化环境下的飞牛OS系统
# 版本: 1.1
# 作者: AI Assistant
# 日期: $(date +%Y-%m-%d)
# 更新: 修复LVM逻辑卷路径问题，添加GPT分区表支持
# =============================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志文件
LOG_FILE="/var/log/fnos_storage_expand_$(date +%Y%m%d_%H%M%S).log"
BACKUP_DIR="/tmp/fnos_expand_backup_$(date +%Y%m%d_%H%M%S)"

# 全局变量
STORAGE_DEVICE=""
STORAGE_PARTITION=""
STORAGE_MOUNT_POINT=""
FILESYSTEM_TYPE=""
VG_NAME=""
LV_NAME=""
PV_NAME=""
TARGET_SIZE_BYTES=""
TARGET_SIZE_HUMAN=""

# =============================================================================
# 工具函数
# =============================================================================

# 打印带颜色的消息
print_info() {
    echo -e "${BLUE}[信息]${NC} $1" | tee -a "$LOG_FILE"
}

print_success() {
    echo -e "${GREEN}[成功]${NC} $1" | tee -a "$LOG_FILE"
}

print_warning() {
    echo -e "${YELLOW}[警告]${NC} $1" | tee -a "$LOG_FILE"
}

print_error() {
    echo -e "${RED}[错误]${NC} $1" | tee -a "$LOG_FILE"
}

# 显示进度条
show_progress() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((width * current / total))
    local remaining=$((width - completed))
    
    printf "\r${BLUE}["
    printf "%${completed}s" | tr ' ' '#'
    printf "%${remaining}s" | tr ' ' '-'
    printf "] %d%%${NC}" $percentage
}

# 确认操作
confirm_operation() {
    local message="$1"
    echo -e "${YELLOW}$message${NC}"
    read -p "请输入 'yes' 确认继续，或按回车取消: " confirm
    if [[ "$confirm" != "yes" ]]; then
        print_warning "操作已取消"
        exit 0
    fi
}

# 检查命令是否存在
check_command() {
    if ! command -v "$1" &> /dev/null; then
        print_error "命令 '$1' 未找到，请先安装相关工具"
        exit 1
    fi
}

# 验证数值是否有效
validate_numeric_value() {
    local value="$1"
    local description="$2"
    
    if [[ -z "$value" ]] || [[ ! "$value" =~ ^[0-9]+$ ]]; then
        print_error "无效的数值: $description = '$value'"
        print_info "请检查设备是否存在且可访问"
        return 1
    fi
    
    if [[ "$value" -eq 0 ]]; then
        print_error "数值为零: $description = '$value'"
        return 1
    fi
    
    return 0
}

# 构建逻辑卷路径
build_lv_path() {
    local vg_name="$1"
    local lv_name="$2"
    local storage_device="$3"
    
    # 尝试标准路径
    local lv_path="/dev/$vg_name/$lv_name"
    if [[ -e "$lv_path" ]]; then
        echo "$lv_path"
        return 0
    fi
    
    # 尝试mapper路径
    local vg_name_clean=$(echo "$vg_name" | tr '-' '_')
    local lv_name_clean=$(echo "$lv_name" | tr '-' '_')
    lv_path="/dev/mapper/${vg_name_clean}-${lv_name_clean}"
    if [[ -e "$lv_path" ]]; then
        echo "$lv_path"
        return 0
    fi
    
    # 使用原始存储设备路径
    echo "$storage_device"
    return 0
}

# =============================================================================
# 环境检测和预检查
# =============================================================================

check_environment() {
    print_info "开始环境检测..."
    
    # 检查是否为root用户
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要root权限运行，请使用 sudo 执行"
        exit 1
    fi
    
    # 检查必要的命令
    local required_commands=("fdisk" "pvdisplay" "vgdisplay" "lvdisplay" "df" "lsblk" "mount" "numfmt")
    for cmd in "${required_commands[@]}"; do
        check_command "$cmd"
    done
    
    # 检查是否为飞牛OS系统
    if [[ ! -f "/etc/fnos-release" ]] && [[ ! -d "/vol1" ]]; then
        print_warning "未检测到飞牛OS特征，请确认这是飞牛OS系统"
        confirm_operation "是否继续执行？"
    fi
    
    # 创建备份目录
    mkdir -p "$BACKUP_DIR"
    print_success "环境检测完成，备份目录: $BACKUP_DIR"
}

# =============================================================================
# 自动检测存储配置
# =============================================================================

detect_storage_config() {
    print_info "正在检测存储配置..."
    
    # 检测存储空间挂载点（通常是/vol1）
    local mount_points=("/vol1" "/volume1" "/mnt/storage")
    for mp in "${mount_points[@]}"; do
        if mountpoint -q "$mp" 2>/dev/null; then
            STORAGE_MOUNT_POINT="$mp"
            break
        fi
    done
    
    if [[ -z "$STORAGE_MOUNT_POINT" ]]; then
        print_error "未找到存储空间挂载点"
        print_info "当前挂载点列表："
        mount | grep -E "(vol|storage|data)" | tee -a "$LOG_FILE"
        exit 1
    fi
    
    print_info "检测到存储挂载点: $STORAGE_MOUNT_POINT"
    
    # 获取文件系统信息
    local fs_info=$(df -T "$STORAGE_MOUNT_POINT" | tail -n 1)
    STORAGE_DEVICE=$(echo "$fs_info" | awk '{print $1}')
    FILESYSTEM_TYPE=$(echo "$fs_info" | awk '{print $2}')
    
    print_info "存储设备: $STORAGE_DEVICE"
    print_info "文件系统类型: $FILESYSTEM_TYPE"
    
    # 检测LVM信息
    if [[ "$STORAGE_DEVICE" =~ /dev/mapper/ ]] || [[ "$STORAGE_DEVICE" =~ /dev/dm- ]]; then
        print_info "检测到LVM设备，正在获取LVM信息..."
        
        # 获取LV信息
        local lv_info=$(lvdisplay "$STORAGE_DEVICE" 2>/dev/null)
        if [[ -n "$lv_info" ]]; then
            VG_NAME=$(echo "$lv_info" | grep "VG Name" | awk '{print $3}')
            LV_NAME=$(echo "$lv_info" | grep "LV Name" | awk '{print $3}')
            print_info "卷组名称: $VG_NAME"
            print_info "逻辑卷名称: $LV_NAME"
        fi
        
        # 获取PV信息
        local pv_list=$(pvdisplay 2>/dev/null | grep -B1 -A10 "$VG_NAME" | grep "PV Name" | awk '{print $3}')
        for pv in $pv_list; do
            if [[ -n "$pv" ]]; then
                PV_NAME="$pv"
                # 从PV名称推导出基础设备名
                if [[ "$PV_NAME" =~ ^/dev/([a-z]+)[0-9]+$ ]]; then
                    STORAGE_PARTITION="$PV_NAME"
                    local base_device="${BASH_REMATCH[1]}"
                    local base_device_path="/dev/$base_device"
                    
                    # 验证基础设备是否存在
                    if [[ -b "$base_device_path" ]]; then
                        # 检查这个设备是否有足够的未分配空间
                        local device_size=$(lsblk -b -n -o SIZE "$base_device_path" 2>/dev/null | head -1 | tr -d ' \n')
                        local partition_size=$(lsblk -b -n -o SIZE "$PV_NAME" 2>/dev/null | head -1 | tr -d ' \n')
                        
                        if validate_numeric_value "$device_size" "设备大小" && validate_numeric_value "$partition_size" "分区大小" && [[ $device_size -gt $partition_size ]]; then
                            print_info "找到可扩容的设备: $base_device_path"
                            print_info "设备总大小: $(numfmt --to=iec $device_size)"
                            print_info "当前分区大小: $(numfmt --to=iec $partition_size)"
                            print_info "可扩容空间: $(numfmt --to=iec $((device_size - partition_size)))"
                            break
                        fi
                    fi
                fi
            fi
        done
    else
        print_error "未检测到LVM配置，此脚本主要适用于LVM环境"
        exit 1
    fi
    
    if [[ -z "$PV_NAME" ]] || [[ -z "$VG_NAME" ]] || [[ -z "$LV_NAME" ]]; then
        print_error "无法获取完整的LVM信息"
        print_info "请检查以下信息："
        print_info "PV名称: $PV_NAME"
        print_info "VG名称: $VG_NAME" 
        print_info "LV名称: $LV_NAME"
        exit 1
    fi
    
    print_success "存储配置检测完成"
}

# =============================================================================
# 显示磁盘状态和扩容选项
# =============================================================================

show_disk_status_and_options() {
    print_info "当前磁盘状态分析"
    echo ""
    
    # 获取基础设备信息
    local base_device=$(echo "$PV_NAME" | sed 's/[0-9]*$//')
    local device_size_bytes=$(lsblk -b -n -o SIZE "$base_device" 2>/dev/null | head -1 | tr -d ' \n')
    local partition_size_bytes=$(lsblk -b -n -o SIZE "$PV_NAME" 2>/dev/null | head -1 | tr -d ' \n')
    local current_fs_size_bytes=$(df -B1 "$STORAGE_MOUNT_POINT" | tail -n 1 | awk '{print $2}')
    local current_fs_used_bytes=$(df -B1 "$STORAGE_MOUNT_POINT" | tail -n 1 | awk '{print $3}')
    local current_fs_avail_bytes=$(df -B1 "$STORAGE_MOUNT_POINT" | tail -n 1 | awk '{print $4}')
    
    # 验证获取的数值
    if ! validate_numeric_value "$device_size_bytes" "设备总大小"; then
        print_error "无法获取有效的设备大小信息"
        exit 1
    fi
    
    if ! validate_numeric_value "$partition_size_bytes" "分区大小"; then
        print_error "无法获取有效的分区大小信息"
        exit 1
    fi
    
    if ! validate_numeric_value "$current_fs_size_bytes" "文件系统大小"; then
        print_error "无法获取有效的文件系统大小信息"
        exit 1
    fi
    
    # 转换为人类可读格式
    local device_size_human=$(numfmt --to=iec $device_size_bytes)
    local partition_size_human=$(numfmt --to=iec $partition_size_bytes)
    local current_fs_size_human=$(numfmt --to=iec $current_fs_size_bytes)
    local current_fs_used_human=$(numfmt --to=iec $current_fs_used_bytes)
    local current_fs_avail_human=$(numfmt --to=iec $current_fs_avail_bytes)
    local expandable_space_bytes=$((device_size_bytes - partition_size_bytes))
    local expandable_space_human=$(numfmt --to=iec $expandable_space_bytes)
    
    # 计算使用率
    local usage_percent=$((current_fs_used_bytes * 100 / current_fs_size_bytes))
    
    # 显示详细状态表格
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                        磁盘状态详情                          ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${NC}"
    printf "${BLUE}║${NC} %-20s ${YELLOW}│${NC} %-35s ${BLUE}║${NC}\n" "虚拟磁盘设备" "$base_device"
    printf "${BLUE}║${NC} %-20s ${YELLOW}│${NC} %-35s ${BLUE}║${NC}\n" "存储分区" "$PV_NAME"
    printf "${BLUE}║${NC} %-20s ${YELLOW}│${NC} %-35s ${BLUE}║${NC}\n" "挂载点" "$STORAGE_MOUNT_POINT"
    printf "${BLUE}║${NC} %-20s ${YELLOW}│${NC} %-35s ${BLUE}║${NC}\n" "文件系统类型" "$FILESYSTEM_TYPE"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${NC}"
    printf "${BLUE}║${NC} %-20s ${YELLOW}│${NC} %-35s ${BLUE}║${NC}\n" "虚拟磁盘总大小" "$device_size_human"
    printf "${BLUE}║${NC} %-20s ${YELLOW}│${NC} %-35s ${BLUE}║${NC}\n" "当前分区大小" "$partition_size_human"
    printf "${BLUE}║${NC} %-20s ${YELLOW}│${NC} %-35s ${BLUE}║${NC}\n" "当前文件系统大小" "$current_fs_size_human"
    printf "${BLUE}║${NC} %-20s ${YELLOW}│${NC} %-35s ${BLUE}║${NC}\n" "已使用空间" "$current_fs_used_human ($usage_percent%)"
    printf "${BLUE}║${NC} %-20s ${YELLOW}│${NC} %-35s ${BLUE}║${NC}\n" "可用空间" "$current_fs_avail_human"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${NC}"
    if [[ $expandable_space_bytes -gt 0 ]]; then
        printf "${BLUE}║${NC} %-20s ${YELLOW}│${NC} ${GREEN}%-35s${NC} ${BLUE}║${NC}\n" "可扩容空间" "$expandable_space_human"
        printf "${BLUE}║${NC} %-20s ${YELLOW}│${NC} ${GREEN}%-35s${NC} ${BLUE}║${NC}\n" "扩容后总大小" "$device_size_human"
    else
        printf "${BLUE}║${NC} %-20s ${YELLOW}│${NC} ${RED}%-35s${NC} ${BLUE}║${NC}\n" "可扩容空间" "无可扩容空间"
    fi
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    
    echo ""
    
    # 检查是否可以扩容
    if [[ $expandable_space_bytes -le 0 ]]; then
        print_warning "当前磁盘没有可扩容的空间"
        print_info "请先在ESXi中扩容虚拟磁盘，然后重新运行此脚本"
        exit 0
    fi
    
    # 提供扩容选项
    print_info "扩容选项："
    echo "1. 扩容到最大可用空间 ($device_size_human)"
    echo "2. 自定义扩容大小"
    echo "3. 取消扩容"
    echo ""
    
    while true; do
        read -p "请选择扩容方式 (1-3): " expansion_choice
        
        case $expansion_choice in
            1)
                print_info "选择扩容到最大可用空间: $device_size_human"
                TARGET_SIZE_BYTES=$device_size_bytes
                TARGET_SIZE_HUMAN=$device_size_human
                break
                ;;
            2)
                echo ""
                print_info "当前可扩容范围: $current_fs_size_human ~ $device_size_human"
                while true; do
                    read -p "请输入目标大小 (例如: 80G, 1T): " custom_size
                    
                    # 验证输入格式
                    if [[ "$custom_size" =~ ^[0-9]+[KMGT]?$ ]]; then
                        # 转换为字节
                        local target_bytes=$(numfmt --from=iec "$custom_size" 2>/dev/null)
                        
                        if [[ -n "$target_bytes" ]] && [[ $target_bytes -gt $current_fs_size_bytes ]] && [[ $target_bytes -le $device_size_bytes ]]; then
                            TARGET_SIZE_BYTES=$target_bytes
                            TARGET_SIZE_HUMAN=$(numfmt --to=iec $target_bytes)
                            print_success "目标大小设置为: $TARGET_SIZE_HUMAN"
                            break 2
                        else
                            print_error "目标大小必须大于当前大小 ($current_fs_size_human) 且不超过最大可用大小 ($device_size_human)"
                        fi
                    else
                        print_error "格式错误，请输入如 80G 或 1T 的格式"
                    fi
                done
                ;;
            3)
                print_info "扩容操作已取消"
                exit 0
                ;;
            *)
                print_error "无效选项，请输入 1-3"
                ;;
        esac
    done
    
    echo ""
    print_info "扩容计划："
    echo "  当前大小: $current_fs_size_human"
    echo "  目标大小: $TARGET_SIZE_HUMAN"
    echo "  扩容空间: $(numfmt --to=iec $((TARGET_SIZE_BYTES - current_fs_size_bytes)))"
    echo ""
    
    confirm_operation "确认执行扩容操作？"
}

# =============================================================================
# 备份关键配置
# =============================================================================

backup_configurations() {
    print_info "正在备份关键配置..."
    
    # 备份分区表
    local base_device=$(echo "$PV_NAME" | sed 's/[0-9]*$//')
    if [[ -b "$base_device" ]]; then
        print_info "备份分区表: $base_device"
        sfdisk -d "$base_device" > "$BACKUP_DIR/partition_table.backup" 2>/dev/null
    fi
    
    # 备份LVM配置
    print_info "备份LVM配置..."
    vgcfgbackup "$VG_NAME" -f "$BACKUP_DIR/lvm_backup" 2>/dev/null
    
    # 备份fstab
    print_info "备份fstab..."
    cp /etc/fstab "$BACKUP_DIR/fstab.backup"
    
    # 记录当前状态
    print_info "记录当前系统状态..."
    {
        echo "=== 磁盘信息 ==="
        lsblk
        echo ""
        echo "=== 分区信息 ==="
        fdisk -l "$base_device" 2>/dev/null
        echo ""
        echo "=== LVM信息 ==="
        pvdisplay
        echo ""
        vgdisplay
        echo ""
        lvdisplay
        echo ""
        echo "=== 文件系统信息 ==="
        df -h
        echo ""
        echo "=== 挂载信息 ==="
        mount | grep -E "(vol|storage|data)"
    } > "$BACKUP_DIR/system_status.txt"
    
    print_success "配置备份完成，备份位置: $BACKUP_DIR"
}

# =============================================================================
# 分区扩展
# =============================================================================

extend_partition() {
    print_info "开始扩展分区..."
    
    local base_device=$(echo "$PV_NAME" | sed 's/[0-9]*$//')
    local partition_number=$(echo "$PV_NAME" | sed 's/.*[^0-9]//')
    
    print_info "基础设备: $base_device"
    print_info "分区号: $partition_number"
    print_info "目标大小: $TARGET_SIZE_HUMAN"
    
    # 显示当前分区信息
    print_info "当前分区信息:"
    fdisk -l "$base_device" | tee -a "$LOG_FILE"
    
    confirm_operation "即将扩展分区 $PV_NAME 到 $TARGET_SIZE_HUMAN，这将删除并重建分区（数据不会丢失，但有风险）"
    
    # 获取分区的起始扇区
    local start_sector=$(fdisk -l "$base_device" | grep "$PV_NAME" | awk '{print $2}')
    
    if [[ -z "$start_sector" ]]; then
        print_error "无法获取分区起始扇区"
        exit 1
    fi
    
    print_info "分区起始扇区: $start_sector"
    
    # 计算目标结束扇区
    local sector_size=512  # 通常为512字节
    local device_size_bytes=$(lsblk -b -n -o SIZE "$base_device" 2>/dev/null | head -1 | tr -d ' \n')
    local end_sector=""
    
    # 如果目标大小等于设备总大小，使用默认（最大）
    if [[ $TARGET_SIZE_BYTES -eq $device_size_bytes ]]; then
        end_sector=""  # 使用默认值（磁盘末尾）
        print_info "扩展到磁盘最大容量"
    else
        # 计算目标结束扇区
        local target_sectors=$((TARGET_SIZE_BYTES / sector_size))
        end_sector=$((start_sector + target_sectors - 1))
        print_info "计算的结束扇区: $end_sector"
    fi
    
    # 检测分区表类型
    local partition_table_type=$(fdisk -l "$base_device" 2>/dev/null | grep "Disklabel type" | awk '{print $3}')
    
    # 使用fdisk扩展分区
    print_info "正在扩展分区..."
    print_info "分区表类型: $partition_table_type"
    
    if [[ "$partition_table_type" == "gpt" ]]; then
        # GPT分区表
        {
            echo "d"           # 删除分区
            echo "$partition_number"  # 分区号
            echo "n"           # 新建分区
            echo "$partition_number"  # 分区号
            echo "$start_sector"      # 起始扇区
            echo "$end_sector"        # 结束扇区（空字符串表示使用默认值）
            echo "t"           # 修改分区类型
            echo "$partition_number"  # 分区号
            echo "31"          # Linux LVM类型 (GPT)
            echo "w"           # 写入并退出
        } | fdisk "$base_device" >> "$LOG_FILE" 2>&1
    else
        # MBR分区表
        {
            echo "d"           # 删除分区
            echo "$partition_number"  # 分区号
            echo "n"           # 新建分区
            echo "p"           # 主分区
            echo "$partition_number"  # 分区号
            echo "$start_sector"      # 起始扇区
            echo "$end_sector"        # 结束扇区（空字符串表示使用默认值）
            echo "t"           # 修改分区类型
            echo "$partition_number"  # 分区号
            echo "8e"          # LVM类型 (MBR)
            echo "w"           # 写入并退出
        } | fdisk "$base_device" >> "$LOG_FILE" 2>&1
    fi
    
    if [[ $? -eq 0 ]]; then
        print_success "分区扩展完成"
    else
        print_error "分区扩展失败，请检查日志: $LOG_FILE"
        exit 1
    fi
    
    # 通知内核重新读取分区表
    print_info "通知内核重新读取分区表..."
    partprobe "$base_device" 2>/dev/null || true
    sleep 2
    
    # 验证分区扩展
    print_info "验证分区扩展结果:"
    fdisk -l "$base_device" | tee -a "$LOG_FILE"
}

# =============================================================================
# LVM扩容
# =============================================================================

extend_lvm() {
    print_info "开始LVM扩容..."
    
    # 扩展物理卷
    print_info "扩展物理卷: $PV_NAME"
    if pvresize "$PV_NAME" >> "$LOG_FILE" 2>&1; then
        print_success "物理卷扩展完成"
    else
        print_error "物理卷扩展失败"
        exit 1
    fi
    
    # 显示PV状态
    print_info "物理卷状态:"
    pvdisplay "$PV_NAME" | tee -a "$LOG_FILE"
    
    # 显示VG状态
    print_info "卷组状态:"
    vgdisplay "$VG_NAME" | tee -a "$LOG_FILE"
    
    # 构建完整的逻辑卷路径
    local lv_path=$(build_lv_path "$VG_NAME" "$LV_NAME" "$STORAGE_DEVICE")
    print_info "逻辑卷路径: $lv_path"
    
    # 计算需要扩展的大小
    local current_lv_size_bytes=$(lvdisplay "$lv_path" | grep "LV Size" | awk '{print $3}' | numfmt --from=iec 2>/dev/null || echo "0")
    local base_device=$(echo "$PV_NAME" | sed 's/[0-9]*$//')
    local device_size_bytes=$(lsblk -b -n -o SIZE "$base_device" 2>/dev/null | head -1 | tr -d ' \n')
    
    # 扩展逻辑卷
    print_info "扩展逻辑卷: $lv_path 到 $TARGET_SIZE_HUMAN"
    
    # 如果目标大小等于设备总大小，使用所有可用空间
    if [[ $TARGET_SIZE_BYTES -eq $device_size_bytes ]]; then
        print_info "扩展到最大可用空间"
        if lvresize -l +100%FREE "$lv_path" >> "$LOG_FILE" 2>&1; then
            print_success "逻辑卷扩展完成"
        else
            print_error "逻辑卷扩展失败"
            exit 1
        fi
    else
        # 使用指定大小扩展
        print_info "扩展到指定大小: $TARGET_SIZE_HUMAN"
        if lvresize -L "$TARGET_SIZE_HUMAN" "$lv_path" >> "$LOG_FILE" 2>&1; then
            print_success "逻辑卷扩展完成"
        else
            print_error "逻辑卷扩展失败"
            exit 1
        fi
    fi
    
    # 显示LV状态
    print_info "逻辑卷状态:"
    lvdisplay "$lv_path" | tee -a "$LOG_FILE"
}

# =============================================================================
# 文件系统扩容
# =============================================================================

extend_filesystem() {
    print_info "开始文件系统扩容..."
    print_info "文件系统类型: $FILESYSTEM_TYPE"
    
    case "$FILESYSTEM_TYPE" in
        "btrfs")
            print_info "扩容btrfs文件系统..."
            if btrfs filesystem resize max "$STORAGE_MOUNT_POINT" >> "$LOG_FILE" 2>&1; then
                print_success "btrfs文件系统扩容完成"
            else
                print_error "btrfs文件系统扩容失败"
                exit 1
            fi
            ;;
        "ext4"|"ext3"|"ext2")
            print_info "扩容ext文件系统..."
            if resize2fs "$STORAGE_DEVICE" >> "$LOG_FILE" 2>&1; then
                print_success "ext文件系统扩容完成"
            else
                print_error "ext文件系统扩容失败"
                exit 1
            fi
            ;;
        "xfs")
            print_info "扩容xfs文件系统..."
            if xfs_growfs "$STORAGE_MOUNT_POINT" >> "$LOG_FILE" 2>&1; then
                print_success "xfs文件系统扩容完成"
            else
                print_error "xfs文件系统扩容失败"
                exit 1
            fi
            ;;
        *)
            print_warning "不支持的文件系统类型: $FILESYSTEM_TYPE"
            print_info "请手动扩容文件系统"
            ;;
    esac
}

# =============================================================================
# 验证扩容结果
# =============================================================================

verify_expansion() {
    print_info "验证扩容结果..."
    
    # 显示磁盘使用情况
    print_info "当前磁盘使用情况:"
    df -h "$STORAGE_MOUNT_POINT" | tee -a "$LOG_FILE"
    
    # 显示LVM状态
    print_info "LVM状态:"
    {
        echo "=== 物理卷状态 ==="
        pvdisplay "$PV_NAME"
        echo ""
        echo "=== 卷组状态 ==="
        vgdisplay "$VG_NAME"
        echo ""
        echo "=== 逻辑卷状态 ==="
        local lv_display_path=$(build_lv_path "$VG_NAME" "$LV_NAME" "$STORAGE_DEVICE")
        lvdisplay "$lv_display_path"
    } | tee -a "$LOG_FILE"
    
    # 检查文件系统完整性
    print_info "检查文件系统完整性..."
    case "$FILESYSTEM_TYPE" in
        "btrfs")
            btrfs filesystem show "$STORAGE_MOUNT_POINT" >> "$LOG_FILE" 2>&1
            ;;
        "ext4"|"ext3"|"ext2")
            # 对于已挂载的ext文件系统，只能进行只读检查
            tune2fs -l "$STORAGE_DEVICE" >> "$LOG_FILE" 2>&1
            ;;
        "xfs")
            xfs_info "$STORAGE_MOUNT_POINT" >> "$LOG_FILE" 2>&1
            ;;
    esac
    
    print_success "扩容验证完成"
}

# =============================================================================
# 清理和总结
# =============================================================================

cleanup_and_summary() {
    print_info "清理临时文件和生成总结报告..."
    
    # 生成总结报告
    local report_file="$BACKUP_DIR/expansion_report.txt"
    {
        echo "飞牛OS存储扩容报告"
        echo "===================="
        echo "执行时间: $(date)"
        echo "日志文件: $LOG_FILE"
        echo "备份目录: $BACKUP_DIR"
        echo ""
        echo "扩容前后对比:"
        echo "============"
        echo "存储设备: $STORAGE_DEVICE"
        echo "挂载点: $STORAGE_MOUNT_POINT"
        echo "文件系统: $FILESYSTEM_TYPE"
        echo "物理卷: $PV_NAME"
        echo "卷组: $VG_NAME"
        echo "逻辑卷: $LV_NAME"
        echo ""
        echo "当前磁盘使用情况:"
        df -h "$STORAGE_MOUNT_POINT"
        echo ""
        echo "LVM状态摘要:"
        vgdisplay "$VG_NAME" | grep -E "(VG Size|Free)"
        local lv_summary_path=$(build_lv_path "$VG_NAME" "$LV_NAME" "$STORAGE_DEVICE")
        lvdisplay "$lv_summary_path" | grep -E "(LV Size)"
    } > "$report_file"
    
    print_success "扩容操作完成！"
    print_info "总结报告: $report_file"
    print_info "详细日志: $LOG_FILE"
    print_info "配置备份: $BACKUP_DIR"
    
    echo ""
    print_info "请在飞牛OS管理界面中确认存储空间大小是否正确显示"
    print_warning "建议重启系统以确保所有更改生效"
}

# =============================================================================
# 主函数
# =============================================================================

main() {
    echo -e "${BLUE}"
    echo "=============================================="
    echo "    飞牛OS存储空间自动化扩容脚本 v1.1"
    echo "=============================================="
    echo -e "${NC}"
    
    print_info "开始执行存储扩容操作..."
    print_info "日志文件: $LOG_FILE"
    
    # 执行各个步骤
    local steps=(
        "check_environment:环境检测"
        "detect_storage_config:存储配置检测"
        "show_disk_status_and_options:磁盘状态分析和扩容选择"
        "backup_configurations:备份配置"
        "extend_partition:扩展分区"
        "extend_lvm:LVM扩容"
        "extend_filesystem:文件系统扩容"
        "verify_expansion:验证结果"
        "cleanup_and_summary:清理总结"
    )
    
    local total_steps=${#steps[@]}
    local current_step=0
    
    for step_info in "${steps[@]}"; do
        local step_func="${step_info%%:*}"
        local step_desc="${step_info##*:}"
        
        current_step=$((current_step + 1))
        echo ""
        print_info "步骤 $current_step/$total_steps: $step_desc"
        show_progress $current_step $total_steps
        echo ""
        
        # 执行步骤函数
        if ! $step_func; then
            print_error "步骤失败: $step_desc"
            exit 1
        fi
    done
    
    echo ""
    print_success "所有步骤执行完成！"
}

# =============================================================================
# 脚本入口
# =============================================================================

# =============================================================================
# 备份恢复功能（集成自backup_restore.sh）
# =============================================================================

# 创建备份
create_backup() {
    local backup_dir="$1"
    
    print_info "开始创建系统备份..."
    print_info "备份目录: $backup_dir"
    
    # 创建备份目录
    mkdir -p "$backup_dir"
    
    # 备份分区表
    print_info "备份磁盘分区表..."
    for disk in $(lsblk -d -n -o NAME | grep -E '^[a-z]+$'); do
        if [[ -b "/dev/$disk" ]]; then
            print_info "备份 /dev/$disk 分区表"
            sfdisk -d "/dev/$disk" > "$backup_dir/partition_table_${disk}.backup" 2>/dev/null
        fi
    done
    
    # 备份LVM配置
    print_info "备份LVM配置..."
    if command -v vgdisplay &> /dev/null; then
        # 获取所有卷组
        local vg_list=$(vgdisplay 2>/dev/null | grep "VG Name" | awk '{print $3}')
        for vg in $vg_list; do
            if [[ -n "$vg" ]]; then
                print_info "备份卷组: $vg"
                vgcfgbackup "$vg" -f "$backup_dir/lvm_backup_${vg}" 2>/dev/null
            fi
        done
        
        # 备份LVM元数据
        print_info "备份LVM元数据..."
        {
            echo "=== 物理卷信息 ==="
            pvdisplay 2>/dev/null
            echo ""
            echo "=== 卷组信息 ==="
            vgdisplay 2>/dev/null
            echo ""
            echo "=== 逻辑卷信息 ==="
            lvdisplay 2>/dev/null
        } > "$backup_dir/lvm_metadata.txt"
    fi
    
    # 备份关键系统文件
    print_info "备份关键系统文件..."
    local files_to_backup=(
        "/etc/fstab"
        "/etc/mtab"
        "/proc/mounts"
        "/proc/partitions"
    )
    
    for file in "${files_to_backup[@]}"; do
        if [[ -f "$file" ]]; then
            local basename=$(basename "$file")
            cp "$file" "$backup_dir/${basename}.backup" 2>/dev/null
            print_info "已备份: $file"
        fi
    done
    
    # 记录系统状态
    print_info "记录系统状态信息..."
    {
        echo "备份创建时间: $(date)"
        echo "系统信息: $(uname -a)"
        echo "主机名: $(hostname)"
        echo ""
        echo "=== 磁盘信息 ==="
        lsblk
        echo ""
        echo "=== 磁盘分区详情 ==="
        fdisk -l 2>/dev/null
        echo ""
        echo "=== 挂载信息 ==="
        mount
        echo ""
        echo "=== 文件系统使用情况 ==="
        df -h
        echo ""
        echo "=== 内存信息 ==="
        free -h
        echo ""
        echo "=== 网络接口 ==="
        ip addr show
    } > "$backup_dir/system_status.txt"
    
    # 创建备份清单
    print_info "创建备份清单..."
    {
        echo "飞牛OS存储扩容备份清单"
        echo "========================"
        echo "备份时间: $(date)"
        echo "备份目录: $backup_dir"
        echo ""
        echo "备份文件列表:"
        find "$backup_dir" -type f -exec ls -lh {} \;
    } > "$backup_dir/backup_manifest.txt"
    
    # 计算备份文件的校验和
    print_info "计算文件校验和..."
    find "$backup_dir" -type f -name "*.backup" -exec md5sum {} \; > "$backup_dir/checksums.md5"
    
    print_success "备份创建完成！"
    print_info "备份位置: $backup_dir"
    print_info "备份清单: $backup_dir/backup_manifest.txt"
}

# 恢复备份
restore_backup() {
    local backup_dir="$1"
    
    if [[ ! -d "$backup_dir" ]]; then
        print_error "备份目录不存在: $backup_dir"
        exit 1
    fi
    
    print_warning "即将从备份恢复系统配置"
    print_warning "这将覆盖当前的系统配置！"
    echo ""
    read -p "请输入 'RESTORE' 确认恢复操作: " confirm
    
    if [[ "$confirm" != "RESTORE" ]]; then
        print_info "恢复操作已取消"
        exit 0
    fi
    
    print_info "开始恢复系统配置..."
    print_info "备份目录: $backup_dir"
    
    # 验证备份完整性
    print_info "验证备份完整性..."
    if [[ -f "$backup_dir/checksums.md5" ]]; then
        if md5sum -c "$backup_dir/checksums.md5" --quiet; then
            print_success "备份文件完整性验证通过"
        else
            print_warning "备份文件完整性验证失败，但继续恢复"
        fi
    fi
    
    # 恢复分区表
    print_info "恢复磁盘分区表..."
    for backup_file in "$backup_dir"/partition_table_*.backup; do
        if [[ -f "$backup_file" ]]; then
            local disk_name=$(basename "$backup_file" | sed 's/partition_table_\(.*\)\.backup/\1/')
            local disk_device="/dev/$disk_name"
            
            if [[ -b "$disk_device" ]]; then
                print_warning "即将恢复 $disk_device 的分区表"
                read -p "确认恢复 $disk_device 分区表? (y/N): " confirm_disk
                
                if [[ "$confirm_disk" =~ ^[Yy]$ ]]; then
                    print_info "恢复 $disk_device 分区表..."
                    if sfdisk "$disk_device" < "$backup_file" 2>/dev/null; then
                        print_success "分区表恢复成功: $disk_device"
                        # 通知内核重新读取分区表
                        partprobe "$disk_device" 2>/dev/null || true
                    else
                        print_error "分区表恢复失败: $disk_device"
                    fi
                else
                    print_info "跳过 $disk_device 分区表恢复"
                fi
            fi
        fi
    done
    
    # 恢复LVM配置
    print_info "恢复LVM配置..."
    for backup_file in "$backup_dir"/lvm_backup_*; do
        if [[ -f "$backup_file" ]]; then
            local vg_name=$(basename "$backup_file" | sed 's/lvm_backup_\(.*\)/\1/')
            
            print_warning "即将恢复卷组: $vg_name"
            read -p "确认恢复卷组 $vg_name? (y/N): " confirm_vg
            
            if [[ "$confirm_vg" =~ ^[Yy]$ ]]; then
                print_info "恢复卷组: $vg_name"
                if vgcfgrestore "$vg_name" -f "$backup_file" 2>/dev/null; then
                    print_success "卷组恢复成功: $vg_name"
                else
                    print_error "卷组恢复失败: $vg_name"
                fi
            else
                print_info "跳过卷组 $vg_name 恢复"
            fi
        fi
    done
    
    # 恢复系统文件
    print_info "恢复系统文件..."
    local files_to_restore=(
        "fstab"
        "mtab"
    )
    
    for file in "${files_to_restore[@]}"; do
        local backup_file="$backup_dir/${file}.backup"
        local target_file="/etc/$file"
        
        if [[ -f "$backup_file" ]]; then
            print_info "恢复 $target_file"
            cp "$backup_file" "$target_file" 2>/dev/null
            print_success "已恢复: $target_file"
        fi
    done
    
    print_success "系统配置恢复完成！"
    print_warning "建议重启系统以确保所有更改生效"
}

# 列出备份
list_backups() {
    local search_dir="${1:-/tmp}"
    
    print_info "搜索备份目录: $search_dir"
    
    local backup_dirs=$(find "$search_dir" -maxdepth 1 -type d -name "fnos_*backup*" 2>/dev/null | sort)
    
    if [[ -z "$backup_dirs" ]]; then
        print_warning "未找到备份目录"
        return
    fi
    
    echo ""
    print_info "找到的备份目录:"
    echo "================================"
    
    local count=1
    for dir in $backup_dirs; do
        echo -e "${BLUE}[$count]${NC} $dir"
        
        if [[ -f "$dir/backup_manifest.txt" ]]; then
            local backup_time=$(grep "备份时间:" "$dir/backup_manifest.txt" 2>/dev/null | cut -d: -f2-)
            echo "    备份时间:$backup_time"
        fi
        
        if [[ -f "$dir/system_status.txt" ]]; then
            local system_info=$(grep "系统信息:" "$dir/system_status.txt" 2>/dev/null | cut -d: -f2-)
            echo "    系统信息:$system_info"
        fi
        
        local dir_size=$(du -sh "$dir" 2>/dev/null | cut -f1)
        echo "    目录大小: $dir_size"
        echo ""
        
        count=$((count + 1))
    done
}

# 验证备份
verify_backup() {
    local backup_dir="$1"
    
    if [[ ! -d "$backup_dir" ]]; then
        print_error "备份目录不存在: $backup_dir"
        exit 1
    fi
    
    print_info "验证备份: $backup_dir"
    
    # 检查必要文件
    local required_files=(
        "backup_manifest.txt"
        "system_status.txt"
    )
    
    local missing_files=()
    for file in "${required_files[@]}"; do
        if [[ ! -f "$backup_dir/$file" ]]; then
            missing_files+=("$file")
        fi
    done
    
    if [[ ${#missing_files[@]} -gt 0 ]]; then
        print_warning "缺少以下文件:"
        for file in "${missing_files[@]}"; do
            echo "  - $file"
        done
    else
        print_success "必要文件检查通过"
    fi
    
    # 验证文件完整性
    if [[ -f "$backup_dir/checksums.md5" ]]; then
        print_info "验证文件完整性..."
        if md5sum -c "$backup_dir/checksums.md5" --quiet; then
            print_success "文件完整性验证通过"
        else
            print_error "文件完整性验证失败"
        fi
    else
        print_warning "未找到校验和文件"
    fi
    
    # 显示备份信息
    if [[ -f "$backup_dir/backup_manifest.txt" ]]; then
        echo ""
        print_info "备份清单:"
        cat "$backup_dir/backup_manifest.txt"
    fi
}

# 清理备份
cleanup_backups() {
    local search_dir="${1:-/tmp}"
    local days="${2:-7}"
    
    print_info "清理 $days 天前的备份文件..."
    print_info "搜索目录: $search_dir"
    
    local old_backups=$(find "$search_dir" -maxdepth 1 -type d -name "fnos_*backup*" -mtime +$days 2>/dev/null)
    
    if [[ -z "$old_backups" ]]; then
        print_info "未找到需要清理的备份"
        return
    fi
    
    echo ""
    print_warning "将要删除以下备份目录:"
    for dir in $old_backups; do
        local dir_size=$(du -sh "$dir" 2>/dev/null | cut -f1)
        echo "  - $dir (大小: $dir_size)"
    done
    
    echo ""
    read -p "确认删除这些备份? (y/N): " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        for dir in $old_backups; do
            print_info "删除: $dir"
            rm -rf "$dir"
        done
        print_success "备份清理完成"
    else
        print_info "清理操作已取消"
    fi
}

# 备份恢复主菜单
show_backup_menu() {
    echo ""
    print_info "备份恢复功能菜单:"
    echo "1. 创建备份"
    echo "2. 恢复备份"
    echo "3. 列出备份"
    echo "4. 验证备份"
    echo "5. 清理旧备份"
    echo "6. 返回主菜单"
    echo ""
    read -p "请输入选项 (1-6): " choice
    
    case $choice in
        1)
            read -p "请输入备份目录路径 (回车使用默认): " input_dir
            local backup_dir="${input_dir:-$BACKUP_DIR}"
            create_backup "$backup_dir"
            ;;
        2)
            read -p "请输入备份目录路径: " input_dir
            if [[ -n "$input_dir" ]]; then
                restore_backup "$input_dir"
            else
                print_error "请提供备份目录路径"
            fi
            ;;
        3)
            read -p "请输入搜索目录 (回车使用 /tmp): " search_dir
            list_backups "${search_dir:-/tmp}"
            ;;
        4)
            read -p "请输入备份目录路径: " input_dir
            if [[ -n "$input_dir" ]]; then
                verify_backup "$input_dir"
            else
                print_error "请提供备份目录路径"
            fi
            ;;
        5)
            read -p "请输入搜索目录 (回车使用 /tmp): " search_dir
            read -p "请输入保留天数 (回车使用 7): " days
            cleanup_backups "${search_dir:-/tmp}" "${days:-7}"
            ;;
        6)
            return 0
            ;;
        *)
            print_error "无效选项，请重新选择"
            show_backup_menu
            ;;
    esac
    
    echo ""
    read -p "按回车继续..." 
    show_backup_menu
}

# 主功能选择菜单
show_main_menu() {
    echo -e "${BLUE}"
    echo "=============================================="
    echo "    飞牛OS存储空间自动化扩容脚本 v1.1"
    echo "=============================================="
    echo -e "${NC}"
    
    echo ""
    print_info "请选择功能:"
    echo "1. 存储空间扩容"
    echo "2. 备份恢复管理"
    echo "3. 干运行检测"
    echo "4. 退出"
    echo ""
    read -p "请输入选项 (1-4): " main_choice
    
    case $main_choice in
        1)
            print_info "开始存储空间扩容..."
            return 1  # 返回1表示执行扩容
            ;;
        2)
            show_backup_menu
            show_main_menu  # 备份菜单结束后返回主菜单
            ;;
        3)
            print_info "执行干运行检测..."
            check_environment
            detect_storage_config
            show_dry_run_status
            echo ""
            read -p "按回车返回主菜单..." 
            show_main_menu
            ;;
        4)
            print_info "退出程序"
            exit 0
            ;;
        *)
            print_error "无效选项，请重新选择"
            show_main_menu
            ;;
    esac
}

# 干运行状态显示
show_dry_run_status() {
    print_info "当前磁盘状态分析"
    echo ""
    
    # 获取基础设备信息
    local base_device=$(echo "$PV_NAME" | sed 's/[0-9]*$//')
    local device_size_bytes=$(lsblk -b -n -o SIZE "$base_device" 2>/dev/null | head -1 | tr -d ' \n')
    local partition_size_bytes=$(lsblk -b -n -o SIZE "$PV_NAME" 2>/dev/null | head -1 | tr -d ' \n')
    local current_fs_size_bytes=$(df -B1 "$STORAGE_MOUNT_POINT" | tail -n 1 | awk '{print $2}')
    local current_fs_used_bytes=$(df -B1 "$STORAGE_MOUNT_POINT" | tail -n 1 | awk '{print $3}')
    local current_fs_avail_bytes=$(df -B1 "$STORAGE_MOUNT_POINT" | tail -n 1 | awk '{print $4}')
    
    # 验证获取的数值
    if ! validate_numeric_value "$device_size_bytes" "设备总大小"; then
        print_error "无法获取有效的设备大小信息"
        return 1
    fi
    
    if ! validate_numeric_value "$partition_size_bytes" "分区大小"; then
        print_error "无法获取有效的分区大小信息"
        return 1
    fi
    
    if ! validate_numeric_value "$current_fs_size_bytes" "文件系统大小"; then
        print_error "无法获取有效的文件系统大小信息"
        return 1
    fi
    
    # 转换为人类可读格式
    local device_size_human=$(numfmt --to=iec $device_size_bytes)
    local partition_size_human=$(numfmt --to=iec $partition_size_bytes)
    local current_fs_size_human=$(numfmt --to=iec $current_fs_size_bytes)
    local current_fs_used_human=$(numfmt --to=iec $current_fs_used_bytes)
    local current_fs_avail_human=$(numfmt --to=iec $current_fs_avail_bytes)
    local expandable_space_bytes=$((device_size_bytes - partition_size_bytes))
    local expandable_space_human=$(numfmt --to=iec $expandable_space_bytes)
    
    # 计算使用率
    local usage_percent=$((current_fs_used_bytes * 100 / current_fs_size_bytes))
    
    # 显示详细状态表格
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                        磁盘状态详情                          ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${NC}"
    printf "${BLUE}║${NC} %-20s ${YELLOW}│${NC} %-35s ${BLUE}║${NC}\n" "虚拟磁盘设备" "$base_device"
    printf "${BLUE}║${NC} %-20s ${YELLOW}│${NC} %-35s ${BLUE}║${NC}\n" "存储分区" "$PV_NAME"
    printf "${BLUE}║${NC} %-20s ${YELLOW}│${NC} %-35s ${BLUE}║${NC}\n" "挂载点" "$STORAGE_MOUNT_POINT"
    printf "${BLUE}║${NC} %-20s ${YELLOW}│${NC} %-35s ${BLUE}║${NC}\n" "文件系统类型" "$FILESYSTEM_TYPE"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${NC}"
    printf "${BLUE}║${NC} %-20s ${YELLOW}│${NC} %-35s ${BLUE}║${NC}\n" "虚拟磁盘总大小" "$device_size_human"
    printf "${BLUE}║${NC} %-20s ${YELLOW}│${NC} %-35s ${BLUE}║${NC}\n" "当前分区大小" "$partition_size_human"
    printf "${BLUE}║${NC} %-20s ${YELLOW}│${NC} %-35s ${BLUE}║${NC}\n" "当前文件系统大小" "$current_fs_size_human"
    printf "${BLUE}║${NC} %-20s ${YELLOW}│${NC} %-35s ${BLUE}║${NC}\n" "已使用空间" "$current_fs_used_human ($usage_percent%)"
    printf "${BLUE}║${NC} %-20s ${YELLOW}│${NC} %-35s ${BLUE}║${NC}\n" "可用空间" "$current_fs_avail_human"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${NC}"
    if [[ $expandable_space_bytes -gt 0 ]]; then
        printf "${BLUE}║${NC} %-20s ${YELLOW}│${NC} ${GREEN}%-35s${NC} ${BLUE}║${NC}\n" "可扩容空间" "$expandable_space_human"
        printf "${BLUE}║${NC} %-20s ${YELLOW}│${NC} ${GREEN}%-35s${NC} ${BLUE}║${NC}\n" "扩容后总大小" "$device_size_human"
        echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        print_success "检测到可扩容空间: $expandable_space_human"
        print_info "可以扩容到最大: $device_size_human"
    else
        printf "${BLUE}║${NC} %-20s ${YELLOW}│${NC} ${RED}%-35s${NC} ${BLUE}║${NC}\n" "可扩容空间" "无可扩容空间"
        echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        print_warning "当前磁盘没有可扩容的空间"
        print_info "请先在ESXi中扩容虚拟磁盘"
    fi
}

# =============================================================================
# 脚本入口和参数处理
# =============================================================================

# 检查参数
if [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    echo "飞牛OS存储空间自动化扩容脚本"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help     显示此帮助信息"
    echo "  --dry-run      仅检测配置，不执行实际操作"
    echo "  --menu         显示功能选择菜单"
    echo "  --backup       进入备份恢复管理"
    echo ""
    echo "备份恢复命令:"
    echo "  --backup create [目录]        创建备份"
    echo "  --backup restore <目录>       恢复备份"
    echo "  --backup list [搜索目录]      列出备份"
    echo "  --backup verify <目录>        验证备份"
    echo "  --backup cleanup [目录] [天数] 清理旧备份"
    echo ""
    echo "注意事项:"
    echo "1. 请确保已在ESXi中扩容虚拟磁盘"
    echo "2. 建议在执行前创建虚拟机快照"
    echo "3. 此脚本需要root权限运行"
    echo ""
    echo "项目地址: https://github.com/3377/fnos_storage_expand"
    echo ""
    exit 0
fi

# 处理命令行参数
case "${1:-}" in
    "--dry-run")
        print_info "干运行模式：仅检测配置"
        check_environment
        detect_storage_config
        show_dry_run_status
        print_info "干运行模式检测完成，退出"
        exit 0
        ;;
    "--menu")
        # 显示主菜单
        if show_main_menu; then
            # 如果返回1，表示用户选择了扩容功能
            main "$@"
        fi
        exit 0
        ;;
    "--backup")
        # 备份恢复功能
        case "${2:-}" in
            "create")
                backup_dir="${3:-$BACKUP_DIR}"
                create_backup "$backup_dir"
                ;;
            "restore")
                if [[ -n "$3" ]]; then
                    restore_backup "$3"
                else
                    print_error "请提供备份目录路径"
                    echo "用法: $0 --backup restore <备份目录>"
                    exit 1
                fi
                ;;
            "list")
                list_backups "${3:-/tmp}"
                ;;
            "verify")
                if [[ -n "$3" ]]; then
                    verify_backup "$3"
                else
                    print_error "请提供备份目录路径"
                    echo "用法: $0 --backup verify <备份目录>"
                    exit 1
                fi
                ;;
            "cleanup")
                cleanup_backups "${3:-/tmp}" "${4:-7}"
                ;;
            "")
                # 进入备份恢复交互菜单
                show_backup_menu
                ;;
            *)
                print_error "未知备份选项: $2"
                echo "使用 '$0 --help' 查看帮助信息"
                exit 1
                ;;
        esac
        exit 0
        ;;
    "")
        # 无参数时显示主菜单
        if show_main_menu; then
            # 如果返回1，表示用户选择了扩容功能
            main "$@"
        fi
        exit 0
        ;;
    *)
        # 其他参数或直接执行扩容
        main "$@"
        ;;
esac 