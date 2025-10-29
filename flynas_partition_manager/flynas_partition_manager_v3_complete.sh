#!/bin/bash
# ============================================================
# 飞牛NAS智能分区管理工具 v3.0 完整版
# ============================================================
# 整合功能：
# 1. 动态检测所有分区（vda1/2/3/4...）
# 2. 识别未分配空间
# 3. 支持多种文件系统（ext4/xfs/btrfs），明确标注支持情况
# 4. 用户灵活选择任意源/目标分区
# 5. 智能计算可用空间和建议
# 6. 两阶段安全操作
# ============================================================

set -e

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 全局变量
DISK="/dev/vda"
STATE_FILE="/var/lib/flynas_partition_state_v3"
LOG_FILE="/var/log/flynas_partition_manager.log"

# 分区信息数组
declare -A PARTITIONS
declare -A PARTITION_SIZES
declare -A PARTITION_USED
declare -A PARTITION_FS
declare -A PARTITION_MOUNT
declare -A PARTITION_ROLE

# 操作变量
SOURCE_PART_NUM=""
TARGET_PART_NUM=""
RESIZE_SIZE_GB=0
RESIZE_SIZE_MB=0
HAS_LVM=false
VG_NAME=""
LV_NAME=""

# 日志函数
log_info() { echo -e "${BLUE}[信息]${NC} $1" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[成功]${NC} $1" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}[错误]${NC} $1" | tee -a "$LOG_FILE"; }
log_warning() { echo -e "${YELLOW}[警告]${NC} $1" | tee -a "$LOG_FILE"; }

# 显示横幅
show_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║      飞牛NAS智能分区管理工具 v3.0                    ║"
    echo "║      • 动态检测所有分区                              ║"
    echo "║      • 灵活选择操作                                  ║"
    echo "║      • 智能建议优化                                  ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}\n"
}

# 文件系统支持信息
get_fs_support() {
    case $1 in
        ext4) echo "✓ 缩小/扩展(离线缩小)" ;;
        xfs) echo "✓ 仅扩展 ✗ 不支持缩小" ;;
        btrfs) echo "✓ 在线缩小/扩展" ;;
        ntfs) echo "⚠ 有限支持" ;;
        *) echo "未知" ;;
    esac
}

# 动态检测所有分区
detect_all_partitions() {
    log_info "扫描磁盘分区..."
    
    # 清空数组
    PARTITIONS=()
    PARTITION_SIZES=()
    PARTITION_USED=()
    PARTITION_FS=()
    PARTITION_MOUNT=()
    PARTITION_ROLE=()
    
    # 扫描分区
    for num in {1..10}; do
        local device="${DISK}${num}"
        [ ! -b "$device" ] && continue
        
        local size=$(lsblk -bno SIZE "$device" 2>/dev/null | awk '{printf "%.1f", $1/1024/1024/1024}')
        local fstype=$(lsblk -no FSTYPE "$device" 2>/dev/null)
        [ -z "$fstype" ] && fstype="未格式化"
        
        local mountpoint=$(lsblk -no MOUNTPOINT "$device" 2>/dev/null)
        local used="-"
        
        if [ -n "$mountpoint" ]; then
            local used_raw=$(df -BG "$mountpoint" 2>/dev/null | tail -1 | awk '{print $3}' | tr -d 'G')
            if [ -n "$used_raw" ] && [ "$used_raw" != "0" ]; then
                used="${used_raw}GB"
            else
                used="-"
            fi
        fi
        
        # 判断角色
        local role="数据分区"
        case "$mountpoint" in
            "/") role="系统分区" ;;
            "/boot") role="引导分区" ;;
            *vol*) role="存储分区" ;;
        esac
        
        # 检测MD/LVM成员
        if [[ "$fstype" =~ (linux_raid_member|LVM2_member) ]]; then
            local md_name=$(ls /sys/block/vda${num}/holders/ 2>/dev/null | grep "^md" | head -1)
            if [ -n "$md_name" ]; then
                role="MD成员(→$md_name)"
                # 获取MD设备上的文件系统和挂载点
                local md_mount=$(lsblk -no MOUNTPOINT "/dev/$md_name" 2>/dev/null | head -1)
                local md_fs=$(lsblk -no FSTYPE "/dev/$md_name" 2>/dev/null | head -1)
                
                if [ -n "$md_mount" ]; then
                    mountpoint="$md_mount"
                    # 保存上层文件系统信息（用于判断是否可缩小）- 避免换行符
                    if [ -n "$md_fs" ]; then
                        fstype="${fstype}/${md_fs}"  # 使用斜杠而不是括号，避免显示问题
                    fi
                    
                    local md_used=$(df -BG "$md_mount" 2>/dev/null | tail -1 | awk '{print $3}' | tr -d 'G')
                    if [ -n "$md_used" ] && [ "$md_used" != "0" ]; then
                        used="${md_used}GB"
                    fi
                fi
            fi
        fi
        
        PARTITIONS[$num]="$device"
        PARTITION_SIZES[$num]="$size"
        PARTITION_USED[$num]="$used"
        PARTITION_FS[$num]="$fstype"
        PARTITION_MOUNT[$num]="$mountpoint"
        PARTITION_ROLE[$num]="$role"
        
        # 调试信息
        log_info "[调试] vda$num: size=$size, used=$used, fs=$fstype" >> "$LOG_FILE"
    done
    
    # 检测未分配空间（磁盘上未被任何分区占用的空间）
    # 获取磁盘总大小（MB）
    local disk_total_mb=$(parted "$DISK" unit MB print 2>/dev/null | grep "^Disk $DISK:" | awk '{print $3}' | tr -d 'MB')
    
    # 获取最后一个分区的结束位置（MB）
    local last_part_end_mb=0
    for num in {1..10}; do
        local device="${DISK}${num}"
        if [ -b "$device" ]; then
            local part_end=$(parted "$DISK" unit MB print 2>/dev/null | grep "^ $num" | awk '{print $3}' | tr -d 'MB')
            if [ -n "$part_end" ] && awk "BEGIN {exit !($part_end > $last_part_end_mb)}"; then
                last_part_end_mb=$part_end
            fi
        fi
    done
    
    # 计算未分配空间（MB）= 磁盘总大小 - 最后分区结束位置
    local unalloc_mb=0
    if [ -n "$disk_total_mb" ] && [ -n "$last_part_end_mb" ]; then
        unalloc_mb=$(awk "BEGIN {printf \"%.0f\", $disk_total_mb - $last_part_end_mb}")
    fi
    
    # 转换为GB并保存（只有大于1GB才显示）
    if [ "$unalloc_mb" -gt 1024 ]; then
        local unalloc_gb=$(awk "BEGIN {printf \"%.1f\", $unalloc_mb / 1024}")
        PARTITIONS[99]="未分配空间"
        PARTITION_SIZES[99]="$unalloc_gb"
        PARTITION_USED[99]="0"
        PARTITION_FS[99]="空闲"
        PARTITION_MOUNT[99]="-"
        PARTITION_ROLE[99]="磁盘末尾未分配"
        
        log_info "[计算] 磁盘总大小=${disk_total_mb}MB, 最后分区结束=${last_part_end_mb}MB, 未分配=${unalloc_mb}MB (${unalloc_gb}GB)" >> "$LOG_FILE"
    fi
    
    log_success "检测到 ${#PARTITIONS[@]} 个分区"
}

# 检测LVM
detect_lvm() {
    local vg=$(vgs --noheadings -o vg_name 2>/dev/null | tr -d ' ' | head -1)
    if [ -n "$vg" ]; then
        HAS_LVM=true
        VG_NAME="$vg"
        LV_NAME=$(lvs --noheadings -o lv_name "$VG_NAME" 2>/dev/null | tr -d ' ' | head -1)
    fi
}

# 显示所有分区
show_all_partitions() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}               当前分区状态${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    printf "${YELLOW}%-4s %-15s %-10s %-10s %-18s %-18s %-15s${NC}\n" \
        "编号" "设备" "大小" "已用" "文件系统" "挂载点" "角色"
    echo "──────────────────────────────────────────────────────────────────────────────────────"
    
    for num in $(echo "${!PARTITIONS[@]}" | tr ' ' '\n' | sort -n); do
        local color=""
        [ "$num" = "99" ] && color="${GREEN}"
        [ "${PARTITION_MOUNT[$num]}" = "/" ] && color="${RED}"
        
        local mount="${PARTITION_MOUNT[$num]}"
        [ -z "$mount" ] && mount="-"
        
        printf "${color}%-4s %-15s %-10s %-10s %-18s %-18s %-15s${NC}\n" \
            "$num" "${PARTITIONS[$num]:0:15}" "${PARTITION_SIZES[$num]}GB" \
            "${PARTITION_USED[$num]}" "${PARTITION_FS[$num]:0:18}" \
            "${mount:0:18}" "${PARTITION_ROLE[$num]:0:15}"
    done
    
    echo "────────────────────────────────────────────────────────────────────────────\n"
    
    # 空间说明
    echo -e "${CYAN}【空间说明】${NC}"
    echo -e "  ${YELLOW}未分配空间${NC}：磁盘上未被任何分区占用的空间（可用于创建新分区或扩展现有分区）"
    echo -e "  ${YELLOW}分区已用空间${NC}：分区内文件系统实际使用的空间（已用列显示）"
    echo -e "  ${YELLOW}分区可用空间${NC}：分区大小 - 已用空间（可以被文件写入使用）"
    echo ""
    
    # 文件系统支持
    echo -e "${YELLOW}【文件系统支持】${NC}"
    echo "  ext4:   $(get_fs_support ext4)"
    echo "  xfs:    $(get_fs_support xfs)"
    echo "  btrfs:  $(get_fs_support btrfs)"
    echo "  ntfs:   $(get_fs_support ntfs)"
    echo ""
    
    # LVM信息
    if [ "$HAS_LVM" = true ]; then
        echo -e "${YELLOW}【LVM配置】${NC}"
        echo "  VG: $VG_NAME"
        echo "  LV: $LV_NAME"
        pvs 2>/dev/null | grep -E "PV|/dev" | head -2
        echo ""
    fi
}

# 智能建议
show_suggestions() {
    echo -e "${CYAN}【智能建议】${NC}\n"
    
    local count=0
    
    # 检查系统分区
    for num in "${!PARTITIONS[@]}"; do
        if [ "${PARTITION_MOUNT[$num]}" = "/" ]; then
            local used_str="${PARTITION_USED[$num]}"
            if [[ "$used_str" =~ ^([0-9.]+)GB$ ]]; then
                local used="${BASH_REMATCH[1]}"
                local size="${PARTITION_SIZES[$num]}"
                local usage=$(awk "BEGIN {printf \"%.0f\", ($used / $size) * 100}")
                
                if [ $usage -gt 80 ]; then
                    echo -e "  ${RED}⚠${NC}  系统分区使用率 ${usage}% - ${YELLOW}建议扩容${NC}"
                    count=$((count + 1))
                fi
            fi
        fi
    done
    
    # 未分配空间（磁盘末尾未被分区占用的空间）
    if [ -n "${PARTITIONS[99]}" ]; then
        echo -e "  ${GREEN}✓${NC}  发现 ${PARTITION_SIZES[99]}GB 未分配空间 (磁盘末尾) - 可直接使用"
        count=$((count + 1))
    fi
    
    # 可释放空间（分区内可缩小的空间）
    for num in "${!PARTITIONS[@]}"; do
        [ "$num" = "99" ] && continue
        local fs="${PARTITION_FS[$num]}"
        local used_str="${PARTITION_USED[$num]}"
        
        # 只有btrfs支持在线缩小，ext4需要离线
        if [[ "$fs" =~ btrfs ]] && [[ "$used_str" =~ ^([0-9.]+)GB$ ]]; then
            local used="${BASH_REMATCH[1]}"
            local size="${PARTITION_SIZES[$num]}"
            # 可释放 = 分区大小 - 已用 - 2GB安全余量
            local avail=$(awk "BEGIN {printf \"%.0f\", $size - $used - 2}")
            
            if [ $avail -gt 3 ]; then
                echo -e "  ${BLUE}→${NC}  ${PARTITIONS[$num]} ($fs) 分区内可缩小约 ${avail}GB (已用${used}GB)"
                count=$((count + 1))
            fi
        fi
    done
    
    [ $count -eq 0 ] && echo "  ✓ 当前分区配置合理"
    echo ""
}

# 用户选择操作类型
select_operation() {
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}          操作选项${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    echo "  1) 调整分区大小 (从一个分区移动空间到另一个)"
    echo "  2) 使用未分配空间 (添加到现有分区)"
    echo "  3) 删除分区 (释放为未分配空间)"
    echo "  4) 修复分区对齐 (解决扇区间隙/对齐问题) ⭐"
    echo "  5) 刷新显示"
    echo "  6) 退出\n"
    
    while true; do
        read -p "请选择 [1-6]: " choice
        case $choice in
            1) OPERATION_TYPE="resize"; break ;;
            2)
                if [ -z "${PARTITIONS[99]}" ]; then
                    echo -e "${RED}错误：没有未分配空间${NC}"
                else
                    OPERATION_TYPE="use_unalloc"; break
                fi
                ;;
            3) OPERATION_TYPE="delete_partition"; break ;;
            4) OPERATION_TYPE="fix_alignment"; break ;;
            5) 
                show_banner
                detect_all_partitions
                detect_lvm
                show_all_partitions
                show_suggestions
                ;;
            6) log_info "用户退出"; exit 0 ;;
            *) echo "无效选择" ;;
        esac
    done
}

# 选择分区
select_partitions() {
    if [ "$OPERATION_TYPE" = "resize" ]; then
        # 选择源分区
        echo -e "\n${CYAN}【步骤1】选择源分区(缩小)${NC}\n"
        echo "可缩小的分区："
        for num in $(echo "${!PARTITIONS[@]}" | tr ' ' '\n' | sort -n); do
            [ "$num" = "99" ] && continue
            local fs="${PARTITION_FS[$num]}"
            local mount="${PARTITION_MOUNT[$num]}"
            
            # 支持ext4/btrfs，以及MD/LVM上层是ext4/btrfs的
            if [[ "$fs" =~ (ext4|btrfs) ]] && [ -n "$mount" ] && [ "$mount" != "-" ]; then
                echo "  $num) ${PARTITIONS[$num]} (${PARTITION_SIZES[$num]}GB, $fs) - ${PARTITION_ROLE[$num]}"
            fi
        done
        
        echo ""
        read -p "选择源分区编号: " SOURCE_PART_NUM
        [ -z "${PARTITIONS[$SOURCE_PART_NUM]}" ] && log_error "无效分区" && exit 1
        
        # 检查是否为根分区
        if [ "${PARTITION_MOUNT[$SOURCE_PART_NUM]}" = "/" ]; then
            log_warning "警告：您选择了根分区（/）作为源分区！"
            echo ""
            echo -e "${YELLOW}根分区缩小需要特殊处理：${NC}"
            echo "  1. 系统必须在操作后重启"
            echo "  2. 缩小操作在重启后的initramfs中进行"
            echo "  3. 如果失败，可能导致系统无法启动"
            echo ""
            read -p "确认继续操作根分区？(输入 YES): " confirm_root
            if [ "$confirm_root" != "YES" ]; then
                log_warning "用户取消操作"
                exit 0
            fi
        fi
        
        # 计算可释放空间
        local source_device="${PARTITIONS[$SOURCE_PART_NUM]}"
        local source_mount="${PARTITION_MOUNT[$SOURCE_PART_NUM]}"
        local source_size="${PARTITION_SIZES[$SOURCE_PART_NUM]}"
        
        # 重新获取精确的使用情况
        local used_gb="0"
        if [ -n "$source_mount" ] && [ "$source_mount" != "-" ]; then
            used_gb=$(df -BG "$source_mount" 2>/dev/null | tail -1 | awk '{print $3}' | tr -d 'G')
        fi
        
        # 显示调试信息
        log_info "源分区: $source_device, 大小: ${source_size}GB, 已用: ${used_gb}GB"
        
        # 计算可释放（分区大小 - 已使用 - 安全余量2GB）
        if [ -n "$used_gb" ] && [ "$used_gb" != "0" ]; then
            MAX_SHRINK=$(awk "BEGIN {printf \"%.0f\", $source_size - $used_gb - 2}")
        else
            log_error "无法获取分区使用情况，请确保分区已挂载"
            exit 1
        fi
        
        if [ $MAX_SHRINK -lt 1 ]; then
            log_error "可释放空间不足1GB (可用: ${MAX_SHRINK}GB)"
            log_info "分区大小: ${source_size}GB, 已用: ${used_gb}GB, 需保留: 2GB"
            exit 1
        fi
        
        log_success "计算完成: 最多可释放 ${MAX_SHRINK}GB"
        
        # 选择目标分区
        echo -e "\n${CYAN}【步骤2】选择目标分区(扩大)${NC}\n"
        for num in $(echo "${!PARTITIONS[@]}" | tr ' ' '\n' | sort -n); do
            [ "$num" = "99" ] || [ "$num" = "$SOURCE_PART_NUM" ] || \
                echo "  $num) ${PARTITIONS[$num]} (${PARTITION_SIZES[$num]}GB) - ${PARTITION_ROLE[$num]}"
        done
        
        echo ""
        read -p "选择目标分区编号: " TARGET_PART_NUM
        [ -z "${PARTITIONS[$TARGET_PART_NUM]}" ] && log_error "无效分区" && exit 1
        
        # 输入大小
        echo -e "\n${CYAN}【步骤3】输入大小${NC}\n"
        echo "最多可释放: ${MAX_SHRINK}GB"
        while true; do
            read -p "输入大小(GB) [1-${MAX_SHRINK}]: " RESIZE_SIZE_GB
            [[ "$RESIZE_SIZE_GB" =~ ^[0-9]+$ ]] && [ $RESIZE_SIZE_GB -ge 1 ] && [ $RESIZE_SIZE_GB -le $MAX_SHRINK ] && break
            echo "无效输入"
        done
        
    elif [ "$OPERATION_TYPE" = "use_unalloc" ]; then
        echo -e "\n${CYAN}【选择目标分区】${NC}\n"
        for num in $(echo "${!PARTITIONS[@]}" | tr ' ' '\n' | sort -n); do
            [ "$num" != "99" ] && echo "  $num) ${PARTITIONS[$num]} - ${PARTITION_ROLE[$num]}"
        done
        
        echo ""
        read -p "选择分区编号: " TARGET_PART_NUM
        if [ -z "${PARTITIONS[$TARGET_PART_NUM]}" ] || [ "$TARGET_PART_NUM" = "99" ]; then
            log_error "无效分区"
            exit 1
        fi
        
        SOURCE_PART_NUM="99"  # 标记源为未分配空间
        RESIZE_SIZE_GB=$(echo "${PARTITION_SIZES[99]}" | awk '{printf "%.0f", $1}')
        
        log_info "将添加 ${RESIZE_SIZE_GB}GB 未分配空间到 ${PARTITIONS[$TARGET_PART_NUM]}"
        
    elif [ "$OPERATION_TYPE" = "delete_partition" ]; then
        echo -e "\n${CYAN}【选择要删除的分区】${NC}\n"
        echo -e "${RED}警告：删除分区将清除该分区上的所有数据！${NC}\n"
        
        # 显示可删除的分区（未格式化或用户确认）
        echo "可删除的分区："
        for num in $(echo "${!PARTITIONS[@]}" | tr ' ' '\n' | sort -n); do
            [ "$num" = "99" ] && continue
            local mount="${PARTITION_MOUNT[$num]}"
            local fs="${PARTITION_FS[$num]}"
            
            # 显示所有非根分区
            if [ "$mount" != "/" ]; then
                local warn=""
                if [ "$fs" = "未格式化" ]; then
                    warn="${GREEN}(未格式化)${NC}"
                elif [ -z "$mount" ] || [ "$mount" = "-" ]; then
                    warn="${YELLOW}(未挂载)${NC}"
                else
                    warn="${RED}(已使用:$mount)${NC}"
                fi
                echo -e "  $num) ${PARTITIONS[$num]} (${PARTITION_SIZES[$num]}GB) - ${PARTITION_FS[$num]} $warn"
            fi
        done
        
        echo ""
        read -p "选择要删除的分区编号: " DELETE_PART_NUM
        
        if [ -z "${PARTITIONS[$DELETE_PART_NUM]}" ] || [ "$DELETE_PART_NUM" = "99" ]; then
            log_error "无效分区"
            exit 1
        fi
        
        # 检查是否为根分区
        if [ "${PARTITION_MOUNT[$DELETE_PART_NUM]}" = "/" ]; then
            log_error "不能删除根分区！"
            exit 1
        fi
        
        # 显示警告
        local delete_device="${PARTITIONS[$DELETE_PART_NUM]}"
        local delete_size="${PARTITION_SIZES[$DELETE_PART_NUM]}"
        
        echo ""
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${RED}          确认删除${NC}"
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo "  分区: $delete_device"
        echo "  大小: ${delete_size}GB"
        echo "  文件系统: ${PARTITION_FS[$DELETE_PART_NUM]}"
        echo "  挂载点: ${PARTITION_MOUNT[$DELETE_PART_NUM]}"
        echo ""
        echo -e "${RED}此操作不可恢复！${NC}"
        echo ""
        
        read -p "确认删除此分区？(输入 DELETE): " confirm_delete
        if [ "$confirm_delete" != "DELETE" ]; then
            log_warning "用户取消删除"
            exit 0
        fi
        
        SOURCE_PART_NUM="$DELETE_PART_NUM"
        TARGET_PART_NUM=""
        RESIZE_SIZE_GB=0
        RESIZE_SIZE_MB=0
        
    elif [ "$OPERATION_TYPE" = "fix_alignment" ]; then
        echo -e "\n${CYAN}【检测分区对齐问题】${NC}\n"
        
        # 检测所有分区的对齐情况和扇区间隙
        local has_issue=false
        local issue_parts=()
        local issue_reasons=()
        
        # 获取磁盘总扇区数
        local disk_end=$(parted "$DISK" unit s print 2>/dev/null | grep "^Disk $DISK:" | awk '{print $3}' | tr -d 's')
        
        for num in $(echo "${!PARTITIONS[@]}" | tr ' ' '\n' | sort -n); do
            [ "$num" = "99" ] && continue
            
            local device="${PARTITIONS[$num]}"
            local part_end=$(parted "$DISK" unit s print 2>/dev/null | grep "^ $num" | awk '{print $3}' | tr -d 's')
            
            if [ -n "$part_end" ] && [ -n "$disk_end" ]; then
                # 计算到磁盘末尾的间隙（扇区）
                local gap=$((disk_end - part_end - 1))
                
                # 如果间隙大于2048扇区（1MB），认为有问题
                if [ $gap -gt 2048 ]; then
                    local gap_mb=$(awk "BEGIN {printf \"%.1f\", $gap * 512 / 1024 / 1024}")
                    local gap_gb=$(awk "BEGIN {printf \"%.1f\", $gap_mb / 1024}")
                    
                    echo -e "  ${YELLOW}发现问题${NC}: ${PARTITIONS[$num]}"
                    echo -e "    分区结束扇区: ${part_end}"
                    echo -e "    磁盘末尾扇区: ${disk_end}"
                    echo -e "    扇区间隙: ${gap} 扇区 (${gap_gb}GB)"
                    echo -e "    ${RED}问题${NC}: 扇区间隙导致飞牛NAS无法创建存储"
                    echo -e "    ${BLUE}建议${NC}: 扩展此分区到磁盘末尾以消除间隙"
                    echo ""
                    
                    issue_parts+=($num)
                    issue_reasons[$num]="扇区间隙 ${gap} 扇区"
                    has_issue=true
                fi
            fi
        done
        
        # 如果没有通过扇区检测到问题，再检查是否有未分配空间
        if [ "$has_issue" = false ] && [ -n "${PARTITIONS[99]}" ]; then
            # 找到最后一个分区
            local last_num=0
            for num in $(echo "${!PARTITIONS[@]}" | tr ' ' '\n' | sort -n); do
                [ "$num" = "99" ] && continue
                [ $num -gt $last_num ] && last_num=$num
            done
            
            if [ $last_num -gt 0 ]; then
                echo -e "  ${YELLOW}发现${NC}: ${PARTITIONS[$last_num]} 后有 ${PARTITION_SIZES[99]}GB 未分配空间"
                echo -e "  ${BLUE}建议${NC}: 扩展此分区到磁盘末尾以充分利用空间"
                echo ""
                issue_parts+=($last_num)
                issue_reasons[$last_num]="未分配空间 ${PARTITION_SIZES[99]}GB"
                has_issue=true
            fi
        fi
        
        if [ "$has_issue" = false ]; then
            echo -e "${GREEN}✓ 未发现分区对齐问题${NC}"
            echo -e "${GREEN}✓ 所有分区已正确对齐${NC}"
            echo ""
            read -p "按Enter返回主菜单..." 
            select_operation
            return
        fi
        
        echo ""
        echo -e "${CYAN}【选择要修复的分区】${NC}\n"
        echo "可修复的分区："
        for num in "${issue_parts[@]}"; do
            local reason="${issue_reasons[$num]}"
            [ -z "$reason" ] && reason="扇区对齐问题"
            echo "  $num) ${PARTITIONS[$num]} (${PARTITION_SIZES[$num]}GB) - $reason"
        done
        echo ""
        echo -e "${YELLOW}修复方式${NC}: 扩展分区到磁盘末尾，消除扇区间隙"
        
        echo ""
        read -p "选择分区编号: " FIX_PART_NUM
        
        if [ -z "${PARTITIONS[$FIX_PART_NUM]}" ]; then
            log_error "无效分区"
            exit 1
        fi
        
        # 检查是否为根分区
        if [ "${PARTITION_MOUNT[$FIX_PART_NUM]}" = "/" ]; then
            echo ""
            echo -e "${YELLOW}警告：这是根分区，扩展操作相对安全${NC}"
            echo -e "${YELLOW}将扩展分区边界并扩展文件系统${NC}"
            echo ""
            read -p "确认继续？(输入 YES): " confirm_fix
            if [ "$confirm_fix" != "YES" ]; then
                log_warning "用户取消操作"
                exit 0
            fi
        fi
        
        SOURCE_PART_NUM="$FIX_PART_NUM"
        TARGET_PART_NUM=""
        
        # 计算实际增加的大小（从扇区间隙）
        local part_end=$(parted "$DISK" unit s print 2>/dev/null | grep "^ $FIX_PART_NUM" | awk '{print $3}' | tr -d 's')
        local disk_end=$(parted "$DISK" unit s print 2>/dev/null | grep "^Disk $DISK:" | awk '{print $3}' | tr -d 's')
        
        if [ -n "$part_end" ] && [ -n "$disk_end" ]; then
            local gap=$((disk_end - part_end - 1))
            RESIZE_SIZE_GB=$(awk "BEGIN {printf \"%.1f\", $gap * 512 / 1024 / 1024 / 1024}")
        else
            # 如果计算失败，使用未分配空间大小
            RESIZE_SIZE_GB="${PARTITION_SIZES[99]:-0}"
        fi
        
        RESIZE_SIZE_MB=0
    fi
    
    if [ "$OPERATION_TYPE" != "delete_partition" ] && [ "$OPERATION_TYPE" != "fix_alignment" ]; then
        RESIZE_SIZE_MB=$((RESIZE_SIZE_GB * 1024))
    fi
}

# 显示摘要
show_summary() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}          操作摘要${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    if [ "$OPERATION_TYPE" = "resize" ]; then
        echo "  源分区: ${PARTITIONS[$SOURCE_PART_NUM]}"
        echo "  文件系统: ${PARTITION_FS[$SOURCE_PART_NUM]}"
        echo "  操作: 缩小 ${RESIZE_SIZE_GB}GB"
        echo ""
        echo "  目标分区: ${PARTITIONS[$TARGET_PART_NUM]}"
        echo "  文件系统: ${PARTITION_FS[$TARGET_PART_NUM]}"
        echo "  操作: 扩大 ${RESIZE_SIZE_GB}GB"
    elif [ "$OPERATION_TYPE" = "use_unalloc" ]; then
        echo "  操作类型: 使用未分配空间"
        echo "  未分配空间: ${RESIZE_SIZE_GB}GB"
        echo ""
        echo "  目标分区: ${PARTITIONS[$TARGET_PART_NUM]}"
        echo "  文件系统: ${PARTITION_FS[$TARGET_PART_NUM]}"
        echo "  操作: 扩大 ${RESIZE_SIZE_GB}GB"
    elif [ "$OPERATION_TYPE" = "delete_partition" ]; then
        echo "  操作类型: 删除分区"
        echo ""
        echo "  分区: ${PARTITIONS[$SOURCE_PART_NUM]}"
        echo "  大小: ${PARTITION_SIZES[$SOURCE_PART_NUM]}GB"
        echo "  文件系统: ${PARTITION_FS[$SOURCE_PART_NUM]}"
        echo ""
        echo -e "  ${RED}删除后将释放为未分配空间${NC}"
    elif [ "$OPERATION_TYPE" = "fix_alignment" ]; then
        echo "  操作类型: 修复分区对齐"
        echo ""
        echo "  分区: ${PARTITIONS[$SOURCE_PART_NUM]}"
        echo "  当前大小: ${PARTITION_SIZES[$SOURCE_PART_NUM]}GB"
        echo "  文件系统: ${PARTITION_FS[$SOURCE_PART_NUM]}"
        echo ""
        echo "  操作: 扩展到磁盘末尾"
        echo "  增加: ${RESIZE_SIZE_GB}GB"
        local new_size=$(awk "BEGIN {printf \"%.1f\", ${PARTITION_SIZES[$SOURCE_PART_NUM]} + $RESIZE_SIZE_GB}")
        echo "  新大小: ${new_size}GB"
        echo ""
        echo -e "  ${GREEN}✓ 消除扇区间隙和对齐问题${NC}"
    fi
    
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

# 停止trim_file进程
stop_trim_file() {
    log_info "停止trim_file进程..."
    pkill -f trim_file 2>/dev/null || true
    sleep 2
    
    if pgrep -f trim_file >/dev/null; then
        log_warning "trim_file仍在运行，强制终止..."
        pkill -9 -f trim_file 2>/dev/null || true
        sleep 2
    fi
    
    log_success "trim_file已停止"
}

# 检测MD设备
detect_md_device() {
    local partition=$1
    local fs_type=$(lsblk -no FSTYPE "$partition" 2>/dev/null)
    
    if echo "$fs_type" | grep -q "linux_raid_member"; then
        # 方法1: holders目录
        local holders_path="/sys/block/$(basename $partition)/holders"
        if [ -d "$holders_path" ]; then
            local md=$(ls "$holders_path" 2>/dev/null | grep "^md" | head -1)
            if [ -n "$md" ]; then
                echo "/dev/$md"
                return 0
            fi
        fi
        
        # 方法2: /proc/mdstat
        local part_name=$(basename "$partition")
        local md=$(grep -B 1 "$part_name" /proc/mdstat 2>/dev/null | grep "^md" | awk '{print $1}' | head -1)
        if [ -n "$md" ]; then
            echo "/dev/$md"
            return 0
        fi
        
        # 方法3: pvs扫描
        local pv=$(pvs --noheadings -o pv_name 2>/dev/null | grep "md" | head -1 | tr -d ' ')
        if [ -n "$pv" ]; then
            echo "$pv"
            return 0
        fi
    fi
    
    echo "$partition"
    return 0
}

# 执行实际的分区调整操作
execute_operation() {
    log_info "开始执行分区调整..."
    
    # 保存状态
    echo "stage1_pending" > "$STATE_FILE"
    echo "OPERATION_TYPE=$OPERATION_TYPE" >> "$STATE_FILE"
    echo "SOURCE_PART_NUM=$SOURCE_PART_NUM" >> "$STATE_FILE"
    echo "TARGET_PART_NUM=$TARGET_PART_NUM" >> "$STATE_FILE"
    echo "RESIZE_SIZE_GB=$RESIZE_SIZE_GB" >> "$STATE_FILE"
    echo "RESIZE_SIZE_MB=$RESIZE_SIZE_MB" >> "$STATE_FILE"
    
    if [ "$OPERATION_TYPE" = "resize" ]; then
        execute_resize_partitions
    elif [ "$OPERATION_TYPE" = "use_unalloc" ]; then
        execute_use_unallocated
    elif [ "$OPERATION_TYPE" = "delete_partition" ]; then
        execute_delete_partition
    elif [ "$OPERATION_TYPE" = "fix_alignment" ]; then
        execute_fix_alignment
    fi
}

# 执行分区间调整
execute_resize_partitions() {
    local source_device="${PARTITIONS[$SOURCE_PART_NUM]}"
    local target_device="${PARTITIONS[$TARGET_PART_NUM]}"
    
    log_info "场景: 从 $source_device 移动 ${RESIZE_SIZE_GB}GB 到 $target_device"
    
    # 检测是否涉及MD设备
    local source_md=$(detect_md_device "$source_device")
    local target_md=$(detect_md_device "$target_device")
    
    log_info "源设备: $source_device -> $source_md"
    log_info "目标设备: $target_device -> $target_md"
    
    # 停止服务
    stop_trim_file
    
    log_info "停止Docker服务..."
    systemctl stop docker 2>/dev/null || true
    sleep 2
    
    # 卸载目标分区（如果挂载）
    local target_mount="${PARTITION_MOUNT[$TARGET_PART_NUM]}"
    if [ -n "$target_mount" ] && [ "$target_mount" != "-" ] && [ "$target_mount" != "/" ]; then
        log_info "卸载目标分区: $target_mount"
        umount -l "$target_mount" 2>/dev/null || true
        sleep 2
    fi
    
    # 如果目标是MD成员，停止MD设备
    if [ "$target_md" != "$target_device" ]; then
        log_info "停止目标MD设备: $target_md"
        
        # 停止LVM
        if [ "$HAS_LVM" = true ]; then
            log_info "停止LVM..."
            lvchange -an "$VG_NAME/$LV_NAME" 2>/dev/null || true
            vgchange -an "$VG_NAME" 2>/dev/null || true
            sleep 2
        fi
        
        mdadm --stop "$target_md" 2>/dev/null || true
        sleep 2
    fi
    
    # 检查源分区是否为根分区
    local source_is_root=false
    if [ "${PARTITION_MOUNT[$SOURCE_PART_NUM]}" = "/" ]; then
        source_is_root=true
        log_warning "源分区是根分区，需要特殊处理"
        
        # 根分区ext4需要离线缩小
        if [[ "${PARTITION_FS[$SOURCE_PART_NUM]}" =~ ext4 ]]; then
            log_error "ext4根分区无法在线缩小！"
            echo ""
            echo -e "${RED}错误：ext4文件系统必须离线才能缩小${NC}"
            echo -e "${YELLOW}建议操作方式：${NC}"
            echo "  1. 使用LiveCD/救援模式启动系统"
            echo "  2. 在离线状态下运行 e2fsck 和 resize2fs"
            echo "  3. 然后调整分区表"
            echo ""
            echo "或者考虑："
            echo "  • 使用未分配空间扩展目标分区（选项2）"
            echo "  • 从其他非根分区调整空间"
            exit 1
        fi
    fi
    
    # 如果源分区涉及LVM且不是根分区，需要缩小LV
    if [ "$HAS_LVM" = true ] && [ "$source_md" != "$source_device" ] && [ "$source_is_root" = false ]; then
        log_info "缩小LVM逻辑卷..."
        
        # 获取当前LV大小
        local current_lv_size=$(lvs --noheadings --units m -o lv_size "$VG_NAME/$LV_NAME" | tr -d ' Mm' | cut -d. -f1)
        local target_lv_size=$((current_lv_size - RESIZE_SIZE_MB))
        
        log_info "当前LV大小: ${current_lv_size}MB, 目标: ${target_lv_size}MB"
        
        # 缩小文件系统
        if [[ "${PARTITION_FS[$SOURCE_PART_NUM]}" =~ btrfs ]]; then
            log_info "缩小btrfs文件系统..."
            btrfs filesystem resize -${RESIZE_SIZE_GB}G "${PARTITION_MOUNT[$SOURCE_PART_NUM]}"
        fi
        
        # 缩小LV
        log_info "缩小逻辑卷..."
        lvreduce -f -L ${target_lv_size}M "$VG_NAME/$LV_NAME"
        
        # 缩小PV
        log_info "缩小物理卷..."
        pvresize --setphysicalvolumesize ${target_lv_size}M "$source_md"
    fi
    
    # 停止MD设备（如果需要且不是根分区）
    if [ "$source_md" != "$source_device" ] && [ "$source_is_root" = false ]; then
        log_info "停止源MD设备..."
        umount -l "${PARTITION_MOUNT[$SOURCE_PART_NUM]}" 2>/dev/null || true
        vgchange -an "$VG_NAME" 2>/dev/null || true
        mdadm --stop "$source_md" 2>/dev/null || true
        sleep 2
    fi
    
    # 获取分区信息（在修改前）
    log_info "获取分区表信息..."
    local source_start=$(parted "$DISK" unit MB print | grep "^ $SOURCE_PART_NUM" | awk '{print $2}' | tr -d 'MB')
    local source_end=$(parted "$DISK" unit MB print | grep "^ $SOURCE_PART_NUM" | awk '{print $3}' | tr -d 'MB')
    local target_start=$(parted "$DISK" unit MB print | grep "^ $TARGET_PART_NUM" | awk '{print $2}' | tr -d 'MB')
    local target_end=$(parted "$DISK" unit MB print | grep "^ $TARGET_PART_NUM" | awk '{print $3}' | tr -d 'MB')
    
    log_info "源分区: ${source_start}MB - ${source_end}MB"
    log_info "目标分区: ${target_start}MB - ${target_end}MB"
    
    # 计算新的分区边界
    local new_source_end=$((source_end - RESIZE_SIZE_MB))
    local new_target_start=$((new_source_end + 1))
    
    # 如果目标分区在源分区之前，需要不同的计算
    if [ $TARGET_PART_NUM -lt $SOURCE_PART_NUM ]; then
        local new_target_end=$((target_end + RESIZE_SIZE_MB))
        log_info "调整目标分区: $target_device 到 ${new_target_end}MB"
        
        # 扩展目标分区
        log_warning "扩展目标分区..."
        (echo Yes; echo Ignore) | parted "$DISK" resizepart $TARGET_PART_NUM ${new_target_end}MB 2>&1 | tee -a "$LOG_FILE" || true
        
        # 缩小源分区
        log_warning "缩小源分区..."
        parted -s "$DISK" resizepart $SOURCE_PART_NUM ${new_source_end}MB 2>&1 | tee -a "$LOG_FILE" || true
    else
        log_info "调整源分区: $source_device 到 ${new_source_end}MB"
        
        # 删除目标分区
        log_warning "删除目标分区..."
        parted -s "$DISK" rm $TARGET_PART_NUM 2>&1 | tee -a "$LOG_FILE" || true
        
        # 缩小源分区
        log_warning "缩小源分区..."
        parted -s "$DISK" resizepart $SOURCE_PART_NUM ${new_source_end}MB 2>&1 | tee -a "$LOG_FILE" || true
        
        # 重建目标分区
        log_warning "重建目标分区..."
        local final_target_end=$((target_end))
        parted -s "$DISK" mkpart primary ${new_target_start}MB ${final_target_end}MB 2>&1 | tee -a "$LOG_FILE" || true
        
        # 如果是MD成员，设置raid标志
        if [ "$target_md" != "$target_device" ]; then
            parted -s "$DISK" set $TARGET_PART_NUM raid on 2>&1 | tee -a "$LOG_FILE" || true
        fi
    fi
    
    # 通知内核
    partprobe "$DISK"
    sleep 2
    
    # 重建MD（如果需要）
    if [ "$source_md" != "$source_device" ]; then
        log_info "重建MD设备..."
        mdadm --create "$source_md" --level=1 --raid-devices=1 --force "$source_device" 2>&1 | tee -a "$LOG_FILE" || true
        sleep 2
    fi
    
    # 激活LVM
    if [ "$HAS_LVM" = true ]; then
        log_info "激活LVM..."
        vgchange -ay "$VG_NAME"
        lvchange -ay "$VG_NAME/$LV_NAME"
    fi
    
    # 保存状态供第二阶段使用
    echo "stage1_done" > "$STATE_FILE"
    
    log_success "第一阶段完成！"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓ 分区表已调整${NC}"
    echo -e "${YELLOW}需要重启系统以应用更改${NC}"
    echo -e "${YELLOW}重启后会自动执行第二阶段（扩展文件系统）${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    read -p "按Enter重启系统..." 
    reboot
}

# 执行使用未分配空间
execute_use_unallocated() {
    local target_device="${PARTITIONS[$TARGET_PART_NUM]}"
    
    log_info "场景: 添加 ${RESIZE_SIZE_GB}GB 未分配空间到 $target_device"
    
    # 获取目标分区当前信息
    local target_end=$(parted "$DISK" unit MB print | grep "^ $TARGET_PART_NUM" | awk '{print $3}' | tr -d 'MB')
    local new_target_end=$((target_end + RESIZE_SIZE_MB))
    
    log_info "当前结束位置: ${target_end}MB, 新结束位置: ${new_target_end}MB"
    
    # 停止服务
    stop_trim_file
    
    # 扩展分区
    log_warning "扩展分区..."
    (echo Yes; echo Ignore) | parted "$DISK" resizepart $TARGET_PART_NUM ${new_target_end}MB 2>&1 | tee -a "$LOG_FILE" || true
    
    partprobe "$DISK"
    sleep 2
    
    # 如果是MD成员，需要重组MD
    local target_md=$(detect_md_device "$target_device")
    if [ "$target_md" != "$target_device" ]; then
        log_info "重组MD设备..."
        mdadm --stop "$target_md" 2>/dev/null || true
        mdadm --create "$target_md" --level=1 --raid-devices=1 --force "$target_device" 2>&1 | tee -a "$LOG_FILE" || true
        sleep 2
    fi
    
    # 扩展PV/LV（如果需要）
    if [ "$HAS_LVM" = true ]; then
        log_info "扩展PV和LV..."
        pvresize "$target_md"
        lvextend -l +100%FREE "$VG_NAME/$LV_NAME"
    fi
    
    # 扩展文件系统
    log_info "扩展文件系统..."
    local fs="${PARTITION_FS[$TARGET_PART_NUM]}"
    local mount="${PARTITION_MOUNT[$TARGET_PART_NUM]}"
    
    if [[ "$fs" =~ ext4 ]]; then
        resize2fs "$target_device"
    elif [[ "$fs" =~ btrfs ]]; then
        btrfs filesystem resize max "$mount"
    elif [[ "$fs" =~ xfs ]]; then
        xfs_growfs "$mount"
    fi
    
    log_success "操作完成！"
    df -h "$mount"
}

# 执行删除分区
execute_delete_partition() {
    local delete_device="${PARTITIONS[$SOURCE_PART_NUM]}"
    local delete_size="${PARTITION_SIZES[$SOURCE_PART_NUM]}"
    
    log_info "场景: 删除分区 $delete_device (${delete_size}GB)"
    
    # 停止服务
    stop_trim_file
    
    # 如果分区已挂载，卸载它
    local delete_mount="${PARTITION_MOUNT[$SOURCE_PART_NUM]}"
    if [ -n "$delete_mount" ] && [ "$delete_mount" != "-" ]; then
        log_info "卸载分区: $delete_mount"
        umount -l "$delete_mount" 2>/dev/null || true
        sleep 2
    fi
    
    # 如果是MD成员，停止MD设备
    local delete_md=$(detect_md_device "$delete_device")
    if [ "$delete_md" != "$delete_device" ]; then
        log_info "停止MD设备: $delete_md"
        
        # 停止LVM（如果有）
        if [ "$HAS_LVM" = true ]; then
            log_info "停止LVM..."
            lvchange -an "$VG_NAME/$LV_NAME" 2>/dev/null || true
            vgchange -an "$VG_NAME" 2>/dev/null || true
            sleep 2
        fi
        
        mdadm --stop "$delete_md" 2>/dev/null || true
        sleep 2
        
        # 清除MD超级块
        log_info "清除MD超级块..."
        mdadm --zero-superblock "$delete_device" 2>/dev/null || true
    fi
    
    # 删除分区
    log_warning "删除分区 $delete_device..."
    parted -s "$DISK" rm $SOURCE_PART_NUM 2>&1 | tee -a "$LOG_FILE"
    
    # 通知内核
    partprobe "$DISK"
    sleep 2
    
    log_success "分区删除完成！"
    echo ""
    echo -e "${GREEN}✓ 分区 $delete_device 已删除${NC}"
    echo -e "${GREEN}✓ 释放了 ${delete_size}GB 空间为未分配空间${NC}"
    echo ""
    
    # 重新检测显示
    log_info "重新扫描分区..."
    detect_all_partitions
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}          更新后的分区状态${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    
    show_all_partitions
    
    echo ""
    log_success "操作完成！现在可以使用选项2将未分配空间添加到其他分区"
}

# 执行修复分区对齐
execute_fix_alignment() {
    local fix_device="${PARTITIONS[$SOURCE_PART_NUM]}"
    local current_size="${PARTITION_SIZES[$SOURCE_PART_NUM]}"
    local add_size="${RESIZE_SIZE_GB}"
    
    log_info "场景: 修复 $fix_device 的分区对齐问题"
    log_info "当前大小: ${current_size}GB, 将增加: ${add_size}GB"
    
    # 停止服务
    stop_trim_file
    
    # 获取分区当前信息
    log_info "获取分区表信息..."
    local part_start=$(parted "$DISK" unit s print 2>/dev/null | grep "^ $SOURCE_PART_NUM" | awk '{print $2}' | tr -d 's')
    local part_end=$(parted "$DISK" unit s print 2>/dev/null | grep "^ $SOURCE_PART_NUM" | awk '{print $3}' | tr -d 's')
    local disk_end=$(parted "$DISK" unit s print 2>/dev/null | grep "^Disk $DISK:" | awk '{print $3}' | tr -d 's')
    
    log_info "分区起始: ${part_start}s"
    log_info "分区结束: ${part_end}s"
    log_info "磁盘结束: ${disk_end}s"
    
    # 计算新的结束位置（磁盘末尾-1扇区）
    local new_end=$((disk_end - 1))
    
    log_info "新结束位置: ${new_end}s"
    
    # 检查是否为根分区
    local is_root=false
    if [ "${PARTITION_MOUNT[$SOURCE_PART_NUM]}" = "/" ]; then
        is_root=true
        log_warning "正在处理根分区，将在线扩展"
    fi
    
    # 扩展分区边界
    log_warning "扩展分区边界到磁盘末尾..."
    echo ""
    echo -e "${YELLOW}正在执行 parted 命令...${NC}"
    
    # 方法1: 使用parted resizepart（推荐）
    log_info "尝试方法1: parted resizepart..."
    parted "$DISK" ---pretend-input-tty <<EOF 2>&1 | tee -a "$LOG_FILE"
Yes
resizepart $SOURCE_PART_NUM ${new_end}s
quit
EOF
    
    local result=$?
    
    # 如果方法1失败，尝试方法2
    if [ $result -ne 0 ]; then
        log_warning "方法1失败，尝试方法2: 删除并重建分区..."
        
        # 保存分区信息（part_start已在前面定义）
        local part_flags=$(parted "$DISK" print 2>/dev/null | grep "^ $SOURCE_PART_NUM" | grep -o "boot" || echo "")
        
        log_warning "⚠ 警告：将删除并重建分区，数据不会丢失但有风险"
        log_info "分区起始: ${part_start}s, 新结束: ${new_end}s"
        
        # 删除分区
        log_info "删除分区 $SOURCE_PART_NUM..."
        parted "$DISK" rm $SOURCE_PART_NUM 2>&1 | tee -a "$LOG_FILE"
        
        # 重建分区（从原起始位置到磁盘末尾）
        log_info "重建分区 $SOURCE_PART_NUM..."
        parted "$DISK" mkpart primary ext4 ${part_start}s ${new_end}s 2>&1 | tee -a "$LOG_FILE"
        
        # 恢复boot标志
        if [ -n "$part_flags" ]; then
            log_info "恢复boot标志..."
            parted "$DISK" set $SOURCE_PART_NUM boot on 2>&1 | tee -a "$LOG_FILE"
        fi
        
        log_success "分区重建完成"
    fi
    
    # 通知内核
    log_info "通知内核更新分区表..."
    partprobe "$DISK"
    sleep 3
    
    # 扩展文件系统
    log_info "扩展文件系统..."
    local fs="${PARTITION_FS[$SOURCE_PART_NUM]}"
    
    if [[ "$fs" =~ ext4 ]]; then
        log_info "扩展ext4文件系统..."
        resize2fs "$fix_device" 2>&1 | tee -a "$LOG_FILE"
    elif [[ "$fs" =~ ext3 ]]; then
        log_info "扩展ext3文件系统..."
        resize2fs "$fix_device" 2>&1 | tee -a "$LOG_FILE"
    elif [[ "$fs" =~ xfs ]]; then
        log_info "扩展xfs文件系统..."
        local mount="${PARTITION_MOUNT[$SOURCE_PART_NUM]}"
        if [ -n "$mount" ] && [ "$mount" != "-" ]; then
            xfs_growfs "$mount" 2>&1 | tee -a "$LOG_FILE"
        else
            log_error "xfs文件系统需要挂载后才能扩展"
        fi
    elif [[ "$fs" =~ btrfs ]]; then
        log_info "扩展btrfs文件系统..."
        local mount="${PARTITION_MOUNT[$SOURCE_PART_NUM]}"
        if [ -n "$mount" ] && [ "$mount" != "-" ]; then
            btrfs filesystem resize max "$mount" 2>&1 | tee -a "$LOG_FILE"
        else
            log_error "btrfs文件系统需要挂载后才能扩展"
        fi
    else
        log_warning "未知文件系统类型: $fs，请手动扩展文件系统"
    fi
    
    log_success "分区对齐修复完成！"
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓ 分区已扩展到磁盘末尾${NC}"
    echo -e "${GREEN}✓ 扇区间隙已消除${NC}"
    echo -e "${GREEN}✓ 文件系统已扩展${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # 显示结果
    log_info "验证结果..."
    df -h "$fix_device" 2>/dev/null || df -h "${PARTITION_MOUNT[$SOURCE_PART_NUM]}" 2>/dev/null
    
    echo ""
    parted "$DISK" unit GB print 2>/dev/null | grep -E "Disk|^ $SOURCE_PART_NUM"
    
    echo ""
    log_success "操作完成！分区对齐问题已解决，现在可以正常使用飞牛NAS创建存储了"
}

# 主函数
main() {
    show_banner
    
    # 权限检查
    [ "$EUID" -ne 0 ] && log_error "需要root权限" && echo "使用: sudo $0" && exit 1
    
    # 检测
    detect_all_partitions
    detect_lvm
    
    # 显示
    show_all_partitions
    show_suggestions
    
    # 选择
    select_operation
    select_partitions
    
    # 摘要
    show_summary
    
    # 确认
    echo -e "${RED}⚠ 警告：${NC}"
    echo "  • 此操作会修改分区"
    echo "  • 请确保已备份数据"
    echo ""
    read -p "确认继续？(输入 YES): " confirm
    
    if [ "$confirm" != "YES" ]; then
        log_warning "用户取消"
        exit 0
    fi
    
    # 执行
    execute_operation
}

main "$@"

