# 飞牛OS存储空间扩容完整指南

## 📋 目录
- [背景说明](#背景说明)
- [适用环境](#适用环境)
- [前置条件](#前置条件)
- [操作步骤](#操作步骤)
- [自动化脚本使用](#自动化脚本使用)
- [手动操作步骤](#手动操作步骤)
- [验证扩容结果](#验证扩容结果)
- [故障排除](#故障排除)
- [常见问题](#常见问题)
- [安全建议](#安全建议)

## 🔍 背景说明

### 问题描述
在ESXi虚拟化环境中运行飞牛OS时，当我们在ESXi管理界面中扩容虚拟磁盘后，飞牛OS系统能够识别到扩容后的磁盘大小，但存储空间的可用容量仍然显示为扩容前的大小。

### 原因分析
这是因为飞牛OS使用了LVM（逻辑卷管理）来管理存储空间，磁盘扩容后需要依次进行以下操作：
1. **分区扩展** - 扩展磁盘分区以使用新增的磁盘空间
2. **物理卷扩展** - 扩展LVM物理卷(PV)
3. **逻辑卷扩展** - 扩展LVM逻辑卷(LV)
4. **文件系统扩容** - 调整文件系统大小以使用新增空间

### 存储架构
```
ESXi虚拟磁盘 → 磁盘分区 → LVM物理卷(PV) → LVM卷组(VG) → LVM逻辑卷(LV) → 文件系统 → 飞牛OS存储空间
```

## 🖥️ 适用环境

- **虚拟化平台**: VMware ESXi 6.0+
- **操作系统**: 飞牛OS (fnOS) 各版本
- **存储配置**: 使用LVM管理的存储空间
- **文件系统**: 支持btrfs、ext4、ext3、xfs等

## ✅ 前置条件

### 必要条件
1. **ESXi中已完成磁盘扩容** - 确保虚拟磁盘已在ESXi管理界面中扩容
2. **Root权限** - 需要管理员权限执行系统级操作
3. **SSH访问** - 能够通过SSH连接到飞牛OS系统
4. **系统备份** - 强烈建议创建虚拟机快照或完整备份

### 检查清单
- [ ] 已在ESXi中扩容虚拟磁盘
- [ ] 已创建虚拟机快照
- [ ] 确认SSH连接正常
- [ ] 确认具有root权限
- [ ] 确认存储空间当前工作正常

## 🚀 操作步骤

### 方案一：自动化脚本（推荐）

#### 1. 获取脚本
```bash
# 方法一：从GitHub克隆项目
git clone https://github.com/3377/fnos_storage_expand.git
cd fnos_storage_expand

# 方法二：直接下载脚本文件
wget https://raw.githubusercontent.com/3377/fnos_storage_expand/main/fnos_storage_expand.sh

# 方法三：使用scp上传（在本地执行）
scp fnos_storage_expand.sh root@your-fnos-ip:/root/

# 设置执行权限
chmod +x fnos_storage_expand.sh
```

#### 2. 预检查（可选但推荐）
```bash
# 执行干运行模式，仅检测配置不执行实际操作
sudo ./fnos_storage_expand.sh --dry-run
```

#### 3. 执行扩容
```bash
# 方法一：交互式菜单（推荐）
sudo ./fnos_storage_expand.sh

# 方法二：直接执行扩容
sudo ./fnos_storage_expand.sh --menu
# 然后选择选项1进行扩容

# 方法三：命令行模式
sudo ./fnos_storage_expand.sh --backup create  # 先创建备份
# 然后执行扩容...
```

#### 4. 脚本执行流程
脚本将自动执行以下步骤：
1. **环境检测** - 检查系统环境和必要工具
2. **存储配置检测** - 自动识别存储设备和LVM配置
3. **备份配置** - 备份分区表、LVM配置等关键信息
4. **扩展分区** - 删除并重建分区以使用全部磁盘空间
5. **LVM扩容** - 扩展物理卷和逻辑卷
6. **文件系统扩容** - 根据文件系统类型进行相应扩容
7. **验证结果** - 检查扩容是否成功
8. **生成报告** - 创建详细的操作报告

### 方案二：手动操作

如果自动化脚本无法满足需求，可以按照以下步骤手动操作：

#### 1. 环境准备
```bash
# 切换到root用户
sudo su -

# 查看当前磁盘状态
lsblk
df -h
```

#### 2. 检测存储配置
```bash
# 查看存储空间挂载信息
mount | grep vol

# 查看LVM配置
pvdisplay
vgdisplay  
lvdisplay

# 查看磁盘分区
fdisk -l
```

#### 3. 备份关键配置
```bash
# 创建备份目录
BACKUP_DIR="/tmp/fnos_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

# 备份分区表（假设设备为/dev/sdb）
sfdisk -d /dev/sdb > "$BACKUP_DIR/partition_table.backup"

# 备份LVM配置（假设VG名为trim_xxx）
vgcfgbackup trim_xxx -f "$BACKUP_DIR/lvm_backup"

# 备份fstab
cp /etc/fstab "$BACKUP_DIR/fstab.backup"
```

#### 4. 扩展分区
```bash
# 使用fdisk扩展分区（以/dev/sdb1为例）
fdisk /dev/sdb

# 在fdisk中执行以下命令：
# d    - 删除分区
# 1    - 选择分区号1
# n    - 新建分区  
# p    - 主分区
# 1    - 分区号1
# 回车  - 使用默认起始扇区
# 回车  - 使用默认结束扇区（磁盘末尾）
# t    - 修改分区类型
# 1    - 选择分区号1
# 8e   - LVM类型
# w    - 写入并退出

# 通知内核重新读取分区表
partprobe /dev/sdb
```

#### 5. LVM扩容
```bash
# 扩展物理卷
pvresize /dev/sdb1

# 扩展逻辑卷（使用所有可用空间）
lvresize -l +100%FREE /dev/trim_xxx/0

# 查看扩容结果
pvdisplay
vgdisplay
lvdisplay
```

#### 6. 文件系统扩容
根据文件系统类型选择相应命令：

**btrfs文件系统：**
```bash
btrfs filesystem resize max /vol1
```

**ext4/ext3/ext2文件系统：**
```bash
resize2fs /dev/mapper/trim_xxx-0
```

**xfs文件系统：**
```bash
xfs_growfs /vol1
```

## ✅ 验证扩容结果

### 1. 检查磁盘使用情况
```bash
# 查看存储空间大小
df -h /vol1

# 查看LVM状态
pvdisplay
vgdisplay
lvdisplay
```

### 2. 检查飞牛OS管理界面
1. 登录飞牛OS Web管理界面
2. 进入存储管理页面
3. 确认存储空间大小是否正确显示

### 3. 功能测试
```bash
# 测试文件创建和删除
touch /vol1/test_file
rm /vol1/test_file

# 检查文件系统完整性（可选）
# 注意：以下命令可能需要卸载文件系统，请谨慎使用
# fsck /dev/mapper/trim_xxx-0
```

## 🔧 故障排除

### 常见错误及解决方案

#### 1. 分区扩展失败
**错误现象：** fdisk操作失败或分区表损坏，分区类型错误
**解决方案：**
```bash
# 检查分区表类型
fdisk -l /dev/sdb

# 对于GPT分区表，确保使用正确的分区类型
# GPT: 类型31 (Linux LVM)
# MBR: 类型8e (Linux LVM)

# 恢复分区表
sfdisk /dev/sdb < /tmp/fnos_backup_xxx/partition_table.backup

# 重新启动系统
reboot
```

#### 2. LVM扩容失败
**错误现象：** pvresize或lvresize命令失败，提示"Volume group not found"
**解决方案：**
```bash
# 检查LVM状态
vgscan
pvscan
lvscan

# 激活卷组
vgchange -ay

# 检查逻辑卷路径
ls -la /dev/mapper/
ls -la /dev/trim_*/

# 使用正确的逻辑卷路径重新尝试扩容
pvresize /dev/sdb1
# 使用完整路径，例如：
lvresize -l +100%FREE /dev/trim_xxx/0
# 或者使用mapper路径：
lvresize -l +100%FREE /dev/mapper/trim_xxx-0
```

#### 3. 文件系统扩容失败
**错误现象：** 文件系统扩容命令失败
**解决方案：**
```bash
# 检查文件系统
fsck -f /dev/mapper/trim_xxx-0

# 重新挂载
umount /vol1
mount /dev/mapper/trim_xxx-0 /vol1

# 重新尝试扩容
btrfs filesystem resize max /vol1
```

#### 4. 系统无法启动
**错误现象：** 扩容后系统无法正常启动
**解决方案：**
1. 在ESXi中恢复虚拟机快照
2. 或使用救援模式修复系统
3. 恢复备份的配置文件

### 紧急恢复步骤

如果扩容过程中出现严重问题：

#### 1. 立即停止操作
```bash
# 停止所有正在进行的操作
# 不要强制重启系统
```

#### 2. 恢复备份配置
```bash
# 恢复分区表
sfdisk /dev/sdb < "$BACKUP_DIR/partition_table.backup"

# 恢复LVM配置
vgcfgrestore trim_xxx -f "$BACKUP_DIR/lvm_backup"

# 恢复fstab
cp "$BACKUP_DIR/fstab.backup" /etc/fstab
```

#### 3. 重启系统
```bash
reboot
```

## ❓ 常见问题

### Q1: 扩容后飞牛OS界面仍显示原来的大小？
**A:** 这是正常现象，可能需要：
- 重启飞牛OS服务：`systemctl restart fnos`
- 重启系统：`reboot`
- 清除浏览器缓存并重新登录

### Q2: 可以在不停机的情况下扩容吗？
**A:** 理论上可以，但强烈建议：
- 在维护窗口期间进行
- 提前创建虚拟机快照
- 确保有完整的数据备份

### Q3: 扩容过程中数据会丢失吗？
**A:** 正常情况下不会，但存在风险：
- 分区操作有一定风险
- 建议提前备份重要数据
- 创建虚拟机快照作为保险

### Q4: 支持哪些文件系统？
**A:** 脚本支持以下文件系统：
- btrfs（飞牛OS默认）
- ext4/ext3/ext2
- xfs
- 其他文件系统需要手动操作

### Q5: 可以扩容多次吗？
**A:** 可以，每次ESXi扩容后都可以使用此方法：
- 确保每次扩容前创建快照
- 建议单次扩容不要过大
- 验证上次扩容成功后再进行下次扩容

### Q6: 脚本执行失败怎么办？
**A:** 按以下步骤排查：
1. 检查是否有root权限：`sudo whoami`
2. 检查磁盘是否已在ESXi中扩容：`lsblk`
3. 查看详细错误日志：`tail -f /var/log/fnos_storage_expand_*.log`
4. 使用干运行模式检测：`sudo ./fnos_storage_expand.sh --dry-run`
5. 检查LVM状态：`pvdisplay && vgdisplay && lvdisplay`
6. 验证分区表类型：`fdisk -l /dev/sdb`（替换为实际设备）

### Q7: 如何回滚扩容操作？
**A:** 使用集成的备份恢复功能：
```bash
# 列出可用备份
sudo ./fnos_storage_expand.sh --backup list

# 恢复指定备份
sudo ./fnos_storage_expand.sh --backup restore /tmp/fnos_backup_20240101_120000

# 或者使用交互式菜单
sudo ./fnos_storage_expand.sh --backup
```

### Q8: 扩容后性能是否会受影响？
**A:** 正常情况下不会：
- LVM扩容是在线操作，不影响性能
- 文件系统扩容可能短暂影响IO
- 建议在低负载时段进行操作

### Q9: 支持哪些虚拟化平台？
**A:** 主要支持VMware ESXi，其他平台需要验证：
- VMware ESXi 6.0+ ✅
- VMware Workstation ✅ (理论支持)
- Hyper-V ⚠️ (需要测试)
- KVM/QEMU ⚠️ (需要测试)

### Q10: 如何验证扩容是否成功？
**A:** 多重验证方法：
1. 命令行检查：`df -h /vol1`
2. 飞牛OS界面检查存储空间大小
3. 创建测试文件验证可用空间
4. 检查LVM状态：`lvdisplay`
5. 验证分区大小：`lsblk`
6. 检查文件系统：`btrfs filesystem show`（对于btrfs）

## 🔒 安全建议

### 操作前
1. **创建完整备份** - 虚拟机快照或数据备份
2. **选择合适时间** - 在维护窗口期间操作
3. **准备回滚方案** - 确保能够快速恢复
4. **测试环境验证** - 在测试环境中先行验证

### 操作中
1. **仔细确认** - 每个步骤都要仔细确认
2. **保存日志** - 记录所有操作步骤和结果
3. **分步执行** - 不要跳过任何步骤
4. **监控状态** - 密切关注系统状态

### 操作后
1. **全面验证** - 确认所有功能正常
2. **性能测试** - 检查系统性能是否正常
3. **保留备份** - 保留操作前的备份一段时间
4. **文档记录** - 记录操作过程和结果

## 📞 技术支持

如果在扩容过程中遇到问题：

1. **查看日志文件** - 检查脚本生成的详细日志
2. **收集系统信息** - 保存相关的系统状态信息
3. **寻求帮助** - 联系技术支持或社区论坛
4. **提供详细信息** - 包括错误信息、系统配置等

## 📝 版本历史

- **v1.1** (2024-12-XX) - 修复版本，解决关键问题
  - 修复LVM逻辑卷路径构建问题
  - 添加GPT分区表支持
  - 改进数据获取和验证机制
  - 优化错误处理和日志输出
- **v1.0** (2024-01-XX) - 初始版本，支持基本的LVM扩容功能
  - 支持自动检测存储配置
  - 支持多种文件系统类型
  - 包含完整的备份和恢复机制

---

**免责声明：** 此操作涉及系统底层存储配置，存在数据丢失风险。请务必在操作前创建完整备份，并在测试环境中验证。使用者需自行承担操作风险。 