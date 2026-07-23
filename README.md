# Windows C 盘清理助手技能

一个面向 Codex 的 Windows C 盘清理助手技能，用于安全诊断系统盘空间占用，并在用户明确批准后引导执行低风险清理动作。

本项目的核心目标不是“尽快删除文件”，而是先测量、再分级、再确认、最后复测，尽量避免误删系统文件、用户资料、开发环境缓存或应用关键数据。

## 适用场景

- 分析 Windows `C:` 盘空间占用。
- 识别临时文件、回收站、Windows Update 下载缓存、传递优化缓存、浏览器缓存等清理候选项。
- 为 Downloads、大文件、Docker、WSL、虚拟机、游戏库、包管理器缓存等高风险类别制定审查计划。
- 使用 Windows 设置、存储感知、磁盘清理、DISM、应用卸载器等官方工具完成系统级清理。
- 在清理前后生成可对比的磁盘空间报告。

## 安全原则

- 默认只读诊断，不在未经用户明确批准前删除、移动、卸载、压缩或重置任何内容。
- 对 `C:\Windows`、`C:\Program Files`、`C:\Program Files (x86)`、`C:\ProgramData`、用户配置目录和开发工作区保持谨慎。
- 不手动删除 `WinSxS`、`System32`、安装器数据库、注册表配置单元、驱动存储、还原点、`pagefile.sys`、`hiberfil.sys` 或未知应用数据。
- 用户文件必须先审查，例如 Downloads、Desktop、Documents、照片、视频、压缩包、虚拟机镜像和源码仓库。
- 清理后重新测量，并报告清理前后空间变化。

## 项目结构

```text
.
├── SKILL.md
├── agents/
│   └── openai.yaml
├── references/
│   └── windows-cleanup-safety.md
└── scripts/
    └── measure_c_drive.ps1
```

- `SKILL.md`：技能入口，定义触发说明、核心规则、工作流和常见动作。
- `scripts/measure_c_drive.ps1`：只读测量脚本，支持快速和全面两档 C 盘分析，并输出结构化 JSON 报告。
- `references/windows-cleanup-safety.md`：清理安全参考，说明哪些动作可批准执行、哪些必须审查、哪些只能用官方工具。
- `agents/openai.yaml`：Codex/OpenAI agent 展示配置。

## 安装

将本仓库克隆或复制到 Codex 技能目录，例如：

```powershell
git clone https://github.com/<your-name>/c-drive-cleanup-skills.git "$env:USERPROFILE\.codex\skills\c-drive-cleanup-skills"
```

如果已经在其他目录开发，可以在发布前保持当前项目结构不变；推送到 GitHub 后再按上面的路径安装到本机技能目录。

## 使用方式

### 管理员前置条件

首次咨询时，技能会自动进行只读管理员权限预检。若当前会话不是管理员，可使用 `-ElevateIfNeeded` 自动发起 Windows UAC；只有用户在 UAC 中批准后，独立的管理员 PowerShell 才会执行扫描。该机制不能绕过或代替用户确认 UAC。

管理员会话可直接执行扫描；非管理员会话建议使用下方的 `-ElevateIfNeeded`，扫描结果会自动写入 JSON 文件供原会话读取。

在 Codex 中提出类似请求即可触发该技能：

```text
帮我分析 C 盘为什么快满了，并给出安全清理方案。
```

技能会优先使用只读测量脚本：

```powershell
& "$env:USERPROFILE\.codex\skills\c-drive-cleanup-skills\scripts\measure_c_drive.ps1" -Drive C: -ScanMode Quick -Top 20 -ElevateIfNeeded
```

如需整体分析 C 盘顶层目录和用户目录中的大文件：

```powershell
& "$env:USERPROFILE\.codex\skills\c-drive-cleanup-skills\scripts\measure_c_drive.ps1" -Drive C: -ScanMode Full -Top 50 -MinimumLargeDirectoryGB 0.25 -MinimumLargeFileGB 1
```

如果需要保存 JSON 报告：

```powershell
& "$env:USERPROFILE\.codex\skills\c-drive-cleanup-skills\scripts\measure_c_drive.ps1" -Drive C: -ScanMode Full -ElevateIfNeeded -JsonPath ".\c-drive-report.json"
```

如需把 Windows 组件存储的只读 DISM 分析加入报告（通常需管理员终端）：

```powershell
& "$env:USERPROFILE\.codex\skills\c-drive-cleanup-skills\scripts\measure_c_drive.ps1" -Drive C: -ScanMode Quick -AnalyzeComponentStore -ElevateIfNeeded
```

## 测量脚本参数

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-Drive` | `C:` | 要测量的盘符，格式如 `C:` 或 `D:`。 |
| `-ScanMode` | `Quick` | `Quick` 扫描常见类别；`Full` 单次遍历所有可访问的 C 盘目录与文件。 |
| `-Top` | `20` | 输出前 N 个清理候选项或顶层目录。 |
| `-MinimumLargeFileGB` | `1` | 全面模式中列为“大文件”的最小大小（GB）。 |
| `-MinimumLargeDirectoryGB` | `0.25` | 全面模式中列为“大目录”的最小大小（GB）。 |
| `-IncludeTopLevel` | 关闭 | 兼容参数；在快速模式下额外统计顶层目录。 |
| `-AnalyzeComponentStore` | 关闭 | 运行只读的 DISM 组件存储分析；可能需要管理员权限。 |
| `-ElevateIfNeeded` | 关闭 | 当前会话不是管理员时发起 Windows UAC；获批准后使用独立管理员 PowerShell 扫描，并输出 JSON 报告。 |
| `-JsonPath` | 空 | 写出 JSON 报告，便于清理前后对比。 |

脚本只执行读取和统计，不会删除文件。使用 `-ElevateIfNeeded` 且未指定 `-JsonPath` 时，会在当前用户的临时目录创建带时间戳与随机标识的 JSON 报告；原会话可读取该报告。全面模式单次遍历整个盘符下所有可访问的非重解析目录，输出最大的目录、文件和按风险分类的清理候选项，避免重复递归。它会跳过重解析点，并对无权限或锁定路径记录 `Errors`、最多 10 条 `ErrorSamples` 和 `SkippedReparsePoints`；因此报告是定位依据，可能低估受保护或被锁定路径的实际占用。

扫描结论应逐行显示报告中的完整 `Path`（包括盘符），以及对应的占用、风险和建议。不要只显示“Chrome 用户数据”“临时文件”等汇总类别；同一类别包含多个目录时，必须列出每个实际路径。

## 清理分级

| 分级 | 示例 | 处理方式 |
| --- | --- | --- |
| 安全但需批准 | 临时目录、回收站、WER 报告、浏览器缓存 | 说明风险和影响后，请用户批准再执行。 |
| 先审查 | Downloads、大压缩包、ISO、Docker、WSL、虚拟机、游戏库 | 展示路径和大小，由用户判断是否保留。 |
| 只用官方工具 | WinSxS、系统还原、休眠文件、页面文件、已安装应用、驱动 | 使用 Windows 设置、DISM、卸载器或对应官方工具。 |
| 避免手动处理 | System32、Windows Installer、未知 ProgramData、未知 AppData | 不建议手动删除。 |

## 验证

文档修改后，可做以下轻量检查：

```powershell
Get-ChildItem -Recurse
Get-Content .\README.md
```

如果只验证测量脚本语法（不会执行扫描）：

```powershell
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
  (Resolve-Path .\scripts\measure_c_drive.ps1), [ref]$tokens, [ref]$errors
)
if ($errors.Count) { $errors; exit 1 }
```

注意：测量真实 C 盘可能耗时，尤其是使用 `-ScanMode Full` 时。`WinSxS` 可回收空间、系统还原点、已安装应用和 Docker/WSL 数据仍应通过对应官方工具进一步分析。

## 发布到 GitHub 前检查

1. 确认没有提交本机私有路径、账号、密钥、token 或清理报告。
2. 如果生成过 `c-drive-report.json` 等本机诊断文件，不要提交。
3. 运行一次只读脚本验证，确认没有破坏脚本入口。
4. 使用原子提交，例如：

```powershell
git add README.md
git commit -m "docs: add project readme"
```

5. 创建 GitHub 新仓库后再添加远程地址并推送：

```powershell
git remote add origin https://github.com/<your-name>/c-drive-cleanup-skills.git
git push -u origin main
```

## 许可证

本项目采用 MIT License 开源，允许自由使用、复制、修改、分发和再授权。

公开使用或二次分发时，请保留 `LICENSE` 文件中的版权声明和许可文本。该工具涉及系统盘诊断与清理建议，软件按“原样”提供，不附带任何形式的担保；执行清理动作前仍应先审查风险并确认备份。

## 联系方式

- **作者**：Jerion
- **邮箱**：416685476@qq.com
- **项目地址**：https://github.com/zyx3721/c-drive-cleanup-skills
