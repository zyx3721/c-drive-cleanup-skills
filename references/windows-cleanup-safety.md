# Windows 清理安全参考

## 优先顺序

1. 先测量当前可用空间和可能释放的空间。
2. 优先使用 Windows 设置、存储感知、磁盘清理、DISM 或应用自带清理工具。
3. 只有在关闭相关应用后，才清理低风险缓存。
4. 删除用户文件前，先让用户审查。
5. 清理后重新测量，并记录发生了什么变化。

## 安全但必须明确批准

- 回收站内容。
- `%TEMP%` 和 `C:\Windows\Temp` 的内容，跳过被锁定文件。
- `C:\Windows\SoftwareDistribution\Download`，前提是 Windows Update 处于空闲状态，并且更新服务能被干净重启。
- 通过 Windows 设置或 `cleanmgr` 清理传递优化缓存。
- 通过浏览器设置清理浏览器缓存。
- 通过工具自带命令清理包管理器缓存，例如 `npm cache clean --force`、`pip cache purge`、`winget source reset` 或对应工具的专用清理命令。

## 先审查

- `Downloads`、Desktop、Documents、Videos、Pictures、Music。
- `.zip`、`.7z`、`.rar`、`.iso`、`.msi`、`.exe`、`.dmg`、`.vhd`、`.vhdx`、`.qcow2`、`.bak`、`.old`、`.log` 文件。
- Docker 镜像、WSL 发行版、虚拟机目录、游戏库、IDE 索引、构建产物、包缓存和源码仓库。
- OneDrive、Dropbox、Google Drive、iCloud Drive 等云同步目录。

## 只用官方工具

- `WinSxS`：使用 DISM 组件存储分析和清理。
- 系统还原和卷影副本：只有明确批准后，才通过系统保护设置或 `vssadmin` 处理。
- `hiberfil.sys`：只有用户接受失去休眠和快速启动时，才用 `powercfg /hibernate off`。
- `pagefile.sys`：除非和用户一起排查问题，否则不要修改。
- 驱动存储：使用官方驱动清理或设备管理工具。
- 已安装应用和游戏：使用卸载器、设置、`winget uninstall` 或启动器自带工具。

## 避免手动删除

- `C:\Windows\System32`
- `C:\Windows\WinSxS`
- `C:\Windows\Installer`
- `C:\Program Files`
- `C:\Program Files (x86)`
- `C:\ProgramData`，除非是明确识别出的缓存目录
- 用户配置目录中的 `AppData`，除非是明确识别出的临时目录或缓存目录
- 注册表配置单元、启动文件、恢复分区和未知隐藏系统目录

## 报告模板

诊断后使用这个结构：

```text
当前 C: 可用空间：X GB / Y GB

大概率安全可释放：
- 类别：大小，动作，风险

需要用户审查：
- 路径或类别：大小，为什么需要审查

官方工具清理：
- 工具/命令：预期效果，取舍

建议下一步：
- 一个低风险、可先批准的动作
```
