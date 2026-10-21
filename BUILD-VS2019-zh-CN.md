# Notepad++ 8.3.3 编译构建笔记（VS2019 / v142 / NSIS / MSIX）

> 本仓库的**唯一**根级构建笔记：从源码到 exe、到 nsis 安装包、到 MSIX/MSIXBundle 三架构包，
> 全部命令、路径、体积、坑与验证结果都在这里。MSIX 的深水区细节另见
> [`PowerEditor/visual.net/Packaging/README.md`](PowerEditor/visual.net/Packaging/README.md)。
> 上游自带的 [`BUILD.md`](BUILD.md) 写的是「VS2017 + v141」，对本副本已不适用，以本文为准。

---

## 0. 30 秒速查

```powershell
$msb = 'C:\Program Files (x86)\Microsoft Visual Studio\2019\Enterprise\MSBuild\Current\Bin\MSBuild.exe'

# 1) 编 exe（Release | x64），产物 PowerEditor\bin64\Notepad++.exe
& $msb PowerEditor\visual.net\notepadPlus.sln /p:Configuration=Release /p:Platform=x64 /m /nologo /v:m

# 2) 打 nsis 精简安装包，产物 PowerEditor\installer\build\npp.8.3.3.Installer.x64.exe（3.5 MB）
cd PowerEditor\installer; & 'C:\Program Files (x86)\NSIS\makensis.exe' /DARCH64 /DNPP_MINIMAL nppSetup.nsi; cd ..\..

# 3) 打 MSIXBundle（x86+x64+ARM64），产物 AppPackages\NppPackaging_8.3.3.0_Test\*.msixbundle（12.2 MB）
cd PowerEditor\visual.net\Packaging; powershell -ExecutionPolicy Bypass -File .\build-msix.ps1 -Sign; cd ..\..\..
```

三条产线互不干扰：①只出 exe；②③都以①的产物为输入。

---

## 1. 环境与版本（本机实测）

| 组件 | 值 | 备注 |
|---|---|---|
| 操作系统 | Windows 10 IoT 企业版 LTSC 21H2（`10.0.19044.7807`，x64） | MSIX 也在这台机器上验证；Win11 用同一份包 |
| Visual Studio | 2019 Enterprise，`C:\Program Files (x86)\Microsoft Visual Studio\2019\Enterprise\` | 工作负载：使用 C++ 的桌面开发 + 通用 Windows 平台开发（后者给 MSIX 打包用） |
| MSVC 工具集 | `14.29.30133`（= **v142**） | `VC\Tools\MSVC\` 下只有这一个，**没有 v141** |
| ARM64 工具集 | 已装组件 `Microsoft.VisualStudio.Component.VC.Tools.ARM64` | `lib\arm64` / `bin\HostX64\arm64` 存在。**VS2019 默认不装**，缺它编不了 ARM64 |
| Windows SDK | `10.0.19041.0` | 与工程 `WindowsTargetPlatformVersion`、MSIX `TargetPlatformVersion` 一致 |
| MSBuild | `…\2019\Enterprise\MSBuild\Current\Bin\MSBuild.exe`（16.11.6） | 命令行构建统一用它 |
| NSIS | **v3.13**，`C:\Program Files (x86)\NSIS\makensis.exe` | `winget install --id NSIS.NSIS -e` |
| 7-Zip | `C:\Program Files\7-Zip\7z.exe` | 可选，便携包/校验用 |
| signtool / makeappx / appcert（WACK） | `C:\Program Files (x86)\Windows Kits\10\bin\10.0.19041.0\x64\`、`…\App Certification Kit\` | MSIX 签名 / 打包 / 认证 |

补 ARM64 工具集（一次性，需管理员）：

```powershell
& 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vs_installer.exe' modify `
    --installPath 'C:\Program Files (x86)\Microsoft Visual Studio\2019\Enterprise' `
    --add Microsoft.VisualStudio.Component.VC.Tools.ARM64 --quiet --norestart --nocache
```

---

## 2. 仓库地图与文档索引

```
npp\
├─ BUILD.md                        上游英文构建说明（VS2017/v141，已过时，仅历史参考）
├─ BUILD-VS2019-zh-CN.md           本文：根级构建笔记（编译 + nsis + MSIX）
├─ .gitignore                      构建产物忽略规则（含 MSIX 与 NppShellMsix 产物）
├─ PowerEditor\
│  ├─ visual.net\
│  │  ├─ notepadPlus.sln           解决方案：Notepad++ / SciLexer / NppShellMsix
│  │  ├─ notepadPlus.vcxproj       主程序工程（v142；DPI 清单可切换，见 §3.2）
│  │  └─ Packaging\                MSIX 打包（wapproj / 清单 / 脚本 / 图标 / 专项文档）
│  ├─ src\                         主程序源码（含 4 个 model xml）
│  ├─ src\tools\NppShellMsix\      MSIX 右键菜单处理器（IExplorerCommand，进程外 COM）
│  ├─ src\tools\NppShell\          上游传统右键菜单扩展（in-process，不进 MSIX）
│  ├─ bin\  bin64\  binarm64\      32/64/ARM64 输出目录（exe + 运行时 xml + NppShellMsix.dll）
│  ├─ installer\                   NSIS 安装包：nppSetup.nsi + nsisInclude\ + 资源目录
│  └─ gcc\                         MinGW 构建（本记录不使用）
└─ scintilla\                      Scintilla / Lexilla 源码与工程
```

文档分工：

| 文档 | 内容 |
|---|---|
| 本文 | 环境、编译、nsis 打包、MSIX 概览、验证、排错、**对上游的改动清单** |
| [`Packaging/README.md`](PowerEditor/visual.net/Packaging/README.md) | MSIX 载荷对照、清单字段、Win10/Win11 兼容矩阵、8 个坑、WACK 明细 |
| [`BUILD.md`](BUILD.md) | 上游原文（VS2017），**不要照做** |

---

## 3. 从零到 exe

### 3.1 改造一：工具集 v141 → v142（解决 MSB8020）

**症状**

```
错误 MSB8020: 无法找到 Visual Studio 2017 的生成工具(平台工具集 ="v141")
```

**原因**：8.3.3 的 `.vcxproj` 硬编码 `<PlatformToolset>v141</PlatformToolset>`（上游用 VS2017 发布），本机只有 v142。

**改法**：全量替换 `v141` → `v142`。共 6 个文件 19 处：

| 工程文件 | 处数 |
|---|---|
| `PowerEditor\visual.net\notepadPlus.vcxproj` | 6（6 个配置各一） |
| `scintilla\win32\SciLexer.vcxproj`（解决方案内） | 1 |
| `scintilla\win32\Scintilla.vcxproj`（已删） | 1 |
| `scintilla\lexilla\src\Lexilla.vcxproj`（已删） | 1 |
| `scintilla\test\unit\UnitTester.vcxproj`（已删） | 4 |
| `PowerEditor\src\tools\NppShell\project\NppShell.vcxproj` | 6 |

不改文件的等价做法：`/p:PlatformToolset=v142`（命令行有效，IDE 里无效，长期开发还是改工程）。
**关键**：`SciLexer`（静态库 `libSciLexer.lib`）必须与主程序同一工具集，否则链接阶段混用两代 CRT/obj。

验证（应无输出）：

```powershell
Select-String -Path (Get-ChildItem -Recurse -Filter *.vcxproj).FullName -Pattern '<PlatformToolset>v141</PlatformToolset>'
```

### 3.2 改造二：源码编码修复（解决 C4819 → C2220）

**症状**：几乎每个 `.cpp` 都报 `C2220 以下警告被视为错误` + `C4819 该文件包含不能在当前代码页(936)中表示的字符`，位置都指向 `ScintillaEditView.h`。

**原因**：① 6 个配置全开 `WarningLevel=Level4` + `TreatWarningAsError=true`（`/WX`），警告升级成错误；② 真实来源是源码里的非法字节（系统代码页 936/GBK）。

两处问题：

**A. 3 个孤立单字节**（非法 UTF-8、也非法 GBK）：

| 文件 | 位置 | 原字节 | 应为 |
|---|---|---|---|
| `PowerEditor\src\ScintillaComponent\ScintillaEditView.h` | 935 行字符串字面量 | `0x92` | `’` U+2019（`E2 80 99`） |
| `PowerEditor\src\ScintillaComponent\ScintillaEditView.cpp` | 1420 行法语注释 | `0xE9` | `é` U+00E9（`C3 A9`） |
| `PowerEditor\src\tools\NppShell\src\NppShell.rc` | 31 行 LegalCopyright | `0xA9` | `©` U+00A9（`C2 A9`） |

**B. 4 个文件含非 ASCII 但缺 UTF-8 BOM**：`ScintillaEditView.h`、`ScintillaEditView.cpp`、
`NppCommands.cpp`、`Parameters.cpp` → 补 BOM（本仓库既有约定就是「UTF-8 with BOM」）。

**为什么不用「关警告」或 `/utf-8`**：`DisableSpecificWarnings=4819` 只是掩盖坏字节；`/utf-8`
对非法 UTF-8 文件反而报错；逐文件补 BOM 精准且零副作用。

体检脚本见 [附录 A](#附录-a编码体检脚本)。

**另外一处打包相关的开关（本仓库新增）**：`notepadPlus.vcxproj` 的 6 个配置里
`<AdditionalManifestFiles>` 由写死的 `..\src\dpiAware.manifest` 改为 `$(NppDpiManifest)`，
默认值仍是原文件；MSIX 打包时传 `..\src\dpiAware.PerMonitorV2.manifest` 得到 PerMonitorV2（见 §5.3）。

### 3.3 编译

```powershell
$msb = 'C:\Program Files (x86)\Microsoft Visual Studio\2019\Enterprise\MSBuild\Current\Bin\MSBuild.exe'

# 单个架构
& $msb PowerEditor\visual.net\notepadPlus.sln /p:Configuration=Release /p:Platform=x64 /m /nologo /v:m

# 三个架构（Win32 / x64 / ARM64）
foreach ($p in 'Win32','x64','ARM64') {
  & $msb PowerEditor\visual.net\notepadPlus.sln /p:Configuration=Release /p:Platform=$p /m /nologo /v:m
  if ($LASTEXITCODE -ne 0) { throw "build failed: $p" }
}
```

> 解决方案的平台名是 `Win32`（不是 x86）；MSIX 工程 (`wapproj`) 里叫 `x86`，两者由打包工具映射。

VS 图形界面：打开 `notepadPlus.sln` → 选 `Release` + 平台 → 生成解决方案。

### 3.4 产物

| 配置 | 输出 | 体积（实测） |
|---|---|---|
| `Release｜Win32` | `PowerEditor\bin\Notepad++.exe` | 4,980,224 |
| `Release｜x64` | `PowerEditor\bin64\Notepad++.exe` | 5,762,560 |
| `Release｜ARM64` | `PowerEditor\binarm64\Notepad++.exe` | 5,864,960 |
| `Debug｜x64` | `PowerEditor\visual.net\x64\Debug\Notepad++.exe` | — |
| 静态库 | `PowerEditor\visual.net\{Release,x64\Release}\libSciLexer.lib` | ~74 MB |

`Notepad++.exe` 是**单文件自包含**（静态 CRT `/MT`，Scintilla/Lexilla 静态链入），
`dumpbin /dependents` 只有系统 DLL；不需要任何 VC 运行时再发行包。

Release 构建的 PostBuildEvent 会把 `langs.model.xml`、`stylers.model.xml`、`shortcuts.xml`、
`contextMenu.xml` 从 `PowerEditor\src\` 拷到 `bin\` / `bin64\` / `binarm64\`。

> ARM64 配置的 PostBuildEvent 里还多了一句 `copy ..\src\functionList.xml ..\binarm64\`，
> 而该文件本来就不存在（functionList 按语言拆在 `installer\functionList\`），所以编 ARM64 时会
> 打印一句「系统找不到指定的文件」。不影响构建结果，属上游遗留，未改动。

---

## 4. 产线 A：nsis 安装包

### 4.1 上游链路

```
PowerEditor\installer\
├─ packageAll.bat   发布总脚本：签名 → 组装 zipped.package.release[64] → 7-Zip 便携包 → makensis
└─ nppSetup.nsi     NSIS 脚本 → .\build\npp.${APPVERSION}.Installer[.x64|.arm64].exe
```

版本号不用手工填：`nsisInclude\globalDef.nsh` 用 `!getdllversion "..\bin64\notepad++.exe"` 从 exe
资源里读，`8.33` 会自动变成 `8.3.3`。`packageAll.bat` 前置条件：`SIGN=0`、三个 bin 目录的完整载荷、
7-Zip、makensis。

### 4.2 源码树里缺的载荷

以下预编译二进制来自官方发布包/独立仓库，**源码树不含**，直接跑 `packageAll.bat` 必失败：

| 缺失项 | 被谁引用 |
|---|---|
| `bin64\plugins\{NppExport,mimeTools,NppConverter}\*.dll`、`plugins\Config\nppPluginList.dll` | `binariesComponents.nsh` Plugins / Plugins Admin |
| `bin64\updater\{GUP.exe,libcurl.dll,gup.xml,LICENSE,README.md,updater.ico}` + `bin\updater\translations\` | Auto-Updater |
| `bin\notepad++.exe`（32 位） | 默认（非 `-DARCH64`）配置 |
| `binarm64\` 整个目录 | ARM64 配置 |

另外 `..\bin` 里缺 4 个 model xml，而 `copyCommonFiles` 不管打哪个架构都从 `..\bin` 取。

### 4.3 精简包路线（本仓库采用，零第三方 DLL）

用 `NPP_MINIMAL` 把引用外部二进制的 3 个组件（Plugins / Auto-Updater / Plugins Admin）隔离掉，
其余全保留：主程序、22 主题、27 autoCompletion API、34 functionList、94 语言文件、卸载逻辑、
传统右键菜单扩展（`NppShell_06.dll`）。4 处改动全部可用宏还原：

| 文件 | 改动 |
|---|---|
| `nsisInclude\binariesComponents.nsh` | 第 18–112 行用 `!ifndef NPP_MINIMAL` 包住三块组件；173–182 行包住 `.onSelChange` |
| `nppSetup.nsi` | `.onInit`（158–173）与 6 条 `MUI_DESCRIPTION_TEXT` 加同一守卫；`File` 源路径改为本仓库实际的 `..\bin\NppShell64.dll` / `NppShell.dll`（264/266/269/271 行） |
| `nsisInclude\uninstall.nsh` | `un.onUninstSuccess` 补 `RMDir "$INSTDIR\themes\"`、`RMDir "$INSTDIR\functionList\"`（上游顺序问题会残留空目录） |
| `PowerEditor\bin\` | 补入 4 个 model xml（来自 `PowerEditor\src\`） |

```powershell
cd PowerEditor\installer
New-Item -ItemType Directory -Force build | Out-Null
& 'C:\Program Files (x86)\NSIS\makensis.exe' /DARCH64 /DNPP_MINIMAL nppSetup.nsi
# 产物: build\npp.8.3.3.Installer.x64.exe（实测 3,647,040 字节）
```

> ⚠️ PowerShell 里必须以 `&` 开头调用，否则 `/DARCH64` 会被当成除法报语法错误。
> ⚠️ 必须在 `PowerEditor\installer` 目录下执行（脚本里全是 `..\bin` 相对路径），且 `build\` 要先建好。

### 4.4 完整包路线（要插件 + 自动更新器）

1. 从官方 8.3.3 x64 便携包取 §4.2 的目录放进 `PowerEditor\bin64\`；
2. 32 位包还要补 `PowerEditor\bin\notepad++.exe`；
3. 去掉 `NPP_MINIMAL`，改用上游脚本：

```cmd
cd /d PowerEditor\installer
set SIGN=0
packageAll.bat
```

### 4.5 签名

```cmd
signtool sign /f %NPP_CERT% /p %NPP_CERT_PWD% /d "Notepad++" /du https://notepad-plus-plus.org/ ^
  /t http://timestamp.digicert.com/ PowerEditor\bin64\Notepad++.exe
```

`packageAll.bat` 在 `SIGN=1` 时统一签 exe / NppShell / 插件 / GUP / 安装包。**未签名分发会触发
SmartScreen「未知发布者」。**

---

## 5. 产线 B：MSIX / MSIXBundle（x86 + x64 + ARM64）

### 5.1 一条命令

```powershell
cd PowerEditor\visual.net\Packaging
powershell -ExecutionPolicy Bypass -File .\build-msix.ps1 -CreateTestCert -TrustCert -Sign   # 首次（建并信任自签证书）
powershell -ExecutionPolicy Bypass -File .\build-msix.ps1 -Sign                              # 之后
# 产物: AppPackages\NppPackaging_8.3.3.0_Test\NppPackaging_8.3.3.0_x86_x64_ARM64.msixbundle（12.2 MB）
```

脚本做的事：三个架构分别编 `notepadPlus.sln`（含 `NppShellMsix`）→
`msbuild NppPackaging.wapproj /p:AppxBundle=Always /p:AppxBundlePlatforms=x86|x64|ARM64`
（AppxPackage targets 对每个架构各打一个 `.msix` 再合 bundle）→ `signtool` 签外层。

常用开关：`-Platforms x86,x64`（砍 ARM64）、`-NoBundle`（只要 .msix）、`-DpiAwareness system`、
`-Verify`（跑 WACK）、`-Install`（装到本机）、`-TargetPlatformVersion 10.0.22621.0`（换 Win11 SDK）。

### 5.2 包里有什么 / 没什么

**有**：`Notepad++.exe`（按架构）、`NppShellMsix.dll`（按架构）、4 个 model xml、`LICENSE`、
`localization\`(94)、`themes\`(22)、`functionList\`(34)、`APIs\`(27)、图标 9 张。

**没有**：插件（包目录只读 → 放 `%APPDATA%\Notepad++\plugins`）、`doLocalConf.xml`（会写安装目录）、
GUP 自动更新器（改走换包升级）、传统 `NppShell_06.dll`（MSIX 禁 in-process shell 扩展，改由
`NppShellMsix.dll` 提供右键菜单）。

### 5.3 DPI：PerMonitorV2（打包开关）

| 清单 | 声明 | 用于 |
|---|---|---|
| `PowerEditor\src\dpiAware.manifest` | `<dpiAware>true</dpiAware>` | 上游默认（系统级 DPI），普通/nsis 构建 |
| `PowerEditor\src\dpiAware.PerMonitorV2.manifest` | `true/pm` + `dpiAwareness=PerMonitorV2, PerMonitor` | MSIX 打包（脚本默认 `-DpiAwareness permonitorv2`） |

```powershell
# 手工等价
& $msb PowerEditor\visual.net\notepadPlus.sln /p:Configuration=Release /p:Platform=x64 `
    /p:NppDpiManifest=..\src\dpiAware.PerMonitorV2.manifest
```

验证：`mt.exe -inputresource:Notepad++.exe;#1` 里能同时看到 `dpiAware` 与 `dpiAwareness`；
运行中 `GetProcessDpiAwareness` 返回 `2 (PER_MONITOR_AWARE)`（系统级 DPI 是 1）。

> 取舍：npp 的 `WM_DPICHANGED` 处理是空的（`NppBigSwitch.cpp` 直接 `return TRUE;`），
> 所以 PMv2 下跨不同缩放显示器拖动**不会重排**（清晰但物理尺寸偏小）；系统级 DPI 则是位图拉伸
> （尺寸对、略模糊）。要退回：`-DpiAwareness system`。

### 5.4 右键菜单 `Edit with Notepad++`（进程外 COM）

新工程 `PowerEditor\src\tools\NppShellMsix\`：`CNppExplorerCommand : IExplorerCommand` +
类工厂 + `.def` 导出映射；清单里声明为 `com:SurrogateServer`（DLL 跑在 `dllhost.exe` 里）+
`desktop4:FileExplorerContextMenus`。CLSID `8E1B0F5C-1E8B-4D3A-9A2C-5B7E9C4C2A11`，
改一处要同时改 `NppExplorerCommand.h`、`com:Class Id`、`desktop4:Verb Clsid`。

自检（需先装包）：`powershell -ExecutionPolicy Bypass -File .\test-context-menu.ps1`
Win10 19044 实测：`GetTitle='Edit with Notepad++'`、`GetState=ECS_ENABLED`、`Invoke=S_OK`
并把文件拉进 Notepad++；`Shell.Application` 枚举动词时该项在列表里。

### 5.5 安装 / 升级 / 卸载

```powershell
Add-AppxPackage -Path '.\AppPackages\NppPackaging_8.3.3.0_Test\NppPackaging_8.3.3.0_x86_x64_ARM64.msixbundle'
explorer.exe "shell:AppsFolder\NotepadPlusPlus.MSIX_54gzaac6bb4fr!NotepadPlusPlus"
npp.exe somefile.txt                      # 命令行别名（AppExecutionAlias）
Get-AppxPackage NotepadPlusPlus.MSIX | Remove-AppxPackage
```

升级要改 `Package.appxmanifest` 的 `Version`（不改则报 `0x80073CFB`）。用户数据在
`%LOCALAPPDATA%\Packages\NotepadPlusPlus.MSIX_54gzaac6bb4fr\LocalCache\Roaming\Notepad++\`，
卸载后不自动删。

### 5.6 官方认证套件（WACK）

```powershell
powershell -ExecutionPolicy Bypass -File .\build-msix.ps1 -Sign -Verify   # 报告: AppPackages\wack-report.xml
```

本机结果：**Overall PASS / 23 PASS / 1 FAIL（OPTIONAL）/ 0 WARNING**。唯一非 PASS 是
「已阻止的可执行文件」（检出 `ShellExecuteW` 与各 XML 里的 `cmd`/`powershell` 字样，编辑器必然命中，
侧载无影响，上架商店需豁免）。

---

## 6. 验证清单

### 6.1 nsis 安装包（静默安装 → 检查 → 静默卸载）

```powershell
$setup = 'C:\Temp\npp.8.3.3.Installer.x64.exe'      # 先复制到 C:\Temp 之类常规路径，见 §7
$dir   = 'C:\Temp\npp_verify'
Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
Start-Process $setup -ArgumentList '/S', "/D=$dir" -Wait
(Get-ChildItem $dir -Recurse -File).Count                                            # 期望 96
Start-Process "$dir\uninstall.exe" -ArgumentList '/S' -Wait
Test-Path $dir                                                                        # 期望 False
Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++'        # 期望 False
```

实测：96 个文件 / 11.0 MB；包内 `notepad++.exe` 与构建产物 SHA256 一致；卸载后目录、注册表项、
App Paths、开始菜单快捷方式全部清除。

### 6.2 MSIX

```powershell
# 架构是否真对得上（PE machine: 0x014c / 0x8664 / 0xAA64）
& 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.19041.0\x64\makeappx.exe' unbundle `
    /p .\AppPackages\NppPackaging_8.3.3.0_Test\NppPackaging_8.3.3.0_x86_x64_ARM64.msixbundle /d $env:TEMP\npp-unbundle /o
# 签名
& 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.19041.0\x64\signtool.exe' verify /pa /v <bundle>
# 装 → 跑 → 右键菜单 → 卸
```

实测：bundle 12.2 MB（x86 3.91 / x64 4.21 / ARM64 4.07 MB），PE machine 与 `NppShellMsix.dll`
架构一一对应；`signtool verify` 通过；安装后进程路径 `C:\Program Files\WindowsApps\…\Notepad++.exe`；
`npp.exe` 别名落地；卸载干净。

---

## 7. 已知坑与排错

| 现象 | 原因 | 处理 |
|---|---|---|
| `MSB8020` 找不到 v141 | 工程写死 v141，本机只有 v142 | §3.1 改成 v142，或 `/p:PlatformToolset=v142` |
| `C2220` + `C4819` | 源码含 CP936 无法表示的字节；`/WX` 把警告升级为错误 | §3.2 修字节 + 补 BOM |
| 重定解决方案目标后仍有工程报 MSB8020 | 只改 sln 内的工程 | 手工改其余工程 |
| `MSB8036` 找不到 SDK 版本 | 上游部分工程钉旧 SDK（`10.0.16299.0` / `10.0.17763.0`） | 统一到 `10.0.19041.0`（本仓库已处理） |
| 编 ARM64 报 toolset/`MSB8020` | 没装 ARM64 工具集 | §1 的 `vs_installer modify --add …VC.Tools.ARM64` |
| ARM64 构建打印「系统找不到指定的文件」 | PostBuildEvent 拷 `..\src\functionList.xml`，该文件不存在 | 无害，忽略（§3.4 注） |
| `makensis` 报 `File: … not found` | 引用了 §4.2 的外部载荷 | 走精简路线 `/DNPP_MINIMAL` 或补齐载荷 |
| `packageAll.bat` 一跑就结束 | 没设 `SIGN=0`，走了 signtool 分支 | `set SIGN=0` |
| 卸载后残留空的 `themes\`、`functionList\` | 上游 section 顺序 | 已修（§4.3 第 3 行） |
| NSIS 卸载器弹 “Error writing temporary file” | 在受限/重定向的临时目录里运行 | 把安装包放 `C:\Temp` 之类常规路径再测 |
| 安装包被 SmartScreen 拦截 | 未签名 | §4.5 签名 |
| MSIX 打不出包 / 报 `.NET SDK 需要 MSBuild 18.0` | 装了 .NET 10 SDK，DesktopBridge targets 仍会 import `Microsoft.NET.Sdk` | 已在 wapproj 里 `<SkipImportNetSdk>true</SkipImportNetSdk>` |
| MSIX `APPX0501` 各种 schema 报错 | 清单字段不合法（DN 里的 `+`、`#AARRGGBB`、`.bat` 关联等） | 见 `Packaging/README.md` §9 |
| MSIX 装不上 `0x800B0109` / `0x80073CF0` | 证书没进 `TrustedPeople` / Publisher 与证书 Subject 不一致 | 重跑 `-CreateTestCert -TrustCert`；或对齐 Subject |

---

## 8. 对上游的改动清单（本仓库相对 Notepad++ 8.3.3 原样）

> 已 `git init` 并提交基线（分支 `main`，提交 `first commit`），可用 `git diff` / `git status` 复核。

### 8.1 工程与源码

| # | 位置 | 内容 |
|---|---|---|
| 1 | `notepadPlus.vcxproj`、`SciLexer.vcxproj`、`NppShell.vcxproj` | 工具集 → **v142**；`NppShell` 的 SDK → `10.0.19041.0` |
| 2 | `ScintillaEditView.h` / `.cpp` | 修 2 个孤立坏字节 + 补 UTF-8 BOM |
| 3 | `NppCommands.cpp`、`Parameters.cpp` | 补 UTF-8 BOM |
| 4 | `NppShell.rc` | 修 1 个孤立坏字节 |
| 5 | `notepadPlus.vcxproj` | 6 处 `<AdditionalManifestFiles>` 改为 `$(NppDpiManifest)`，新增默认值属性（DPI 可切换） |
| 6 | `notepadPlus.sln` | 新增 `Debug|ARM64` / `Release|ARM64` 解决方案平台；新增 `NppShellMsix` 工程与其 6 个配置映射 |
| 7 | `PowerEditor\bin\` | 补 4 个 model xml |

### 8.2 安装器脚本

| # | 位置 | 内容 |
|---|---|---|
| 8 | `nsisInclude\binariesComponents.nsh`、`nppSetup.nsi`、`nsisInclude\uninstall.nsh` | `NPP_MINIMAL` 守卫、NppShell 文件名适配、卸载残留目录修复 |

### 8.3 MSIX 相关（全部新增，不影响 nsis 产线）

| # | 位置 | 内容 |
|---|---|---|
| 9 | `PowerEditor\visual.net\Packaging\` | `NppPackaging.wapproj`、`Package.appxmanifest`、`Assets\`(9)、`make-assets.ps1`、`build-msix.ps1`、`test-context-menu.ps1`、`README.md` |
| 10 | `PowerEditor\src\dpiAware.PerMonitorV2.manifest` | PerMonitorV2 清单（打包版用） |
| 11 | `PowerEditor\src\tools\NppShellMsix\` | `NppExplorerCommand.h/.cpp`、`dllmain.cpp`、`NppShellMsix.def`、`NppShellMsix.vcxproj` |
| 12 | `.gitignore` | 新增 MSIX 产物（`Packaging\{bin,obj,AppPackages}`、`*.pfx/*.cer`）与 `NppShellMsix` 产物忽略规则 |
| 13 | `BUILD-VS2019-zh-CN.md`（本文） | 重写为完整构建笔记 |

### 8.4 已删除的 4 个工程（源码全部保留）

| 工程 | 产出 | 为什么多余 | 恢复 |
|---|---|---|---|
| `scintilla\win32\Scintilla.vcxproj` | `Scintilla.dll` | Notepad++ 用 `SciLexer.vcxproj` 把 Scintilla/Lexilla **静态**编进 `libSciLexer.lib`；导入表里没有任何 Scintilla DLL | 从 8.3.3 源码包取回 + 改 v142 |
| `scintilla\lexilla\src\Lexilla.vcxproj` | `Lexilla.dll` | 同上 | 同上 |
| `scintilla\test\unit\UnitTester.vcxproj` | 单元测试 | 不做测试；还钉了未装的 SDK | 同上 |
| `scintilla\lexilla\test\TestLexers.vcxproj` | 词法器测试 | 同上 | 同上 |

> 只删了工程文件，`scintilla\lexers\`、`lexlib\`、`test\unit\*.cxx` 源码都在。
> 保留 `NppShell.vcxproj`（传统右键菜单扩展）：安装包用的是 `PowerEditor\bin\` 里随源码分发的
> 预编译 DLL，平时不必编；需要时
> `& $msb PowerEditor\src\tools\NppShell\project\NppShell.sln /p:Configuration=Release /p:Platform=x64`。

---

## 9. 命令速查（全量）

```powershell
$msb = 'C:\Program Files (x86)\Microsoft Visual Studio\2019\Enterprise\MSBuild\Current\Bin\MSBuild.exe'
$sdk = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.19041.0\x64'
$pkg = 'PowerEditor\visual.net\Packaging'

# ---- 环境自检 ----
Get-ChildItem 'C:\Program Files (x86)\Microsoft Visual Studio\2019\Enterprise\VC\Tools\MSVC' -Directory   # 工具集
Test-Path 'C:\Program Files (x86)\Microsoft Visual Studio\2019\Enterprise\VC\Tools\MSVC\14.29.30133\lib\arm64'  # ARM64 工具集
Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\Include' -Directory                                    # SDK
& 'C:\Program Files (x86)\NSIS\makensis.exe' /VERSION                                                         # NSIS

# ---- 编译 ----
& $msb PowerEditor\visual.net\notepadPlus.sln /p:Configuration=Release /p:Platform=x64 /m /nologo /v:m
foreach ($p in 'Win32','x64','ARM64') {
  & $msb PowerEditor\visual.net\notepadPlus.sln /p:Configuration=Release /p:Platform=$p /m /nologo /v:m
}

# ---- nsis 精简安装包 ----
cd PowerEditor\installer
& 'C:\Program Files (x86)\NSIS\makensis.exe' /DARCH64 /DNPP_MINIMAL nppSetup.nsi
Get-FileHash build\npp.8.3.3.Installer.x64.exe -Algorithm SHA256
cd ..\..

# ---- MSIX ----
cd $pkg
powershell -ExecutionPolicy Bypass -File .\build-msix.ps1 -CreateTestCert -TrustCert -Sign   # 首次
powershell -ExecutionPolicy Bypass -File .\build-msix.ps1 -Sign                              # 常规
powershell -ExecutionPolicy Bypass -File .\build-msix.ps1 -Sign -Verify                      # + WACK
powershell -ExecutionPolicy Bypass -File .\build-msix.ps1 -Sign -Platforms x86,x64           # 不要 ARM64
powershell -ExecutionPolicy Bypass -File .\build-msix.ps1 -Sign -NoBundle                    # 只要 .msix
powershell -ExecutionPolicy Bypass -File .\build-msix.ps1 -Sign -DpiAwareness system         # 退回系统级 DPI
powershell -ExecutionPolicy Bypass -File .\test-context-menu.ps1                             # 右键菜单自检
cd ..\..\..

# ---- 校验 / 安装 / 卸载 ----
& "$sdk\signtool.exe" verify /pa /v (Get-ChildItem "$pkg\AppPackages" -Recurse -Filter *.msixbundle).FullName
Add-AppxPackage -Path (Get-ChildItem "$pkg\AppPackages" -Recurse -Filter *.msixbundle).FullName
Get-AppxPackage NotepadPlusPlus.MSIX | Remove-AppxPackage

# ---- 复核改动 ----
git status --porcelain
git diff --stat
```

---

## 附录 A：编码体检脚本

```powershell
$root = 'C:\Users\Administrator\AIProjects\npp'
$u8 = New-Object System.Text.UTF8Encoding($false, $true)
Get-ChildItem $root -Recurse -File |
  Where-Object { @('.h','.c','.cpp','.hpp','.cc','.rc','.inl','.def') -contains $_.Extension.ToLower() -and
                 $_.FullName -notmatch '\\(obj|Debug|Release|x64)\\' } |
  ForEach-Object {
    $b = [IO.File]::ReadAllBytes($_.FullName)
    $hi = 0; foreach ($x in $b) { if ($x -ge 0x80) { $hi++ } }
    if ($hi -gt 0) {
      $valid = $true; try { [void]$u8.GetString($b) } catch { $valid = $false }
      $bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
      '{0,-70} high={1,-5} bom={2,-5} validUtf8={3}' -f $_.FullName.Substring($root.Length+1), $hi, $bom, $valid
    }
  }
```

判断标准：**有非 ASCII 就必须 `validUtf8=True` 且 `bom=True`**；`validUtf8=False` 说明文件已被编码
转换破坏，必须逐字节修。

> `scintilla\src\CaseConvert.h` 也是「非 ASCII 无 BOM」，但它属于 SciLexer 工程（没开 `/WX`），
> 只是警告，不影响构建，可不处理。

## 附录 B：脚本编码约定

`Packaging\*.ps1` 一律**纯 ASCII**：Windows PowerShell 5.1 把无 BOM 的 UTF-8 当 ANSI 读，脚本里
写中文会变乱码并引发 `TerminatorExpectedAtEndOfString`。同理，读 `Package.appxmanifest` 要用
`[System.Xml.XmlDocument]::Load()`（认 XML 声明编码），不要用 `Get-Content` 再写回（会 `APPX1402`）。

---

*本文所有命令、路径、体积、构建结果均在 `C:\Users\Administrator\AIProjects\npp` 上实际执行验证过；
体积数字随编译器版本/DPI 清单选择会有几十 KB 漂移，属正常。*
