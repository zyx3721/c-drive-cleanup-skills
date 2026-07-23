---
name: c-drive-cleanup-skills
description: "安全诊断和清理 Windows C 盘空间。用于分析 C: 整体占用、临时文件、系统根文件、浏览器与开发缓存、Docker/WSL/虚拟机、用户大文件、Windows Update、回收站、WinSxS/组件存储，或制定谨慎的 Windows 系统盘清理计划。"
---

# Windows C 盘清理助手

## 核心规则

- 先做只读诊断。未经用户明确批准具体清理动作前，不删除、移动、卸载、压缩或重置任何内容。
- 将系统目录、应用目录、用户配置目录、包管理器缓存和开发工作区视为敏感区域；仅对已识别的低风险类别提出清理建议。
- 优先使用 Windows、浏览器、包管理器、Docker 和虚拟机产品提供的清理工具。不得手动删除 `WinSxS`、`System32`、`Windows\Installer`、驱动存储、还原点、`pagefile.sys`、`hiberfil.sys` 或未知应用数据。
- 解释风险、可逆性和预计释放空间。将建议分为“安全但需批准”“先审查”“只用官方工具”“避免手动处理”。

## 工作流

1. 首次收到 C 盘诊断或清理请求时，先执行一次只读管理员权限预检。若未提升权限，使用 `-ElevateIfNeeded` 自动发起 Windows UAC；用户批准后由独立管理员 PowerShell 执行扫描并写出 JSON 报告。不得绕过、自动接受或伪造 UAC。用户拒绝或 UAC 无法启动时，停止后续测量、DISM 和目录遍历，并说明原因。
2. 预检通过后运行测量脚本。脚本会再次验证管理员身份；若验证失败，停止扫描并要求用户以管理员身份重新启动会话。
3. 确认目标盘。默认分析 `C:`；触及其他盘、云同步目录或用户数据前先询问。
4. 用户请求整体分析、空间异常或快速模式无法解释占用时，运行全面模式；否则运行快速模式。
5. 检查报告中的 `Errors` 与 `ErrorSamples`。访问受限或锁定路径会被跳过，因此目录统计可能低于已用空间。
6. 对 `WinSxS` 使用 DISM，对已安装应用使用设置或卸载器，对 Docker/WSL/虚拟机使用产品专用命令；不要用目录大小替代这些工具的结论。
7. 按风险和预计收益提出一次一个类别的操作；完成后重新测量并报告前后差异。
8. 呈现扫描结论时，逐行保留报告的原始 `Path`，使用绝对路径；不得只给类别、目录名或相对路径。

## 只读测量

脚本可在管理员 PowerShell 或管理员 Codex 会话中直接运行。非管理员会话应加入 `-ElevateIfNeeded`：脚本会请求 Windows UAC，获批准后由独立管理员 PowerShell 执行扫描；原会话只读取生成的 JSON 报告。

```powershell
# 快速：卷容量、常见清理项、系统根文件、浏览器和开发缓存
& ".\scripts\measure_c_drive.ps1" -Drive C: -ScanMode Quick -ElevateIfNeeded

# 全面：单次遍历全盘，列出最大的目录、文件和可安全清理候选项；可能耗时数分钟
& ".\scripts\measure_c_drive.ps1" -Drive C: -ScanMode Full -Top 50 -MinimumLargeDirectoryGB 0.25 -MinimumLargeFileGB 1 -ElevateIfNeeded

# 保留机器可读报告；父目录必须存在
& ".\scripts\measure_c_drive.ps1" -Drive C: -ScanMode Full -ElevateIfNeeded -JsonPath ".\c-drive-report.json"

# 组件存储的只读分析；通常需要管理员终端
& ".\scripts\measure_c_drive.ps1" -Drive C: -ScanMode Quick -AnalyzeComponentStore -ElevateIfNeeded
```

全面模式单次遍历所有可访问的非重解析目录，输出全盘最大的目录与文件，并按路径标记“安全但需批准”“先审查”“仅官方工具”。扫描器仅保留 Top N 结果，避免大盘扫描耗尽内存。它报告逻辑文件大小，不等同于物理磁盘分配；`Errors`、`ErrorSamples` 或 `SkippedReparsePoints` 非零时应说明漏计风险。

## 报告呈现

- 汇总前先读取扫描输出或 JSON 报告中的 `CleanupCandidates`、`LargeDirectories`、`LargeFiles`、`RootFiles` 字段；它们均包含 `Path`。
- “主要可优化方向”使用表格时，表头必须包含“路径”，每一行均展示对应的完整 `Path`、占用、风险与建议。路径可使用行内代码，但不得省略盘符或以 `...` 截断。
- 不得把多个目录合并成只有“企业微信数据”“Chrome 用户数据”等类别名的一行；若需要归类，仍须在该类别下逐行列出每个实际路径及其大小。
- “仅官方工具处理”“避免手动处理”和大文件清单同样必须展示完整绝对路径，例如 `C:\pagefile.sys`，不能只显示文件名。
- 仅在报告未提供路径、或路径因访问错误无法取得时，明确写明“路径未取得”及原因；不要猜测或编造路径。

## 官方分析

- 组件存储：以管理员身份运行 `DISM /Online /Cleanup-Image /AnalyzeComponentStore`；清理需用户批准后运行 `StartComponentCleanup`。
- 还原点与卷影副本：仅通过系统保护设置或 `vssadmin` 分析和处理。
- 已安装应用和游戏：使用设置、官方卸载器、`winget uninstall` 或启动器。
- Docker/WSL/虚拟机：先报告占用，再使用各产品命令；数据清理必须得到单独批准。

## 参考

准备详细计划、处理高风险类别或执行清理前，读取 `references/windows-cleanup-safety.md`。
