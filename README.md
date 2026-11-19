# LocalSafe

Windows 软件关联检查工具。查看安装目录与服务、驱动、启动项、计划任务、防火墙及注册表之间的证据，帮助评估卸载遗留。

当前为 **v0.3.0 预览版**：自动发现已安装软件、检查关联、保存和比较系统登记快照，并支持桌面软件的自带卸载程序与确认后的遗留处理。普通检查仍是只读操作。安装期间实时监测、全盘文件/注册表差异、共享驱动清理和自动重启后验收尚未实现，不能声称“完全卸载”。

## 使用

从 [GitHub Releases](https://github.com/ikeity/localsafe/releases) 下载 Windows 便携包，完整解压后双击 `LocalSafe.exe`。保留旁边的 `src` 文件夹，不能只复制 EXE。发行文件尚未做代码签名，Windows 可能显示未知发布者；可用随附的 `SHA256SUMS.txt` 核对下载文件。

Windows 10/11，64 位 Windows PowerShell 5.1，无需安装额外依赖。双击 `Start-LocalSafe.cmd` 后，通过 Windows UAC 确认，以管理员权限打开桌面窗口；已有管理员权限时直接打开。取消 UAC 就停止启动，不退回权限不足的普通窗口。启动器使用系统自带 .NET 编译器将小型窗口宿主编译到 `%LOCALAPPDATA%\LocalSafe\Runtime`，生成文件不进入仓库。直接启动此宿主也会检查权限；提升时保留原入口，包括最近一次卸载记录。只在本进程放行自身脚本执行，不修改系统执行策略或绕过 UAC。管理员身份不等于清理授权，清理仍须选择项目并确认。

同一用户的同一 Windows 会话只运行一个桌面实例，实例锁不随运行时目录或版本哈希变化。重复启动会唤起已有窗口；有卸载或确认弹窗时优先显示当前弹窗，不重复打开界面或再次请求 UAC。升级前已打开的旧版本需要先正常关闭。应用退出或崩溃后锁会释放。卸载与确认弹窗归属于主窗口，不单独占用任务栏入口。

应用图标使用专门的实心盾牌图案，EXE 内嵌 16–256 像素的九种 ICO 尺寸；窗口使用同源 PNG，不把细线条操作图标用于任务栏。可通过 `src/assets/Build-AppIcon.ps1` 重建图标资源。

打开后自动发现软件并读取系统登记记录，左侧显示软件列表，可按名称或发布者搜索。默认检查第一款软件，选择其他软件后自动检查其关联，不需要手动选择目录。服务和驱动优先展示，其他记录可按类型筛选，选择一行后展开证据详情。普通权限下无法读取的位置会在“扫描范围”显示。

发现来源为机器级与当前用户的卸载注册表，以及当前用户有开始菜单入口的商店应用；忽略框架、系统组件及更新子项。便携软件和其他用户的应用不保证发现。“更多 → 检查其他目录”保留为补充入口。缺少目录的软件仍在列表中，进行系统登记和名称候选检查；从图标或卸载命令推断的目录会明确标注。没有使用可能触发 MSI 修复的 `Win32_Product`。

系统登记记录在启动时读取，切换软件时复用。单款软件的完整检查结果同时保留在内存和 `%LOCALAPPDATA%\LocalSafe\Private\Cache`；检查过的软件再次选择直接显示缓存，重开程序也可复用。缓存区分管理员与普通权限，避免权限提升后仍沿用读取受限的旧结果。尚未检查的软件首次选择时才检查，切走后完成的结果同样进入缓存。不会在每次点击、筛选或切换时重新扫描。

状态栏标明缓存结果的实际检查时间；这些是历史观察，并非实时状态。“重新检查”主动重新读取系统登记与当前软件的文件、局部注册表，成功后替换缓存，期间保留旧结果。失败不覆盖旧缓存。“刷新”只更新软件列表与启动级系统登记，保留单款结果；软件版本、路径、身份变化会使用新缓存键。缓存没有自动过期重扫，安装、卸载或修改软件后应主动重新检查。进程、服务等动态状态以记录时间为准。各步骤并非原子快照。

CLI 可通过 `-Names` 指定产品名或旧名称。长度小于四个字符的名称不会用于模糊匹配，以免泛匹配；安装路径关联仍然有效。程序不执行被扫描软件。

命令行示例使用虚构路径：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\LocalSafe.ps1 -InstallPath 'C:\Program Files\ExampleVendor\ExampleApp' -Names ExampleApp -Save
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\LocalSafe.ps1 -Mode Discover -Save
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\LocalSafe.ps1 -Mode Snapshot -Save
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\LocalSafe.ps1 -Mode Compare -Before '<before.json>' -After '<after.json>' -Save
```

`-Save` 返回保存路径；省略时输出 JSON。GUI 的“保存系统快照”会直接在本机保存，然后再次保存安装后的快照用于比较。快照比较涵盖系统登记记录，**不包括安装目录文件及应用配置的逐项变化**。任一登记来源读取失败时，比较会拒绝继续，防止把读取失败误报为组件消失。

## 卸载与遗留处理

选择桌面软件后点击“卸载…”，流程在独立窗口内完成：

1. 重新读取当前 Windows 卸载登记，检查版本和 EXE 路径，计算程序哈希，重新保存卸载前清单。仅准备，不立即启动。
2. 展示实际执行文件和参数，点击“启动自带卸载程序”并确认后，打开软件自己的交互式卸载程序。默认不使用静默参数，不经 cmd/PowerShell 解释器转执行注册表字符串。MSI 的简单 `/I{ProductCode}` 入口转换成 `/x {ProductCode} /norestart`，复杂 MSI 参数和通用脚本解释器入口暂不支持。
3. 等待卸载进程树退出后，重新读取系统登记、文件和局部注册表，**绕过扫描缓存**。使用卸载前证据追查仍存在的驱动、服务等，避免安装目录被删除后漏掉组件。退出码不替代残留检查。
4. 逐项显示关联依据、拟执行操作及不能自动处理的原因，所有复选框默认不选。勾选后仍需再次确认实际清单；执行前再取新证据，目标或状态变化时要求重新确认。
5. 每项操作先备份，再单独执行并记录成功、失败或已请求删除的真实状态，最后自动重新检查。不把局部失败当成整体成功，也不自动重启。

卸载被取消、登记仍存在、关键来源读取失败、与其他安装路径重叠或安装目录仅为推断时，清理入口会受限。普通 EXE 返回非标准退出码时，只有重新核验登记和主体目录均消失、没有关联进程且关键来源完整，才允许逐项审核；保留原始退出码，不将其改写为成功。MSI 取消不会按此放行。需要权限的项目会标明管理员要求，用户可点击“以管理员身份继续”，重新检查、选择并确认。商店应用暂不通过此流程卸载，可使用 Windows 设置。

数据目录只有产品名精确匹配、厂商父目录一致、位于标准数据位置、有卸载前记录且未与其他已安装软件重叠时，才开放同级隔离；配置、历史和用户数据仍保留在隔离目录中。驱动、共享组件及仅名称匹配的候选继续保留核对。

| 遗留类型 | 当前执行边界 |
| --- | --- |
| 安装目录 | 仅明确安装登记指定且无已知相关进程、无路径冲突时可选；同级重命名隔离，保留文件内容和权限，不递归永久删除 |
| 已停止的服务 | 仅执行文件直接指向该安装目录时可选；先导出服务登记，再请求删除，仍存在或待重启的状态由复查展示 |
| 防火墙 | 程序路径直接关联该目录时可选；备份单规则与筛选条件后移除 |
| Run 启动值 | 只处理 HKLM/HKCU 的 Run 单值，命令必须直接启动安装目录内 EXE；不删除整个 Run 键 |
| 计划任务 | 所有执行动作均直接指向该目录时可选；导出单任务 XML 后移除 |
| 产品注册表键 | 限非 Microsoft 的两层厂商/产品键，产品名精确匹配且顶层值明确引用该目录；先导出该键再移除 |
| 共享驱动、设备、正在运行的组件、仅名称匹配的目录 | 展示证据与受限原因，不自动删除、停止或强制卸载 |

记录和备份保存在 `%LOCALAPPDATA%\LocalSafe\Private\Uninstall`，可能含私密路径、配置和注册表数据，请勿公开。目录隔离位置在原目录同级，路径写入每项执行记录；可在确认原位置未重新创建后手工移回。注册表、服务、任务和防火墙备份用于人工恢复，程序不承诺一键还原所有系统状态。

“更多 → 上次卸载记录”可重新打开最近流程，即使目标已从软件列表消失；也可运行 `Start-LocalSafe.cmd -LastUninstall` 直接进入最近结果并重新检查，不重放卸载、不自动清理。关闭窗口中断监控不会被当作卸载成功。清理执行期间暂不关闭窗口，以保留完整操作记录。

卸载窗口顶部只显示本次判定和“可清理 / 保留”数量，有失败或检查不完整时仍明确显示数量。“详情”保留原始退出码、卸载状态、检查时间、范围和执行记录；选择一行可查看它的归属依据。保留项不显示复选框，处理列直接说明驱动依赖、归属、运行状态等未通过条件。可选择处理的数量不等于剩余数量；未标准化的厂商退出码不会被改写成成功。目录明确不存在时不把该目录的文件扫描缺失算成权限盲区，无法判断目录状态时仍保留未知。

进程等待与 MSI 参数参照微软文档：[Start-Process](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/start-process?view=powershell-5.1)、[Windows Installer 命令选项](https://learn.microsoft.com/en-us/windows/win32/msi/standard-installer-command-line-options)。

## 界面与图标

软件列表与详情优先读取本机安装登记的 EXE/DLL 图标资源，或商店应用包内的 PNG 标识。提取失败时使用统一的应用图标，不用首字母冒充软件标识。不启动软件，不向网络请求品牌图片，也不将本机提取的图标加入仓库。图像仅在界面内存中缓存，传给后台任务及写入卸载记录前会移除图像对象。

服务、驱动、设备等组件使用一致的线性图标；列表上方可直接筛选类型，悬停组件图标可查看类型名称。活动圆点表示记录中的运行/启用状态，不代表安全认证或健康检查。功能图标来自固定版本的 [Lucide](https://lucide.dev/)，原始 SVG、来源版本与完整 ISC/MIT 许可见 `src/assets/lucide`。本机软件标识属于各自厂商，不随项目分发。

## 关联依据

| 依据 | 含义 | 限制 |
| --- | --- | --- |
| Path | 系统记录的路径包含选中的安装目录边界 | 可能只是参数引用，不证明独占所有权 |
| Component | 驱动/设备名称与安装目录附带的 SYS/INF 名称匹配 | 可能共享，也可能来自旧版本 |
| Name | 产品名称与记录、数据目录或注册表键名称匹配 | 仅为候选，需要人工核对 |

每项保留来源、原始路径、状态及依据。附带驱动文件与实际系统驱动分开展示。没有验证数字签名，也没有将匹配结果当成删除授权。文件扫描跳过重解析点；数据目录与注册表键仅检查两层，不读取任意应用注册表值。设备清单不会覆盖驱动仓库中的全部未使用包，其他用户未加载的注册表也不在覆盖范围内。快照采集期间系统仍在变化，并非原子快照。

## 隐私

- 无遥测、服务器、自动上传或联网查询功能。
- 报告默认保存在 `%LOCALAPPDATA%\LocalSafe\Private`，位于仓库外，使用当前用户的本地目录权限；未额外加密。
- 报告可能包含用户名、安装路径、软件清单、任务参数及卸载命令，其中可能夹带敏感数据。请勿直接公开报告或截图。
- 仓库忽略常见报告、快照和日志文件；`.gitignore` 不是脱敏保证，手动改名或复制仍可能泄露。
- 示例及测试只使用虚构数据。提交前使用 `git diff --cached` 检查，不提交本机扫描产物、账户、凭证或个人绝对路径。

## 开发与验证

发布打包使用 `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\scripts\Build-Release.ps1`，从当前已提交的 Git 版本提取白名单文件，编译 Windows 启动器，在 `dist` 生成便携 ZIP 和 SHA-256 校验文件。本机缓存、报告和卸载记录不进入发行包。

核心模块 `src/LocalSafe.Core.psm1` 与 CLI、WPF 界面分离。GUI 将扫描放在后台作业运行，窗口保持响应。关闭窗口会停止本次后台作业。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Core.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Discovery.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Cache.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Uninstall.Tests.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Media.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Verdict.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Instance.Tests.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\AppIcon.Tests.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\CleanupConfirmation.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\ReviewPresentation.Tests.ps1
```

可选完整集成测试只创建临时目录与临时 HKCU 登记中的虚构软件，编译它自己的测试卸载 EXE，验证“卸载 → 查残留 → 确认 → 备份/隔离 → 复查”，结束后移除测试数据。不调用任何真实软件的卸载程序：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Uninstall.Integration.Tests.ps1 -RunFixture
```

后续继续完善：更强的组件归属证据、安装前后文件/注册表快照及进程事件关联、更完整的恢复界面和重启后验收。共享组件始终需要独立判断，不能以追求“零残留”为由直接删除厂商目录或系统历史记录。

沿用仓库 GPL-3.0 许可证，见 [LICENSE](LICENSE)。

界面改造参考 [unslop](https://heydamir.design/unslop)，作者 Damir Sokolovsky（[@heydamir](https://x.com/heydamir)），设计方法为 CC BY 4.0。项目未复制技能文档或参考图。
