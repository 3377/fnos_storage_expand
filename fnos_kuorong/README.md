# 飞牛OS存储空间自动化扩容工具

## 📖 项目简介

本项目提供了一套完整的飞牛OS存储空间扩容解决方案，适用于ESXi虚拟化环境。当您在ESXi中扩容虚拟磁盘后，可以使用这些工具自动完成飞牛OS系统内的存储空间扩容。

## 📁 文件说明

| 文件名 | 描述 |
|--------|------|
| `fnos_storage_expand.sh` | 主要的自动化扩容脚本（集成备份恢复功能） |
| `fnos_storage_expand_guide.md` | 详细的操作指南和文档 |
| `README.md` | 项目说明文件（本文件） |

## 🚀 快速开始

### 1. 准备工作
- 确保已在ESXi中完成虚拟磁盘扩容
- 创建虚拟机快照作为备份
- 通过SSH连接到飞牛OS系统

### 2. 获取脚本
```bash
# 方法一：从GitHub克隆项目
git clone https://github.com/3377/fnos_storage_expand.git
cd fnos_storage_expand

# 方法二：直接下载脚本文件
wget https://raw.githubusercontent.com/3377/fnos_storage_expand/main/fnos_storage_expand.sh

# 方法三：使用scp上传（在本地执行）
scp fnos_storage_expand.sh root@your-fnos-ip:/root/
```

### 3. 设置权限
```bash
# 在飞牛OS系统中执行
chmod +x fnos_storage_expand.sh
```

### 4. 执行扩容

#### 方法一：交互式菜单（推荐）
```bash
# 运行脚本，显示功能菜单
sudo ./fnos_storage_expand.sh

# 或者直接显示菜单
sudo ./fnos_storage_expand.sh --menu
```

脚本会显示功能菜单：
1. **存储空间扩容** - 执行自动化扩容流程
2. **备份恢复管理** - 管理系统备份和恢复
3. **干运行检测** - 查看当前磁盘状态和可扩容空间
4. **退出**

#### 方法二：直接执行扩容
```bash
# 预检查（查看当前磁盘状态和可扩容空间）
sudo ./fnos_storage_expand.sh --dry-run

# 执行交互式扩容（跳过菜单）
sudo ./fnos_storage_expand.sh --menu
# 然后选择选项1进行扩容
```

#### 方法三：备份恢复操作
```bash
# 创建备份
sudo ./fnos_storage_expand.sh --backup create

# 列出备份
sudo ./fnos_storage_expand.sh --backup list

# 恢复备份
sudo ./fnos_storage_expand.sh --backup restore /path/to/backup

# 进入备份管理菜单
sudo ./fnos_storage_expand.sh --backup
```

## 📋 使用场景

### 典型使用流程
1. **ESXi扩容** - 在ESXi管理界面中扩容虚拟磁盘
2. **创建快照** - 为虚拟机创建快照备份
3. **SSH连接** - 连接到飞牛OS系统
4. **执行脚本** - 运行自动化扩容脚本
5. **验证结果** - 确认扩容成功

### 支持的配置
- **虚拟化平台**: VMware ESXi 6.0+
- **操作系统**: 飞牛OS (fnOS) 各版本
- **存储配置**: LVM管理的存储空间
- **文件系统**: btrfs、ext4、ext3、xfs

## ⚠️ 重要提醒

### 操作前必读
1. **数据备份** - 务必创建虚拟机快照或完整数据备份
2. **测试环境** - 建议先在测试环境中验证
3. **维护窗口** - 在业务低峰期进行操作
4. **权限确认** - 确保具有root权限

### 风险说明
- 分区操作存在数据丢失风险
- 不当操作可能导致系统无法启动
- 建议由有经验的系统管理员执行

## 🔧 故障排除

### 常见问题
1. **权限不足** - 使用 `sudo` 执行脚本
2. **磁盘未扩容** - 确认ESXi中已完成磁盘扩容
3. **LVM未检测** - 检查存储空间是否使用LVM管理
4. **脚本执行失败** - 查看日志文件排查错误
5. **LVM扩容失败** - 检查逻辑卷路径是否正确
6. **分区类型错误** - 确认GPT/MBR分区表类型

### 紧急恢复
如果扩容失败：
```bash
# 恢复备份
sudo ./fnos_storage_expand.sh --backup restore /tmp/fnos_backup_YYYYMMDD_HHMMSS

# 或者在ESXi中恢复虚拟机快照
```

## 📚 详细文档

完整的操作指南请参考：[fnos_storage_expand_guide.md](./fnos_storage_expand_guide.md)

该文档包含：
- 详细的背景说明
- 分步操作指南
- 手动操作方法
- 故障排除方案
- 常见问题解答

## 🛠️ 脚本功能

### 主扩容脚本 (fnos_storage_expand.sh)
- ✅ 自动检测存储配置
- ✅ 智能识别磁盘和分区
- ✅ 支持GPT和MBR分区表
- ✅ 支持多种文件系统
- ✅ 完整的备份机制
- ✅ 详细的操作日志
- ✅ 进度显示和确认提示
- ✅ LVM逻辑卷路径智能识别
- ✅ 集成备份恢复功能
- ✅ 交互式菜单界面
- ✅ 命令行参数支持

### 集成的备份恢复功能
- ✅ 系统配置备份
- ✅ LVM配置备份
- ✅ 分区表备份
- ✅ 备份完整性验证
- ✅ 一键恢复功能
- ✅ 备份管理功能
- ✅ 交互式和命令行模式

## 📞 技术支持

### 获取帮助
```bash
# 查看脚本帮助
./fnos_storage_expand.sh --help

# 查看备份恢复帮助
./fnos_storage_expand.sh --backup --help
```

### 日志文件
- 扩容日志：`/var/log/fnos_storage_expand_*.log`
- 备份目录：`/tmp/fnos_expand_backup_*`

### 联系方式
如遇到问题，请提供：
1. 错误信息和日志文件
2. 系统配置信息
3. 操作步骤描述

## 📝 版本信息

- **当前版本**: v1.1
- **更新日期**: 2024年12月
- **兼容性**: 飞牛OS各版本，ESXi 6.0+

### 更新日志
#### v1.1 (当前版本)
- 🔧 修复LVM逻辑卷路径构建问题
- 🔧 添加GPT分区表支持
- 🔧 改进数据获取和验证机制
- 🔧 优化错误处理和日志输出
- 🔧 增强脚本稳定性和兼容性

#### v1.0
- 🎉 初始发布版本
- ✅ 支持自动化存储扩容
- ✅ 包含完整的备份恢复机制
- ✅ 提供详细的操作文档

## 📄 许可证

本项目仅供学习和研究使用。使用者需自行承担操作风险。

---

**⚠️ 免责声明**: 此工具涉及系统底层存储配置，存在数据丢失风险。请务必在操作前创建完整备份，并在测试环境中验证。使用者需自行承担操作风险。 