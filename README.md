# 飞牛NAS存储扩展脚本汇总指南

## 概览
- **目标** 提供 `fnos_storage_expand/` 下全部自动化脚本的入口命令及功能速览，便于快速选择合适方案。
- **目录**
  - `fnos_kuorong/`：飞牛OS在线扩容与备份工具包。
  - `flynas_partition_manager/`：通用分区管理与调整助手。
  - `flynas_storage_creator/`：系统分区腾挪空间并创建新存储分区的自动化方案。

## 使用前准备
- **权限** 需具备 `root` 或 `sudo` 权限。
- **环境** 建议提前创建快照或完整数据备份，确认主机磁盘已在虚拟化平台扩容。
- **执行** 首次运行前为脚本赋予执行权限：
  ```bash
  chmod +x <script_name>.sh
  ```

## 脚本速查表
| 序号 | 脚本路径 | 主调用命令 | 核心功能 | 推荐场景 |
|------|----------|------------|----------|----------|
| 1 | `fnos_kuorong/fnos_storage_expand.sh` | `sudo ./fnos_storage_expand.sh` | 在线检测、扩容、备份恢复一体化 | ESXi 已扩容虚拟磁盘，需要在线扩展 `vol1` 等数据卷 |
| 2 | `flynas_partition_manager/flynas_partition_manager_v3_complete.sh` | `sudo ./flynas_partition_manager_v3_complete.sh` | 智能识别分区、支持任意分区间空间调整与对齐修复 | 需在多分区、多文件系统场景下灵活调整空间 |
| 3 | `flynas_storage_creator/flynas_create_storage_v3_ultimate.sh` | `sudo ./flynas_create_storage_v3_ultimate.sh` | 释放系统分区空间并创建新的 `vda2` 存储分区 | 只有单盘环境，需要为飞牛NAS创建新的存储卷 |

## 详细说明

### `fnos_kuorong/` 在线扩容工具
- **主脚本** `fnos_storage_expand.sh`
- **关键命令**
  ```bash
  sudo ./fnos_storage_expand.sh              # 进入交互式菜单
  sudo ./fnos_storage_expand.sh --dry-run    # 仅检测磁盘/LVM状态
  sudo ./fnos_storage_expand.sh --backup     # 进入备份管理菜单
  sudo ./fnos_storage_expand.sh --backup create   # 创建当前配置备份
  sudo ./fnos_storage_expand.sh --backup restore <路径>  # 恢复指定备份
  ```
- **功能要点**
  - **自动检测** 智能识别挂载点、LVM 结构及可扩容空间。
  - **安全守护** 在扩容前自动备份分区表、LVM 配置与 `fstab`。
  - **多文件系统支持** 针对 `ext4`、`xfs`、`btrfs` 等场景自动选择扩容策略。
  - **日志追踪** 执行日志保存在 `/var/log/fnos_storage_expand_*.log`，备份位于 `/tmp/fnos_expand_backup_*`。
- **适用人群** 需要在业务不中断情况下扩容飞牛OS存储卷，并希望保留完整回滚能力的管理员。

### `flynas_partition_manager/` 通用分区管理器
- **主脚本** `flynas_partition_manager_v3_complete.sh`
- **关键命令**
  ```bash
  sudo ./flynas_partition_manager_v3_complete.sh
  ```
- **功能要点**
  - **分区盘点** 自动罗列物理/逻辑分区、文件系统类型、挂载点与使用率。
  - **灵活操作** 支持在任意源、目标分区间移动空间，可利用未分配空间或删除分区。
  - **对齐修复** 识别扇区间隙，提供一键扩展到磁盘末尾的对齐修复流程。
  - **两阶段执行** 通过 systemd 服务在重启后完成高风险操作，配合 `/var/lib/flynas_partition_state_v3` 状态文件确保可追踪。
- **适用人群** 需对飞牛NAS或其他 Linux 主机执行复杂分区规划、解决扇区对齐问题或跨文件系统调整空间的运维人员。

### `flynas_storage_creator/` 存储分区创建方案
- **主脚本** `flynas_create_storage_v3_ultimate.sh`
- **关键命令**
  ```bash
  sudo ./flynas_create_storage_v3_ultimate.sh          # 启动流程并配置释放空间
  sudo ./flynas_create_storage_v3_ultimate.sh --cleanup # 执行完成后的清理
  ```
- **功能要点**
  - **空间评估** 自动计算系统分区已用与可释放容量，提醒最小保留空间（>=13GB）。
  - **自动化流程** 创建 systemd 一次性服务在重启后执行离线缩小、`gdisk` 调整分区、创建 `vda2` 并扩展文件系统。
  - **配置修复** 检测 UUID 变化后自动更新 `/etc/fstab` 与 `GRUB`，重启后若进入 GRUB 救援模式需要按指南手动恢复。
  - **日志定位** 准备与执行日志分别写入 `/var/log/flynas_storage_v3.log` 和 `/var/log/flynas_resize_exec.log`。
- **适用人群** 希望远程（SSH）完成系统盘减容并新建存储分区、无法使用 LiveCD 但可以接受一次重启和手动 GRUB 恢复的场景。

## 建议流程
- **选择脚本** 根据上表确认需求：在线扩容选 `fnos_storage_expand.sh`，复杂分区调整选 `flynas_partition_manager_v3_complete.sh`，单盘腾挪创建新存储选 `flynas_create_storage_v3_ultimate.sh`。
- **执行前** 复核磁盘扩容、LVM 状态及备份方案，必要时多读对应子目录下的 README 了解限制与风险。
- **执行中** 关注脚本输出与日志，严格按照提示输入 `YES`/`yes` 等确认信息。
- **执行后** 验证 `lsblk`、`df -h`、飞牛NAS 管理界面中的容量变化，并在需要时运行 `--cleanup` 或查看状态文件确保流程完结。
