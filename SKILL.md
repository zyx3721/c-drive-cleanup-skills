---
name: c-drive-cleanup-skills
description: "安全诊断和清理 Windows C 盘空间。用户要求释放 C: 空间、分析磁盘占用、清理 Windows 临时文件、Windows Update 缓存、传递优化缓存、回收站、用户缓存、大体积下载、WinSxS/组件存储，或为 Windows 系统盘制定谨慎清理计划时使用。"
---

# Windows C 盘清理助手

## 核心规则

- 先做只读诊断。未经用户明确批准具体清理动作前，不删除、移动、卸载、压缩或重置任何内容。
- 将 `C:\Windows`、`C:\Program Files`、`C:\Program Files (x86)`、`C:\ProgramData`、用户配置目录、包管理器缓存和开发工作区视为敏感区域，除非对应清理类别已明确安全。
- 优先使用 Windows 内置工具，而不是手动删除：设置 > 系统 > 存储、存储感知、磁盘清理、`cleanmgr`、DISM 组件清理、应用卸载器、包管理器自带缓存清理命令。
- 不要建议手动删除 `WinSxS`、`System32`、安装器数据库、注册表配置单元、驱动存储、还原点、`pagefile.sys`/`hiberfil.sys` 或未知应用数据。此类项目只用官方工具处理。
- 说明风险和可逆性。把动作分为“安全但需批准”“先审查”“避免手动处理”。
- 保护用户数据。Downloads、Desktop、Documents、项目目录、虚拟机镜像、游戏库、照片、视频和压缩包都需要用户审查。

## 工作流

1. 确认范围：通常是 Windows 的 `C:`。触及其他盘或云同步目录前先询问用户。
2. 本地 shell 可用时，先用 `scripts/measure_c_drive.ps1` 做只读测量。
3. 汇总最大占用类别，并分类清理候选项：
   - 安全但需批准：临时目录、回收站、Windows Update 下载缓存、传递优化缓存、浏览器/应用缓存，但相关应用应先关闭。
   - 先审查：Downloads、大压缩包、ISO、安装包、旧导出文件、Docker/WSL 数据、虚拟机镜像、游戏录制、包管理器缓存。
   - 只用官方工具：WinSxS/组件存储、还原点、休眠文件、页面文件、已安装应用、驱动。
   - 避免手动处理：系统目录、应用数据库、未知隐藏目录、当前项目依赖的任何内容。
4. 按风险和预计可释放空间提出分阶段计划。
5. 只执行用户批准的步骤，最好一次处理一个类别。
6. 完成后重新测量可用空间，并报告清理前后结果。

## 测量脚本

在 PowerShell 中使用这个只读命令：

```powershell
& "$env:USERPROFILE\.codex\skills\c-drive-cleanup-skills\scripts\measure_c_drive.ps1" -Drive C: -Top 20
```

常用选项：

```powershell
# 包含顶层目录估算大小。可能需要几分钟。
& "$env:USERPROFILE\.codex\skills\c-drive-cleanup-skills\scripts\measure_c_drive.ps1" -Drive C: -Top 20 -IncludeTopLevel

# 写出 JSON 报告，便于后续对比。
& "$env:USERPROFILE\.codex\skills\c-drive-cleanup-skills\scripts\measure_c_drive.ps1" -Drive C: -JsonPath ".\c-drive-report.json"
```

脚本刻意保持只读。它会报告卷使用情况，以及当前机器上常见清理候选目录的估算大小。

## 常见动作

- 清空回收站：只有用户批准后才使用 `Clear-RecycleBin`。
- Windows 临时文件：先关闭应用，再清理 `%TEMP%` 和 `C:\Windows\Temp` 的内容；跳过被锁定文件并报告失败项。
- Windows Update 下载缓存：停止 `wuauserv` 和 `bits`，清理 `C:\Windows\SoftwareDistribution\Download`，再重启服务；仅在 Windows Update 没有安装更新时执行。
- 组件存储：用 `DISM /Online /Cleanup-Image /AnalyzeComponentStore` 分析；用户批准后用 `DISM /Online /Cleanup-Image /StartComponentCleanup` 清理。
- 休眠文件：`powercfg /hibernate off` 可释放 `hiberfil.sys`，但会关闭休眠和快速启动；必须得到明确批准。
- 已安装应用：使用设置、官方卸载器或 `winget uninstall`。不要手动删除应用目录。
- WSL/Docker/虚拟机：先报告占用大小。清理需要产品专用命令和用户确认，因为数据丢失风险较高。

## 参考

在准备详细清理计划、处理高风险类别，或解释哪些内容不能手动删除时，读取 `references/windows-cleanup-safety.md`。
