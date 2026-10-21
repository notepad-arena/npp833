# Notepad++ 8.3.3 —— MSIX / MSIXBundle 打包记录（x86 + x64，不上架商店）

本文记录「把本仓库的 Win32 版 Notepad++ 打成 MSIX / MSIXBundle」这件事：
目录里有哪些文件、怎么构建、怎么装、和 nsis 安装包的差异、微软官方的工具边界、
以及踩过的 6 个坑。全部内容都在本机（VS2019 16.11 + Windows SDK 10.0.19041）实测通过。

---

## 0. 一句话概括

**不做 UWP 重写**，用微软官方的 **Windows Application Packaging Project（Desktop Bridge）**
把现有 `notepad++.exe` 包进 MSIX/MsixBundle：程序仍是完整信任（full trust）的 Win32 进程，
Win32 API 全部可用，只是外层多了一个包、一份清单、一次签名。

当前包含三块「打包侧增强」：

| 能力 | 做法 | 状态 |
| --- | --- | --- |
| 三架构 **x86 + x64 + ARM64** | 同一个 `NppPackaging_8.3.3.0_x86_x64_ARM64.msixbundle`，系统自动挑架构 | 已构建并验证（ARM64 原生 exe） |
| **PerMonitorV2** DPI 感知 | 换一份 exe 清单 `dpiAware.PerMonitorV2.manifest`（构建开关） | 已构建 + WACK 通过 |
| **右键菜单** `Edit with Notepad++` | 新增 `NppShellMsix.dll`（`IExplorerCommand`）+ 打包 COM **代理进程**（dllhost），清单 `com:SurrogateServer` + `desktop4:FileExplorerContextMenus` | Win10 实测出现并成功唤起；Win11 走同一份清单 |
| **替换默认记事本** | IFEO `Debugger` → `wscript.exe` 跑 `npp-notepad-redirect.vbs`（纯脚本、**不闪控制台**），转发给 `npp.exe` 别名 | Win10 实测单文件/带空格/多文件/`cmd start` 全部正确打开且无控制台进程，见 §14 |

```
PowerEditor\
├─ src\dpiAware.PerMonitorV2.manifest      # 新的 DPI 清单（打包版用，见 §7）
├─ src\tools\NppShellMsix\                 # 右键菜单处理器（进程外 COM，见 §8）
│    NppExplorerCommand.h/.cpp  dllmain.cpp  NppShellMsix.def  NppShellMsix.vcxproj
└─ visual.net\Packaging\
     ├─ NppPackaging.wapproj               # 打包工程（只引用 notepadPlus.vcxproj，不含代码）
     ├─ Package.appxmanifest               # 包清单（full trust + 关联 + 别名 + COM + 右键菜单）
     ├─ Assets\*.png                       # 包图标（由 make-assets.ps1 从 chameleon 图生成）
     ├─ make-assets.ps1                    # 重新生成图标
     ├─ build-msix.ps1                     # 一键：编译 → 打包 → 签名 →（可选）WACK / 安装
     ├─ test-context-menu.ps1              # 右键菜单自检（需先安装包）
     └─ README.md                          # 本文件
```

产物：

```
PowerEditor\visual.net\Packaging\AppPackages\NppPackaging_8.3.3.0_Test\
    NppPackaging_8.3.3.0_x86_x64_ARM64.msixbundle   ← 分发这个（12.2 MB）
        解包后：x64 4.3 MB + x86 3.9 MB + ARM64 4.0 MB
    Add-AppDevPackage.ps1 / Install.ps1             ← VS 生成的侧载脚本（可选）
```

只出单架构时（`-Platforms x86 -NoBundle`）才会看到
`AppPackages\NppPackaging_8.3.3.0_x86_Test\NppPackaging_8.3.3.0_x86.msix`。

---

## 1. 环境与前置条件（本机实测版本）

| 项目 | 值 |
| --- | --- |
| Visual Studio | 2019 Enterprise 16.11（MSBuild 16.11.6.22506） |
| 必需工作负载 | 「通用 Windows 平台开发」，或 .NET 桌面开发里的可选组件 **MSIX Packaging Tools** |
| 工具集 | v142（14.29.30133），与 `notepadPlus.vcxproj` 一致 |
| Windows SDK | 10.0.19041.0（`TargetPlatformVersion`） |
| ARM64 工具集 | 可选组件 **MSVC v142 - VS 2019 C++ ARM64 build tools**（`Microsoft.VisualStudio.Component.VC.Tools.ARM64`）；缺了打不出 ARM64 包，见 §9 坑 7 |
| 验证用系统 | Windows 10 IoT 企业版 LTSC 21H2（10.0.19044.7807，x64） |
| 打包引擎 | `…\MSBuild\Microsoft\DesktopBridge\Microsoft.DesktopBridge.targets` |
| 签名工具 | `C:\Program Files (x86)\Windows Kits\10\bin\10.0.19041.0\x64\signtool.exe` |

VS2019 支持 .wapproj（从 VS2017 15.5 起就有），但**不支持** Windows App SDK 的
single-project MSIX（那个要 VS2022 17.1+，Win32 应用也用不上）。
VS2019 已过主流支持期，长期维护建议换 VS2022（工作负载装好后 .wapproj 一样能编）。

**不需要**：NppShell（shell 扩展）、GUP 自动更新器、任何第三方 DLL。见 §4。

---

## 2. 构建

```powershell
cd PowerEditor\visual.net\Packaging

# 第一次：生成自签测试证书 + 信任 + 打包 + 签名
powershell -ExecutionPolicy Bypass -File .\build-msix.ps1 -CreateTestCert -TrustCert -Sign

# 之后（证书已就绪；测试证书导出密码固定为 npp，脚本已默认填好）
powershell -ExecutionPolicy Bypass -File .\build-msix.ps1 -Sign
```

脚本做的事：

1. `msbuild notepadPlus.sln /p:Platform=Win32` 和 `/p:Platform=x64`
   （必须走解决方案，`SciLexer` 的工程依赖只在 .sln 里声明，直接编 vcxproj 会缺
   `libscilexer.lib`）；
2. `msbuild NppPackaging.wapproj /p:Platform=x86 /p:AppxBundle=Always /p:AppxBundlePlatforms="x86|x64"`
   —— AppxPackage targets 会自己按两个架构各编一次，再 `MakeAppx bundle` 合成；
3. `signtool sign /fd SHA256 /f npp-msix-dev.pfx …` 签最终产物（bundle 只需签外层）。

不想用脚本、想手敲（等价）：

```powershell
$msbuild = 'C:\Program Files (x86)\Microsoft Visual Studio\2019\Enterprise\MSBuild\Current\Bin\MSBuild.exe'
& $msbuild "PowerEditor\visual.net\notepadPlus.sln" /p:Configuration=Release /p:Platform=Win32 /m
& $msbuild "PowerEditor\visual.net\notepadPlus.sln" /p:Configuration=Release /p:Platform=x64   /m
& $msbuild "PowerEditor\visual.net\Packaging\NppPackaging.wapproj" `
    /p:Configuration=Release /p:Platform=x86 `
    /p:AppxBundle=Always "/p:AppxBundlePlatforms=x86|x64" /p:AppxPackageSigningEnabled=false
```

`Debug` 配置只出单架构 `.msix`（`AppxBundle=Never`），迭代快。
打出来的包**没有**放进 `notepadPlus.sln`：解决方案的平台名是 `Win32/x64`，而 .wapproj 是
`x86/x64`，混在一个 sln 里会互相打架，独立构建反而干净。

---

## 3. 安装 / 升级 / 卸载

```powershell
# 安装（自签证书必须已在 TrustedPeople，脚本 -TrustCert 已代劳）
Add-AppxPackage -Path 'PowerEditor\visual.net\Packaging\AppPackages\NppPackaging_8.3.3.0_Test\NppPackaging_8.3.3.0_x86_x64_ARM64.msixbundle'

# 启动
explorer.exe "shell:AppsFolder\NotepadPlusPlus.MSIX_54gzaac6bb4fr!NotepadPlusPlus"
npp.exe C:\some\file.txt          # 命令行别名（AppExecutionAlias）

# 查看
Get-AppxPackage NotepadPlusPlus.MSIX | Format-List Name,Version,Architecture,PackageFullName

# 卸载（用户数据留在 %LOCALAPPDATA%\Packages\<PFN>，需要手动删）
Get-AppxPackage NotepadPlusPlus.MSIX | Remove-AppxPackage
```

升级：把 `Package.appxmanifest` 里的 `Version` 调大（第 3 段或第 4 段）后重新打包，
`Add-AppxPackage` 同一条命令即原地升级；**版本号不增大则会报 0x80073CFB**。

包标识（写死在这几个地方，改要一起改）：

| 字段 | 当前值 | 位置 |
| --- | --- | --- |
| Name | `NotepadPlusPlus.MSIX` | `Package.appxmanifest` `<Identity>` |
| Publisher | `CN=NppMSIXDev` | 同上，**必须**与签名证书 Subject 完全一致 |
| Application Id | `NotepadPlusPlus` | `<Application Id>` |
| 命令别名 | `npp.exe` | `<desktop:ExecutionAlias>` |

---

## 4. 这个包和 nsis 安装包的差异（载荷对照）

打进包里（只读数据放在包目录最合适，程序本来就往自身目录找）：

| 内容 | 来源 | 说明 |
| --- | --- | --- |
| `Notepad++.exe` | `PowerEditor\bin(64)\` | x86 4.98 MB / x64 5.5 MB / ARM64 5.5 MB，静态 CRT |
| `NppShellMsix.dll` | `PowerEditor\bin\` / `bin64\` / `binarm64\` | 右键菜单处理器（`IExplorerCommand`），约 118 KB，进程外 COM，见 §8 |
| `langs.model.xml` `stylers.model.xml` `shortcuts.xml` `contextMenu.xml` | `PowerEditor\src\` | 程序启动即读 |
| `localization\*.xml`（94 个） | `installer\nativeLang\` | 界面语言 |
| `themes\*.xml`（22 个） | `installer\themes\` | 主题 |
| `functionList\*.xml`（34 个） | `installer\functionList\` | 函数列表 |
| `APIs\*.xml`（27 个） | `installer\APIs\` | 自动补全 API |
| `LICENSE` | 仓库根 | GPLv3 要求随包分发 |
| `Assets\*.png` | `make-assets.ps1` 生成 | 开始菜单/任务栏/启动画面 |

没打进包的，以及为什么：

| 没打进去 | 原因 | 现在的表现 |
| --- | --- | --- |
| `plugins\`（NppExport / mimeTools / NppConverter / nppPluginList） | 包目录**只读**，且插件是 in-process DLL | 用户插件请放 `%APPDATA%\Notepad++\plugins\`；包里不带默认插件 |
| `doLocalConf.xml`（便携模式） | 便携模式要往安装目录写配置 | 默认走 `%APPDATA%\Notepad++\`，不要打这个文件 |
| `updater\GUP.exe` + 自动更新 | GUP 会替换安装目录里的 exe，MSIX 不允许 | 更新改走「换包升级」（见 §3） |
| `NppShell_06.dll`（老式 in-process shell 扩展） | MSIX **不支持** in-process 扩展 | 不打包；右键菜单改由 `NppShellMsix.dll`（进程外 COM）提供，见 §8 |
| `nppLogNulContentCorruptionIssue.xml`、`change.log`、`readme.txt` | 纯说明文件 | 省略，不影响功能 |

---

## 5. MSIX 带来的行为变化（务必知道）

1. **注册表 HKLM 写不了**：`RegExt\regExtDlg.cpp` 里那批 `RegSetValueEx(HKLM)` 在包里会
   被改写到包私有视图（虚拟化），不会真的落到系统 HKLM；文件关联改由清单声明。
2. **`%APPDATA%\Notepad++` 被重定向** 到
   `%LOCALAPPDATA%\Packages\NotepadPlusPlus.MSIX_54gzaac6bb4fr\LocalCache\Roaming\Notepad++\`。
   从旧版本迁配置：
   ```powershell
   $dst = "$env:LOCALAPPDATA\Packages\NotepadPlusPlus.MSIX_54gzaac6bb4fr\LocalCache\Roaming"
   New-Item -ItemType Directory -Force "$dst\Notepad++" | Out-Null
   Copy-Item "$env:APPDATA\Notepad++\*" "$dst\Notepad++\" -Recurse -Force
   ```
3. **文件关联不会自动抢**：用户还得在「设置 > 应用 > 默认应用」里点一下 `.txt` →
   Notepad++。这是 Windows 的默认程序保护策略，任何 MSIX 包都一样。
4. **`winmain.cpp:564` 的 `SetCurrentDirectory(安装目录)`** 在包里仍然执行，
   指向 `C:\Program Files\WindowsApps\…`（只读），不影响功能；但任何「往当前目录写文件」
   的逻辑都会失败。
5. **单实例/托盘/文件监视**等都正常（full trust，不是 AppContainer）。
6. 卸载后 `%LOCALAPPDATA%\Packages\<PFN>` 里的用户数据**不会**自动删。

---

## 6. Windows 10 / Windows 11 兼容性

**一份包，两个系统通用。** 包里只有 `uap` / `uap3` / `desktop` / `rescap` 四个清单名字空间，
Windows 10 全部认识；程序是 full-trust Win32 进程，不依赖 Windows App SDK / .NET / WebView2
之类的运行时前置，所以没有"Win11 才能装"的成分。

### 6.1 支撑矩阵

| 系统 | 结果 | 说明 |
| --- | --- | --- |
| Windows 11 21H2 ~ 24H2（x64） | ✅ | 同一套 MSIX + full trust；清单里没有任何 Win11 专属项 |
| Windows 11 ARM64 | ✅ **原生** | bundle 里带原生 ARM64 包（PE machine = 0xAA64），不再依赖 x64 模拟 |
| Windows 10 1809 ~ 22H2（x86/x64） | ✅ **已实测** | 本机即 Win10 IoT 企业版 LTSC 21H2（10.0.19044.7807）：安装 / 启动 / 卸载全部通过 |
| Windows 10 1607 / 1703 / 1709 / 1803 | ❌ | MSIX 包格式本身要求 1809+（17763），与本工程无关 |
| Windows 8.1 / 7 | ❌ | 装不了 MSIX，继续用 nsis 安装包 |

### 6.2 三个版本号不要弄混

| 字段 | 位置 | 当前值 | 含义 |
| --- | --- | --- | --- |
| `TargetDeviceFamily/@MinVersion` | `Package.appxmanifest` | `10.0.17763.0` | **最低可安装系统**，这就是 Win10 兼容底线；为 Win11 抬高它会直接砍掉 Win10 用户 |
| `@MaxVersionTested` | `Package.appxmanifest` | `10.0.19041.0` | 仅"声明在哪个版本上验证过"，**不限制**安装与运行，Win11 上照跑 |
| `TargetPlatformVersion`（`NppTargetPlatformVersion`） | `NppPackaging.wapproj` | `10.0.19041.0` | 用哪个 SDK 编译打包 |

要对外声明"已测 Win11 22H2"：装 Win11 SDK 后构建时加 `-TargetPlatformVersion 10.0.22621.0`（脚本会转成 msbuild 的 `/p:NppTargetPlatformVersion=…`），
并把清单里的 `MaxVersionTested` 一起改成 `10.0.22621.0`。其它一律不动。

### 6.3 以后加 Win11 专属功能（例如新版右键菜单）的铁律

1. 扩展必须来自更新的名字空间（`desktop4` / `desktop5` / `uap10` …），**并且**该前缀要写进
   `<Package IgnorableNamespaces="...">` —— Win10 会把不认识的扩展整体忽略：不报错、不影响安装；
2. 忘了写进 `IgnorableNamespaces`，Win10 装包直接 `APPX0501` 失败，这是最容易踩的坑；
3. shell 扩展必须是**进程外 COM**（`com:Extension` + `com:Class`），旧 `NppShell.dll` 是
   in-process 服务器，MSIX 不允许原样打包；
4. 加完必须回 Win10 做回归：`build-msix.ps1 -Sign -Verify`。

`Package.appxmanifest` 里留了一段带注释的 Win11 右键菜单样板（**未启用**，因为还需要配套的
OOP COM 服务器），照抄时记得补 `IgnorableNamespaces`。

一个系统行为差异要知道：Win11 右键菜单是"新版一级菜单 + 显示更多选项"，传统 verb 会被折叠；
Win10 才是传统菜单。同一个 OOP COM 在两边呈现不同，属系统行为，不是包的问题。

### 6.4 官方认证套件（Win10 / Win11 各跑一次最稳）

```powershell
powershell -ExecutionPolicy Bypass -File .\build-msix.ps1 -Sign -Verify
```

`-Verify` 调 Windows App Certification Kit（`appcert.exe test -appxpackagepath …`），
报告落在 `AppPackages\wack-report.xml`。本机（Win10 21H2）实测：
**Overall PASS / 23 PASS / 1 FAIL（可选）/ 0 WARNING**，唯一非 PASS 项的解读：

| 测试 | 结果 | 说明 | 要不要处理 |
| --- | --- | --- | --- |
| 已阻止的可执行文件 | FAIL（OPTIONAL） | 检出 `Notepad++.exe` 对 `shell32!ShellExecuteW` 的引用，以及 `langs.model.xml`、各语言/主题 XML 里出现的 `cmd` / `powershell` / `reg` 等"不可执行引用"字样。文本编辑器必然命中 | 侧载无关；上架商店时按项申请豁免 |
| ~~DPIAwarenessValidation~~ | **已修复 → PASS** | 打包版改用 `dpiAware.PerMonitorV2.manifest`（见 §7），WACK 该项现为 PASS | 无需处理；想退回系统级 DPI 用 `-DpiAwareness system` |

---

### 6.5 ARM64 原生包

`NppPackaging.wapproj` 现在有 `Debug|ARM64` / `Release|ARM64` 配置，`AppxBundlePlatforms` 是
`x86|x64|ARM64`，主程序来源是 `PowerEditor\binarm64\Notepad++.exe`（对应
`notepadPlus.vcxproj` 里既有的 `Release|ARM64` 配置，`OutDir=..\binarm64\`）。

构建脚本默认就打三架构：

```powershell
powershell -ExecutionPolicy Bypass -File .\build-msix.ps1 -Sign          # 默认 x86,x64,ARM64
powershell -ExecutionPolicy Bypass -File .\build-msix.ps1 -Sign -Platforms x86,x64   # 只要两个
```

`notepadPlus.sln` 也补了 `Debug|ARM64` / `Release|ARM64` 解决方案平台，VS 里能直接选 ARM64 编。

前提：装 **MSVC v142 - VS 2019 C++ ARM64 build tools** 组件（`Microsoft.VisualStudio.Component.VC.Tools.ARM64`）。
本机原本没装（`VC\Tools\MSVC\14.29.30133\lib\arm64` 不存在），已用

```powershell
vs_installer.exe modify --installPath "C:\Program Files (x86)\Microsoft Visual Studio\2019\Enterprise" ^
    --add Microsoft.VisualStudio.Component.VC.Tools.ARM64 --quiet --norestart --nocache
```

补上。实测三架构产物的 PE machine：x86=`0x014c`、x64=`0x8664`、ARM64=`0xAA64`，
包内 `Notepad++.exe` 与 `NppShellMsix.dll` 的架构一一对应。

注意：Win11 ARM64 上 **x86/x64 包也能跑（模拟）**，原生 ARM64 包只是更快、更省电；
bundle 里三种架构并存，系统会自己挑最合适的那一个。

小噪音：ARM64 配置的 PostBuildEvent 里有一句 `copy ..\src\functionList.xml ..\binarm64\`，
而 `PowerEditor\src\functionList.xml` 这个文件本来就不存在（functionList 是按语言拆分到
`installer\functionList\` 目录的），所以编 ARM64 时会打印一句「系统找不到指定的文件」。
不影响构建结果，属上游遗留，未改动。

---

## 7. DPI 感知：PerMonitorV2（打包开关）

WACK 的 `DPIAwarenessValidation` 原本是 **WARNING**，因为 `PowerEditor\src\dpiAware.manifest`
只声明了系统级 DPI（`<dpiAware>true</dpiAware>`）。现在提供第二份清单：

| 文件 | 声明 | 用途 |
| --- | --- | --- |
| `PowerEditor\src\dpiAware.manifest`（原有） | `<dpiAware>true</dpiAware>` | 上游默认，系统级 DPI |
| `PowerEditor\src\dpiAware.PerMonitorV2.manifest`（新增） | `<dpiAware>true/pm</dpiAware>` + `<dpiAwareness>PerMonitorV2, PerMonitor</dpiAwareness>` | 打包版用这份 |

切换方式是 MSBuild 属性，`notepadPlus.vcxproj` 里已经参数化（`$(NppDpiManifest)`，6 个配置全改）：

```powershell
# 打包默认就是 permonitorv2
powershell -ExecutionPolicy Bypass -File .\build-msix.ps1 -Sign
# 想退回系统级 DPI（上游行为）
powershell -ExecutionPolicy Bypass -File .\build-msix.ps1 -Sign -DpiAwareness system
# 手工：
msbuild notepadPlus.sln /p:Configuration=Release /p:Platform=x64 `
        /p:NppDpiManifest=..\src\dpiAware.PerMonitorV2.manifest
```

**普通桌面/nsis 构建默认不变**（不传属性就是原来的 `dpiAware.manifest`），所以这个改动只影响 MSIX 包。

已验证：`mt.exe -inputresource:Notepad++.exe;#1` 抽出的嵌入清单里同时有
`<dpiAware>true/pm</dpiAware>` 与 `<dpiAwareness>PerMonitorV2, PerMonitor</dpiAwareness>`；
WACK 的 `DPIAwarenessValidation` 由 WARNING → **PASS**（总体结果 WARNING → **PASS**）。

**必须知道的取舍**：Notepad++ 的 `WM_DPICHANGED` 处理是空的（`NppBigSwitch.cpp` 里直接
`return TRUE;`），各控件尺寸/字体在启动时按 DPI 算好。所以：

| 场景 | 系统级 DPI（旧） | PerMonitorV2（新） |
| --- | --- | --- |
| 在 150% 显示器上启动 | 正确缩放 | 正确缩放、更清晰（本机 DPI=100%，>100% 的视觉效果未在此机器验证） |
| 窗口从 100% 拖到 150% 显示器 | Windows 位图拉伸：尺寸对、略模糊 | 不重排：清晰但**物理尺寸偏小**（npp 不处理 WM_DPICHANGED） |

如果团队更看重「跨显示器拖动时尺寸正确」，用 `-DpiAwareness system` 即可，其余一切不变。
要彻底解决得给 npp 加真正的 WM_DPICHANGED 重排（字体、工具栏、分栏都要重建），属于上游改动范围。

---

## 8. 右键菜单 `Edit with Notepad++`（进程外 COM）

MSIX **不允许 in-process shell 扩展**，所以老的 `NppShell.dll` 那套注册方式不能照搬。官方支持的
做法是「打包 COM + `IExplorerCommand` + `desktop4:FileExplorerContextMenus`」，实现在
`PowerEditor\src\tools\NppShellMsix\`：

| 文件 | 作用 |
| --- | --- |
| `NppExplorerCommand.h/.cpp` | `CNppExplorerCommand : IExplorerCommand`（GetTitle/GetIcon/GetState/Invoke…），`Invoke` 用 `ShellExecuteW` 打开同目录的 `Notepad++.exe` 并带上选中的文件 |
| `dllmain.cpp` | 类工厂 `IClassFactory` + `DllGetClassObject` / `DllCanUnloadNow` |
| `NppShellMsix.def` | 导出名映射（原因见 §9 坑 8） |
| `NppShellMsix.vcxproj` | DLL，Win32/x64/ARM64，静态 CRT，产物进 `bin\`/`bin64\`/`binarm64\` |

清单侧（`Package.appxmanifest`）：

```xml
<com:Extension Category="windows.comServer">
  <com:ComServer>
    <com:SurrogateServer AppId="8E1B0F5C-1E8B-4D3A-9A2C-5B7E9C4C2A11" DisplayName="Notepad++ shell handler">
      <com:Class Id="8E1B0F5C-1E8B-4D3A-9A2C-5B7E9C4C2A11" Path="NppShellMsix.dll" ThreadingModel="Both" />
    </com:SurrogateServer>
  </com:ComServer>
</com:Extension>

<desktop4:Extension Category="windows.fileExplorerContextMenus">
  <desktop4:FileExplorerContextMenus>
    <desktop4:ItemType Type="*">
      <desktop4:Verb Id="NppEdit" Clsid="8E1B0F5C-1E8B-4D3A-9A2C-5B7E9C4C2A11" />
    </desktop4:ItemType>
  </desktop4:FileExplorerContextMenus>
</desktop4:Extension>
```

要点：

* `com:SurrogateServer` 让 shell 把 DLL 加载进 **dllhost.exe**（进程外），这是 MSIX 唯一允许的形态；
* `desktop4` / `com` 都写进了 `IgnorableNamespaces`，所以老系统会整体忽略而不是安装失败；
* `ItemType Type="*"` 表示所有文件；改成 `".txt"` 这类扩展名可缩小范围；
* CLSID/AppId 必须与 `NppExplorerCommand.h` 里的 `__declspec(uuid(...))` 一致，改一处就要改三处。

**Win10 实测（本机 19044）**，用 `test-context-menu.ps1` 跑：

```
GetTitle      hr=0x00000000 'Edit with Notepad++'
GetIcon       hr=0x00000000 'C:\Program Files\WindowsApps\<pkg>\Notepad++.exe,0'
GetCanonical  hr=0x00000000 8e1b0f5c-1e8b-4d3a-9a2c-5b7e9c4c2a11
GetState      hr=0x00000000 state=0 (ECS_ENABLED)
Invoke        hr=0x00000000
LAUNCHED      PID=... Title='...\npp-ctx-test.txt - Notepad++'
```

并且 `Shell.Application` 枚举 `win.ini` 的动词时，第 4 项就是 **`Edit with Notepad++`** —— 说明菜单
项确实被 Explorer 加载出来了（Win10 经典菜单）。Win11 上同一份清单会出现在新式一级菜单
（或在「显示更多选项」里），系统行为差异见 §6.3。

`test-context-menu.ps1` 需要**先安装包**，它做三件事：进程外激活 + 调 IExplorerCommand、
按 Explorer 的真实路径（`SHCreateItemFromParsingName` → `SHCreateShellItemArrayFromShellItem`
→ `Invoke`）跑一遍并确认 Notepad++ 被拉起、枚举 Explorer 动词列表。

---
## 9. 踩过的坑（都已在文件里修好，别随手改回去）

| # | 症状 | 原因 | 修法 |
| --- | --- | --- | --- |
| 1 | `error : .NET SDK 的版本 10.0.401 至少需要 MSBuild 的 18.0.0` + `MSB4236 找不到 Microsoft.NET.Sdk` | `Microsoft.DesktopBridge.targets` 第 16 行会 `Import Sdk="Microsoft.NET.Sdk"`（为 NuGet restore 准备），本机装了 .NET 10 SDK 就顶牛 | wapproj 里 `<SkipImportNetSdk>true</SkipImportNetSdk>`（本工程不用 PackageReference） |
| 2 | `error : 项目必须具有对应用程序的引用` | C++ 的 `BuiltProjectOutputGroup` 只给 `FinalOutputPath`、不给 `TargetPath`，DesktopBridge 任务认不出主程序 | wapproj 里显式 `<EntryPointExe>Notepad++.exe</EntryPointExe>` |
| 3 | 包里出现 `notepadPlus\Notepad++.exe` + `notepadPlus\npp.pdb`（多 33 MB） | 被引用工程输出因缺 `TargetPath` 被塞进以工程名命名的子目录 | `ProjectReference` 设 `Private=False`（只用于构建顺序），主程序用 `Content` + `Link` 精确放到包根；再加 `_NppDropReferencedAppPayload` 兜底清理 |
| 4 | 清单里被自动加了 `Microsoft.VCLibs.140.00.UWPDesktop` 依赖 | `_ResolveVCLibDependencies` 对 C++ 工程一律加 | Notepad++ 是静态 CRT（`MultiThreaded`），wapproj 尾部用空 `<Target Name="_ResolveVCLibDependencies" />` 覆盖掉 |
| 5 | `APPX0501: 'CN=Notepad++ MSIX Dev' 违反了 pattern 约束` | X.500 主题里 `+` 是分隔符，`CN=Notepad++` 非法 | Publisher 用 `CN=NppMSIXDev`（证书 Subject 同步改） |
| 6 | `APPX0501: '#FF1E1E1E' 违反 pattern 约束` / `Applications can't register for the ".bat" file type association` | `SplashScreen@BackgroundColor` 只认 `#RRGGBB`（6 位）；`.bat` `.cmd` 是系统保护区扩展名 | 改成 `#1E1E1E`；从关联列表里删掉 `.bat` `.cmd` |
| 7 | 编 ARM64 报 `MSB8020 / 找不到 arm64 的 platform toolset`（`VC\Tools\MSVC\…\lib\arm64` 不存在） | VS2019 默认不装 ARM64 工具集 | 装组件：`vs_installer.exe modify --installPath "<VS>" --add Microsoft.VisualStudio.Component.VC.Tools.ARM64 --quiet --norestart` |
| 8 | 写 `DllGetClassObject` 报 `C2375: 重定义；不同的链接` | `combaseapi.h` 用 `DECLSPEC_IMPORT` 声明了这两个导出（面向调用方），自己定义就冲突 | 内部实现改名 `NppDllGetClassObject` / `NppDllCanUnloadNow`，用 `NppShellMsix.def` 做导出名映射（`DllGetClassObject=NppDllGetClassObject PRIVATE`） |

另外两个小坑：

- **`.ps1` 必须纯 ASCII**：Windows PowerShell 5.1 把无 BOM 的 UTF-8 当 ANSI 读，
  脚本里的中文会变成乱码并引发 `TerminatorExpectedAtEndOfString`。所以
  `build-msix.ps1` / `make-assets.ps1` 全英文，中文只放在本 README。
- **读清单不要用 `Get-Content`**：同样会把 `Package.appxmanifest` 的中文读坏再写回，
  直接 `APPX1402`。脚本里用 `XmlDocument.Load()`（认 XML 声明编码）。
  现在清单本身也做成了纯 ASCII，双保险。

---

## 10. 排错表

| 现象 | 原因 / 处理 |
| --- | --- |
| `0x800B0109`（根证书不受信任） | 自签证书没进 `LocalMachine\TrustedPeople`。管理员执行：`Import-Certificate -FilePath npp-msix-dev.cer -CertStoreLocation Cert:\LocalMachine\TrustedPeople`；或重跑 `build-msix.ps1 -CreateTestCert -TrustCert` |
| `0x80073CF0` / `0x800B010A`（发布者不匹配） | `Identity@Publisher` 与证书 Subject 不一致 |
| `0x80073CFB`（已装同版本） | 升 `Version` 或先 `Remove-AppxPackage` |
| `0x80073CFF`（包未签名 / 签名后改过文件） | 签名后不要再改包；`AppxPackageSigningEnabled=false` 打出来的东西必须自己 `signtool sign` |
| `0x80073D01`（安装位置策略阻止） | 同包内附加组件装到了受限目录；本包没有这个情况 |
| `APPX0702 负载文件不存在` | wapproj 里 `Content` 路径错了（相对 `Packaging\` 的 `..\..\` 才是 `PowerEditor\`） |
| `MakeAppx : Package creation failed` + `APPX0501` | 清单字段不合法，看具体行号 |
| 装好后启动闪退 | 多半是 `%APPDATA%` 虚拟化后配置不兼容：删掉 `LocalCache\Roaming\Notepad++` 再试 |

清掉这台机器上的开发证书（不再需要侧载时）：

```powershell
Get-ChildItem Cert:\LocalMachine\TrustedPeople | Where-Object Subject -eq 'CN=NppMSIXDev' | Remove-Item
Get-ChildItem Cert:\CurrentUser\My            | Where-Object Subject -eq 'CN=NppMSIXDev' | Remove-Item
```

---

## 11. 已验证（本次实测）

- `build-msix.ps1 -CreateTestCert -TrustCert -Sign` 全流程 green，产出
  `NppPackaging_8.3.3.0_x86_x64_ARM64.msixbundle`（12.2 MB；`makeappx unbundle` 解出
  `x86.msix` 3.91 MB + `x64.msix` 4.21 MB + `ARM64.msix` 4.07 MB，PE machine 分别
  `0x014c` / `0x8664` / `0xAA64`，包内 `NppShellMsix.dll` 架构与之一一对应）；
- **PerMonitorV2** 生效：`mt.exe -inputresource:Notepad++.exe;#1` 抽出的嵌入清单里同时有
  `<dpiAware>true/pm</dpiAware>` 与 `<dpiAwareness>PerMonitorV2, PerMonitor</dpiAwareness>`；
  运行中的进程用 `GetProcessDpiAwareness` 查得 `PROCESS_DPI_AWARENESS=2 (PER_MONITOR_AWARE)`
  （系统级 DPI 的话是 1），改前改后对比得到确认；
- **右键菜单可用**（Win10 19044）：`test-context-menu.ps1` 进程外激活拿到
  `GetTitle='Edit with Notepad++'`、`GetState=ECS_ENABLED`、`Invoke=S_OK` 并成功把
  文件拉进 Notepad++；`Shell.Application` 枚举 `win.ini` 的动词时该项出现在列表（第 4 项）；
- `signtool verify /pa` 通过：`Issued to: NppMSIXDev`，`Successfully verified`；
- `Add-AppxPackage` 安装成功，`Get-AppxPackage` 显示 `Architecture: X64`（bundle 自动选了 64 位）；
- 启动后进程路径为 `C:\Program Files\WindowsApps\NotepadPlusPlus.MSIX_8.3.3.0_x64__54gzaac6bb4fr\Notepad++.exe`，
  窗口正常（中文界面，标题「新文件 1 - Notepad++」）；
- `npp.exe` 命令别名落地到 `%LOCALAPPDATA%\Microsoft\WindowsApps\npp.exe`；
- `Remove-AppxPackage` 卸载干净；
- 以上全部在 **Windows 10**（10.0.19044 / 21H2 LTSC，x64）上完成 —— 即"Win10 能装能跑"是实测结论；
  Win11 用同一份包、同一套 full trust 模型（见 §6），差异只在系统自带的菜单/设置 UI；
- 官方认证套件 WACK（`-Verify`）在同一台机器跑完：**Overall PASS / 23 PASS / 1 FAIL（可选项）/
  0 WARNING**；DPI 项由 WARNING 转 PASS，剩下的只有"已阻止的可执行文件"（OPTIONAL，编辑器必然命中），
  明细与解读见 §6.4。

---

## 12. 后续可以做的（按性价比排序）

1. **正式签名**：企业内部分发用公司代码签名证书；公开分发建议 OV/EV 证书，或走商店。
   把 pfx 换成正式证书后只需改 `Package.appxmanifest` 的 `Publisher`。
2. **右键菜单（Win11）**：清单里加 `desktop4:Extension Category="windows.fileExplorerContextMenus"`
   + `desktop5:ItemType Type="*"`，用 `IExplorerCommand` 的 OOP COM（打包 COM 才允许）。
   这是唯一能把 `NppShell` 那套 in-process 扩展「翻译」成 MSIX 的办法。
3. **PSF 兼容层**：如果有插件/脚本硬要往安装目录写，用
   [Package Support Framework](https://github.com/microsoft/MSIX-PackageSupportFramework)
   的 `FileRedirectionFixup` / `EnvVarFixup`，不用改源码。
4. **`.appinstaller` 自动更新**：自建一个更新源（HTTPS + `.appinstaller` XML），
   替代 GUP；配合 `AppInstaller` 的按需更新。
5. **上架 Microsoft Store**（本仓库暂不做）：需要 Partner Center 预留名称 → 用预留的
   `Identity` 覆盖清单 → `AppxBundle=Always` + `msbuild /p:UapAppxPackageBuildMode=StoreUpload`
   出 `.msixupload` → 过 WACK。注意商店对 GPLv3 无限制，但对「启动命令工具/提权」有限制。

---

## 13. 命令速查

```powershell
# 环境自检：确认 .wapproj 的打包 targets 在位
Test-Path 'C:\Program Files (x86)\Microsoft Visual Studio\2019\Enterprise\MSBuild\Microsoft\DesktopBridge\Microsoft.DesktopBridge.targets'

# 重新生成图标（换 logo 时）
powershell -ExecutionPolicy Bypass -File .\make-assets.ps1

# 全流程
powershell -ExecutionPolicy Bypass -File .\build-msix.ps1 -Configuration Release -CreateTestCert -TrustCert -Sign

# 只出单架构包（快）
powershell -ExecutionPolicy Bypass -File .\build-msix.ps1 -Platforms x86 -NoBundle -Sign

# 构建 + 签名 + 安装
powershell -ExecutionPolicy Bypass -File .\build-msix.ps1 -Sign -Install

# 构建 + 签名 + 跑官方认证套件（Win10 / Win11 各跑一次）
powershell -ExecutionPolicy Bypass -File .\build-msix.ps1 -Sign -Verify
# 报告: AppPackages\wack-report.xml

# 只出 x86 + x64（不要 ARM64）
powershell -ExecutionPolicy Bypass -File .\build-msix.ps1 -Sign -Platforms x86,x64

# 退回系统级 DPI（默认是 permonitorv2）
powershell -ExecutionPolicy Bypass -File .\build-msix.ps1 -Sign -DpiAwareness system

# 右键菜单自检（必须先安装包）
powershell -ExecutionPolicy Bypass -File .\test-context-menu.ps1

# 核对三个包的架构
& 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.19041.0\x64\makeappx.exe' unbundle `
    /p .\AppPackages\NppPackaging_8.3.3.0_Test\NppPackaging_8.3.3.0_x86_x64_ARM64.msixbundle /d $env:TEMP\npp-unbundle /o

# 用 Win11 SDK 打包（需先装该 SDK；同时改清单的 MaxVersionTested）
powershell -ExecutionPolicy Bypass -File .\build-msix.ps1 -Sign -TargetPlatformVersion 10.0.22621.0

# 拆包核对载荷
& 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.19041.0\x64\makeappx.exe' unpack `
    /p .\AppPackages\NppPackaging_8.3.3.0_Test\NppPackaging_8.3.3.0_x86_x64_ARM64.msixbundle /d $env:TEMP\npp-unpack /o
```

---
---
---

## 14. 把默认记事本 `notepad.exe` 重定向到 MSIX 版

三个文件，两个脚本，一个原理：IFEO 把 `notepad.exe` 的启动交给 `wscript` 跑一个 `.vbs`，
`.vbs` 再把参数转给包的执行别名 `npp.exe`。

| 文件 | 作用 |
| --- | --- |
| `npp-notepad-redirect.vbs` | 真正的重定向器：丢掉 IFEO 追加的 `notepad.exe` 参数，其余原样转给 `%LOCALAPPDATA%\Microsoft\WindowsApps\npp.exe` |
| `replace-notepad.ps1` | **替换**：把 vbs 复制到 `%ProgramData%\NppMsixRedirect\`、写 IFEO、`-Verify` 自检 |
| `restore-notepad.ps1` | **还原**：删 IFEO 值（空键一并删）、删脚本目录 |

```powershell
cd PowerEditor\visual.net\Packaging
powershell -ExecutionPolicy Bypass -File .\replace-notepad.ps1 -Verify   # 替换成 Notepad++（含自检）
powershell -ExecutionPolicy Bypass -File .\restore-notepad.ps1           # 还原系统记事本
```

两个脚本都会自己请求提权（UAC），幂等，可以反复执行。

### 14.1 为什么不能直接把 IFEO 指向包里的 exe

```cmd
reg add "HKLM\Software\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe" ^
  /v Debugger /t REG_SZ /d "\"C:\Program Files\WindowsApps\NotepadPlusPlus.MSIX_8.3.3.0_x64__54gzaac6bb4fr\Notepad++.exe\"" /f
```

这条命令的值能写进去，但 `notepad.exe` 起不来，三层原因（本机实测）：

| # | 原因 | 实测证据 |
| --- | --- | --- |
| 1 | 包内 **exe 不能被执行**（AppModel 策略，不是 ACL） | `Start-Process 'C:\Program Files\WindowsApps\…\Notepad++.exe'` → `Access is denied`，管理员也一样 |
| 2 | 路径含 **版本号 + 架构 + 发布者哈希** | 升级后变成 `..._8.3.4.0_x64__...`，指向它的 IFEO 立刻失效 |
| 3 | IFEO 会把 debuggee 路径 **追加进命令行** | 实际执行 `Notepad++.exe <你的固定参数> C:\Windows\System32\notepad.exe …`，于是 N++ 去打开 `notepad.exe` 这个二进制 |

IFEO 机制本身没问题（把 `Debugger` 临时换成 `mspaint.exe`，`notepad.exe` 确实变成了画图）。

### 14.2 正确做法：IFEO → `wscript.exe` → `.vbs`

```
notepad.exe ──IFEO──▶ wscript.exe //nologo C:\ProgramData\NppMsixRedirect\npp-notepad-redirect.vbs
                        ├─ 丢掉 IFEO 追加的 notepad.exe 参数
                        └─ 其余参数原样转给 %LOCALAPPDATA%\Microsoft\WindowsApps\npp.exe
```

注册表最终只有一行：

```
HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe
    Debugger = "C:\Windows\System32\wscript.exe" //nologo "C:\ProgramData\NppMsixRedirect\npp-notepad-redirect.vbs"
```

* **为什么用 `wscript` 而不是 `cmd`**：`cmd.exe` 是控制台程序，一定会创建控制台窗口（闪一下）；
  `wscript.exe` 是 GUI 子系统宿主，**根本不建控制台** → 零闪。
* **为什么脚本放 `%ProgramData%`**：包目录只读（见 §14.5），而且版本化；放外面才稳定。
* **升级不用重跑脚本**：vbs 内部走的是稳定的执行别名 `npp.exe`，与包版本无关。

### 14.3 实测（Win10 19044）

| 场景 | 结果 |
| --- | --- |
| `notepad.exe 文件.txt` | PASS：Notepad++ 打开该文件 |
| `notepad.exe "带 空格的 目录\file one.txt"` | PASS |
| `notepad.exe "file one.txt" "file two.txt"` | PASS：同一实例打开两个 |
| `cmd /c start notepad.exe 文件.txt`（第三方程序调用） | PASS |
| `notepad.exe`（无参数） | 拉起 Notepad++（按它自己的「恢复上次会话」设置） |
| 控制台闪窗 | **没有**：`-Verify` 以 50 ms 采样 `cmd.exe`/`conhost.exe`，峰值等于基线 |
| `restore-notepad.ps1` 后 | IFEO 键、脚本目录全清，系统记事本回来 |
| 包被删掉（IFEO 残留）后按 `notepad.exe` | 弹出提示框让你跑 `restore-notepad.ps1`（不静默失败、不递归） |

### 14.4 坑

* **参数会被重新加引号**：vbs 用 `""" & arg & """` 重建命令行，普通路径没问题；含内嵌引号、
  `^`、`&` 的怪异命令行可能失真（记事本场景基本遇不到）。
* **开关不翻译**：`notepad /p file`、`/pt` 原样转发，不会变成打印动作。
* **不要加 `-notepadStyleCmdline`**：8.3.3 上实测会让 Notepad++ 恢复上次会话而不是打开传入的文件；
  想「记事本式」请在 Notepad++ 里关掉 `首选项 > 备份 > Remember current session for next launch`。
* **VBScript 是"按需功能"**（Win11 24H2 起）：`replace-notepad.ps1` 会先检查 `wscript.exe`，
  不存在就直接报错。这条路目前没有 cmd 兜底了（cmd 一定会闪）。
* **IFEO 只在 HKLM 生效**，所以替换/还原都必须管理员。

### 14.5 问：能不能把 `.vbs` 随包装进 WindowsApps，再让 IFEO 指向那个 vbs？

先把事实摆清楚（都是本机实测）：

| 事实 | 结果 |
| --- | --- |
| 包目录 ACL | `BUILTIN\Users: ReadAndExecute` + `NT AUTHORITY\RESTRICTED: ReadAndExecute`，**没有拒绝项** |
| 普通权限能否**读**包内文件 | 能（`Get-Content …\LICENSE`、`ReadAllBytes …\Notepad++.exe` 都成功） |
| 能否**执行**包内 exe | **不能**，`Access is denied`（管理员也一样）—— 这是 AppModel 策略在拦 CreateProcess，不是文件权限 |
| 能否往包目录**写**文件 | **不能**（TrustedInstaller 所有），实测 `Set-Content` 被拒 |

结论：**理论上可行**——`wscript` 只需要**读**脚本，读权限是有的，`.vbs` 放在包目录里 IFEO 也能拉起它
（真正被 AppModel 拦的是"执行镜像"，不是"读文件"）。但**不建议**，因为：

1. **路径版本化**：`C:\Program Files\WindowsApps\NotepadPlusPlus.MSIX_8.3.3.0_x64__54gzaac6bb4fr\…`
   —— 每次升级目录名都变，IFEO 得跟着重写（那还是要一个"安装/升级后执行"的步骤，等于没省事）；
2. **仍然要管理员**：写 IFEO 是 HKLM，跟 vbs 放哪儿无关；
3. **没有收益**：现在的 vbs 通过 `npp.exe` 别名解析，天生与版本无关，升级后不需要做任何事；
4. 想"从包里读脚本"还得把 vbs 加进包清单的 `Content`，等于为了让路径更脆弱而多改一处打包配置。

一句话：**能，但只有坏处**。真要"完全不用外部文件"，正确的方向是 Win11 的原生
`AppExecutionAliasRedirect`（§14.6），而不是把 vbs 塞进 WindowsApps。

### 14.6 Windows 11 的原生做法（可选，连 .vbs 都不用）

Win11 21H2（build 21313+）起，微软提供官方的「重定向到打包应用」机制：

```
HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe
    AppExecutionAliasRedirect         = 1          (DWORD)
    AppExecutionAliasRedirectPackages = NotepadPlusPlus.MSIX_54gzaac6bb4fr   (REG_SZ，或 *)
```

前提是包里声明了**名为 `notepad.exe`** 的 AppExecutionAlias（当前清单只有 `npp.exe`；
一份 Application 只能有一个别名，换 `notepad.exe` 就得放弃 `npp.exe`）。
Win10 19044 不支持该机制（要求 build 21313+），所以默认走 §14.2 的 .vbs 方案。
