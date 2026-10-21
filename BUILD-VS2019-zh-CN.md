# Notepad++ 8.3.3 —— VS2019 编译 + 安装包制作完整记录

> 本文档记录把 **Notepad++ 8.3.3 源码** 在 **Visual Studio 2019** 上跑通编译、并最终产出 **x64 安装包** 的全过程，包含每一处改造的原因、改法和验证方式。
> 适用于：只想拿到能编译的代码、或要在 8.3.3 基础上做二次开发、或要自己出安装包的人。
> 上游自带的 [`BUILD.md`](BUILD.md) 写的是「VS2017 + v141」，那份文档对这个工作副本已经不适用，以本文为准。

---

## 0. 一句话概括

8.3.3 的工程文件硬编码 `v141`（VS2017 工具集），且源码里有几处**编码损坏**。改造 = 「工具集换成 v142」+「修 3 个孤立字节 + 给 4 个文件补 UTF‑8 BOM」，然后 `msbuild` 出 `Notepad++.exe`，最后用 NSIS 打精简安装包。

---

## 1. 环境与前置条件

本机实际验证通过的组合：

| 组件 | 版本 / 路径 | 说明 |
|---|---|---|
| Visual Studio | 2019 Enterprise，`C:\Program Files (x86)\Microsoft Visual Studio\2019\Enterprise\` | 需装「使用 C++ 的桌面开发」 |
| MSVC 工具集 | `14.29.30133`（= **v142**） | `VC\Tools\MSVC\` 下**只有**这一个，**没有 v141** |
| Windows SDK | `10.0.19041.0`（Include + Lib 完整） | 与工程里 `WindowsTargetPlatformVersion` 一致 |
| MSBuild | `MSBuild\Current\Bin\MSBuild.exe` | VS 自带 |
| NSIS | **3.13**，`C:\Program Files (x86)\NSIS\makensis.exe` | 打包用，`winget install --id NSIS.NSIS -e` 可装 |
| 7-Zip | `C:\Program Files\7-Zip\7z.exe` | 可选，做便携包/校验用 |

⚠️ **本机没有 ARM64 编译工具链**：`VC\Tools\MSVC\14.29.30133\bin\` 下只有 `Hostx64\{x64,x86}`、`Hostx86\{x64,x86}`，没有 `arm64`。所以 **只能编 Win32 / x64**，选 ARM64 平台一定会再报一次 MSB8020。

---

## 2. 关键路径速查

```
npp\
├─ BUILD.md                       上游英文构建说明（写的是 VS2017/v141，已过时）
├─ BUILD-VS2019-zh-CN.md          本文档
├─ PowerEditor\
│  ├─ visual.net\
│  │  ├─ notepadPlus.sln          解决方案（只含 2 个工程：Notepad++、SciLexer）
│  │  ├─ notepadPlus.vcxproj      主程序工程
│  │  └─ Debug|Release|x64|ARM64  中间产物 + 构建日志
│  ├─ src\                        主程序源码（含 langs.model.xml 等 4 个 model xml）
│  ├─ bin\                        32 位运行时文件（readme/change.log/doLocalConf.xml/NppShell*.dll）
│  ├─ bin64\                      64 位输出目录（编译产物 + 需要补齐的运行时文件）
│  ├─ installer\
│  │  ├─ nppSetup.nsi             NSIS 安装包脚本（主入口）
│  │  ├─ nsisInclude\             各组件 section、界面语言、卸载逻辑
│  │  ├─ packageAll.bat           官方发布脚本（含签名 + 便携包 + 调 makensis）
│  │  ├─ themes\ (22)  APIs\ (27)  functionList\ (34)  nativeLang\ (94)
│  │  └─ build\                   安装包输出目录（makensis 生成）
│  └─ gcc\                        MinGW 构建（本记录不使用）
└─ scintilla\                     Scintilla / Lexilla 源码与独立工程
```

---

## 3. 改造一：工具集 v141 → v142（解决 MSB8020）

### 症状

用 VS2019 打开 `PowerEditor\visual.net\notepadPlus.sln`，生成即报：

```
错误 MSB8020: 无法找到 Visual Studio 2017 的生成工具(平台工具集 ="v141")。
              ... 或可以重定解决方案目标。
文件: ...\MSBuild\Microsoft\VC\v160\Microsoft.CppBuild.targets   行:439
```

### 原因

8.3.3 的所有 `.vcxproj` 里写死了 `<PlatformToolset>v141</PlatformToolset>`（上游用 VS2017 发布），而本机只装了 v142，找不到 v141 的编译器目录 → MSB8020。

### 改法

把工程文件里的 `v141` 全量替换为 `v142`。共 **6 个文件、19 处**：

| 工程文件 | 处数 | 行号 |
|---|---|---|
| `PowerEditor\visual.net\notepadPlus.vcxproj` | 6 | 39 / 45 / 51 / 57 / 62 / 67（6 个配置各一） |
| `scintilla\win32\SciLexer.vcxproj`（解决方案内） | 1 | 39 |
| `scintilla\win32\Scintilla.vcxproj` | 1 | 38 |
| `scintilla\lexilla\src\Lexilla.vcxproj` | 1 | 38 |
| `scintilla\test\unit\UnitTester.vcxproj` | 4 | 31 / 37 / 44 / 50 |
| `PowerEditor\src\tools\NppShell\project\NppShell.vcxproj` | 6 | 38 / 44 / 49 / 55 / 61 / 66 |

> `scintilla\lexilla\test\TestLexers.vcxproj` 本来就是 v142，无需处理。

**本仓库的最终状态**：只保留 3 个工程 —— `notepadPlus.vcxproj` + `SciLexer.vcxproj`（解决方案内，出 exe 必需）、`NppShell.vcxproj`（右键菜单扩展，已单独改成 v142 + 现装 SDK）。其余 4 个「独立 DLL / 单元测试」工程已删除，理由与恢复方式见 [第 9 节](#9-本仓库当前状态)。

VS 图形界面的等价操作：右键解决方案 → **重定解决方案目标** → 选 `v142`。注意它**只会改解决方案内的 2 个工程**（Notepad++、SciLexer），其余 4 个需要手工改。

**关键**：`SciLexer`（静态库 `libSciLexer.lib`）必须和 `notepad++` 用**同一套工具集**。只改主程序不改 SciLexer 会导致链接阶段混用两代 CRT/obj，`/GL` 链接容易出问题。

### 不改文件的替代方案

MSBuild 命令行传入的全局属性优先级高于工程内设置，可以完全不改 `.vcxproj`：

```powershell
msbuild PowerEditor\visual.net\notepadPlus.sln /p:Configuration=Release /p:Platform=x64 /p:PlatformToolset=v142
```

（IDE 里没法这么传参，所以长期开发建议还是直接改工程。）

### 验证

```powershell
# 应无输出
Select-String -Path (Get-ChildItem -Recurse -Filter *.vcxproj).FullName -Pattern '<PlatformToolset>v141</PlatformToolset>'
```

---

## 4. 改造二：源码编码修复（解决 C4819 → C2220）

工具集换好后，紧接着会撞上第二堵墙。

### 症状

```
错误 C2220: 以下警告被视为错误 (编译源文件 ..\src\ScintillaComponent\UserDefineDialog.cpp)  ... ScintillaEditView.h  行 907
警告 C4819: 该文件包含不能在当前代码页(936)中表示的字符 ...
```

几乎**每个 .cpp** 都报同一句，位置都指向 `ScintillaEditView.h`。

### 原因

1. `notepadPlus.vcxproj` 的 6 个配置全都开了 `WarningLevel=Level4` + `TreatWarningAsError=true`（`/WX`），所以 C4819 被升级成致命错误 C2220，编译器在第一个警告处就中止整个编译单元。
2. C4819 的真实来源是**源码编码**：系统代码页是 936(GBK)，编译器按 GBK 读取源文件，遇到非法字节就报。所以所有 .cpp 都报，是因为它们都 `#include` 了同一个含坏字节的头文件。

实际检查（按字节比对）后发现两处问题：

**A. 3 个文件里各混入了 1 个「孤立」的 Latin‑1 单字节**（典型的编码往返转换残渣，非法 UTF‑8，也非法 GBK）：

| 文件 | 位置 | 原字节 | 正确内容 |
|---|---|---|---|
| `PowerEditor\src\ScintillaComponent\ScintillaEditView.h` | 935 行 word‑chars 字符串字面量里 | `0x92` | `’` U+2019 → UTF‑8 `E2 80 99` |
| `PowerEditor\src\ScintillaComponent\ScintillaEditView.cpp` | 1420 行法语注释 `d'exécuter` | `0xE9` | `é` U+00E9 → UTF‑8 `C3 A9` |
| `PowerEditor\src\tools\NppShell\src\NppShell.rc` | 31 行 `LegalCopyright` | `0xA9` | `©` U+00A9 → UTF‑8 `C2 A9` |

**B. 4 个文件含非 ASCII 字符却没有 UTF‑8 BOM**，MSVC 会按 GBK 误读（这批只是还没轮到报错）：

- `ScintillaEditView.h`、`ScintillaEditView.cpp`（同上两个）
- `PowerEditor\src\NppCommands.cpp`（`double–clicking`、`«J¤µ§^` 等）
- `PowerEditor\src\Parameters.cpp`（`retourné`）

其余含非 ASCII 的源文件（如 `Notepad_plus.cpp` 的 `²`/`π`/法语彩蛋、`localizationString.h`）**本来就有 BOM**，是合法 UTF‑8，无需改动。

### 改法

1. 按上表把 3 个孤立字节替换成正确的 UTF‑8 序列（**不要**用近似 ASCII 字符顶替，否则字符串字面量内容会变）。
2. 给那 4 个文件加上 UTF‑8 BOM —— 这正好是本仓库既有约定（`Notepad_plus.cpp`、`localizationString.h` 等本来就是「UTF‑8 with BOM」）。MSVC 见到 BOM 就按 UTF‑8 解析，C4819 消失，注释和字符串也不会再乱码。

### 为什么不用「关警告」或 `/utf-8`

- `DisableSpecificWarnings=4819` 或去掉 `/WX`：能过编译，但 3 个坏字节还在，字符串字面量内容依然是被污染的，属于掩盖问题。
- `/utf-8` 全局编译开关：对这些**非法 UTF‑8** 的文件反而会报错；本项目既有「带 BOM」约定，逐文件补 BOM 更精准、零副作用。

### 附：编码体检脚本

```powershell
$root = 'C:\path\to\npp'
$u8 = New-Object System.Text.UTF8Encoding($false, $true)
Get-ChildItem $root -Recurse -File |
  Where-Object { @('.h','.c','.cpp','.hpp','.cc','.rc','.inl','.def') -contains $_.Extension.ToLower() -and $_.FullName -notmatch '\\(obj|Debug|Release|x64)\\' } |
  ForEach-Object {
    $b = [IO.File]::ReadAllBytes($_.FullName)
    $hi = 0; foreach ($x in $b) { if ($x -ge 0x80) { $hi++ } }
    if ($hi -gt 0) {
      $valid = $true; try { [void]$u8.GetString($b) } catch { $valid = $false }
      $bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
      '{0,-60} high={1,-5} bom={2,-5} validUtf8={3}' -f $_.FullName.Substring($root.Length+1), $hi, $bom, $valid
    }
  }
```

判断标准：**有非 ASCII 就必须 `validUtf8=True` 且 `bom=True`**；`validUtf8=False` 说明文件已被编码转换破坏，必须逐字节修。

> `scintilla\src\CaseConvert.h` 同样是非 ASCII 无 BOM，但它属于 SciLexer 工程，该工程**没开** `/WX`，只是警告，不影响构建，可不处理。

---

## 5. 编译

### 5.1 VS 图形界面

打开 `PowerEditor\visual.net\notepadPlus.sln` → 选 `Release` + `x64` → 生成 → 重新生成解决方案。

### 5.2 命令行（推荐，便于自动化）

```powershell
$msb = 'C:\Program Files (x86)\Microsoft Visual Studio\2019\Enterprise\MSBuild\Current\Bin\MSBuild.exe'
& $msb 'PowerEditor\visual.net\notepadPlus.sln' /p:Configuration=Release /p:Platform=x64 /m /nologo /v:m
```

实测结果：**0 警告 0 错误，耗时约 1 分 18 秒**。

### 5.3 产物位置

| 配置 | 输出 |
|---|---|
| `Release｜x64` | `PowerEditor\bin64\Notepad++.exe`（5,762,560 字节，FileVersion `8.33`） |
| `Debug｜x64` | `PowerEditor\visual.net\x64\Debug\Notepad++.exe` |
| `Release｜Win32` | `PowerEditor\bin\Notepad++.exe` |
| 静态库 | `PowerEditor\visual.net\x64\Release\libSciLexer.lib` |

> 仓库里 `PowerEditor\visual.net\Debug\*.log`、`scintilla\win32\Debug\*.log` 是 VS 的构建日志，出现历史报错信息属正常，重新生成会覆盖。

### 5.4 平台限制

- **Win32 / x64**：可编。
- **ARM64**：本机无 ARM64 工具链，需在 VS Installer 里补 `MSVC v142 - VS 2019 C++ ARM64 生成工具`，另需把 `binarm64` 目录建起来。

---

## 6. 生成安装包

### 6.1 上游的打包链路

```
PowerEditor\installer\
├─ packageAll.bat   发布总脚本：签名(signtool) → 组装 zipped.package.release[64] → 7-Zip 打便携包 → 调 makensis
└─ nppSetup.nsi     NSIS 安装包脚本，输出 .\build\npp.${APPVERSION}.Installer[.x64|.arm64].exe
```

版本号不用手工填：`nsisInclude\globalDef.nsh` 用 `!getdllversion "..\bin64\notepad++.exe"` 从 exe 的资源里读，编译出的 `8.33` 会自动变成 `8.3.3`。

`packageAll.bat` 的前置条件（缺一不可）：

- 环境变量 `SIGN=0`（否则会走 `signtool`，没证书就跳 `:End` 直接结束）
- `..\bin`（32 位）、`..\bin64`、`..\binarm64` 三个目录的**完整运行时载荷**
- `C:\Program Files\7-Zip\7z.exe`
- `%ProgramFiles(x86)%\NSIS\makensis.exe`

### 6.2 本仓库原本缺的载荷

源码树里**不含**以下预编译二进制（它们来自独立仓库/官方发布包），这是「直接跑 packageAll.bat 会失败」的根本原因：

| 缺失项 | 被谁引用 |
|---|---|
| `bin64\plugins\NppExport\NppExport.dll` | `binariesComponents.nsh` Plugins 组 |
| `bin64\plugins\mimeTools\mimeTools.dll` | 同上 |
| `bin64\plugins\NppConverter\NppConverter.dll` | 同上 |
| `bin64\plugins\Config\nppPluginList.dll` | Plugins Admin |
| `bin64\updater\{GUP.exe,libcurl.dll,gup.xml,LICENSE,README.md,updater.ico}` + `bin\updater\translations\` | Auto‑Updater |
| `bin\notepad++.exe`（32 位 exe） | 默认（非 `-DARCH64`）配置 |
| `binarm64\` 整个目录 | `-DARCH64` 以外的 ARM64 配置 |

另外 `..\bin` 里**缺 4 个 model xml**（`contextMenu.xml`、`langs.model.xml`、`stylers.model.xml`、`shortcuts.xml`），而 `mainSectionFuncs.nsh` 的 `copyCommonFiles` 不管打哪个架构都从 `..\bin` 取 —— 必须从 `PowerEditor\src\` 拷过去。

### 6.3 精简包路线（本仓库采用，不需要任何第三方 DLL）

思路：用 `NPP_MINIMAL` 开关把引用外部二进制的 3 个组件（Plugins / Auto‑Updater / Plugins Admin）从编译里隔离掉，其余全部保留：主程序、22 个主题、27 个 autoCompletion API、34 个 functionList 定义、94 个界面语言文件（`MementoUnselectedSection`，默认不勾选，只有 `english.xml` 由 `copyCommonFiles` 直接安装）、右键菜单扩展、卸载逻辑。安装向导本身支持 58 种界面语言。

已做的 4 处改动（均可用宏还原，不破坏上游原样）：

| 文件 | 改动 |
|---|---|
| [`nsisInclude\binariesComponents.nsh`](PowerEditor/installer/nsisInclude/binariesComponents.nsh) | 第 18–112 行用 `!ifndef NPP_MINIMAL` 包住 Plugins/Auto‑Updater/PluginsAdmin 三块；第 173–182 行包住引用 `${PluginsAdmin}`/`${AutoUpdater}` 的 `.onSelChange`。`un.*` 卸载 section 只有 Delete/RMDir，无需守卫 |
| [`nppSetup.nsi`](PowerEditor/installer/nppSetup.nsi) | `.onInit` 中处理 updater/pluginsadmin 的段落（158–173）+ 6 条 `MUI_DESCRIPTION_TEXT` 组件说明加同一守卫；`File` 源路径由 `..\bin\NppShell64_06.dll`/`NppShell_06.dll` 改为本仓库实际的 `..\bin\NppShell64.dll`/`NppShell.dll`（264/266/269/271 行） |
| [`nsisInclude\uninstall.nsh`](PowerEditor/installer/nsisInclude/uninstall.nsh) | `un.onUninstSuccess` 中补 `RMDir "$INSTDIR\themes\"`、`RMDir "$INSTDIR\functionList\"`。上游 Section 执行顺序会让这两个目录在删文件前先尝试删除，卸载后残留两个空目录 |
| `PowerEditor\bin\` | 补入 `langs.model.xml`、`stylers.model.xml`、`contextMenu.xml`、`shortcuts.xml`（来自 `PowerEditor\src\`） |

打包命令：

```powershell
# 前置：装 NSIS（一次性）
winget install --id NSIS.NSIS -e --silent --accept-package-agreements --accept-source-agreements

cd PowerEditor\installer
New-Item -ItemType Directory -Force build | Out-Null
& 'C:\Program Files (x86)\NSIS\makensis.exe' /DARCH64 /DNPP_MINIMAL nppSetup.nsi
```

> ⚠️ **PowerShell 必须以 `&` 开头调用**：`& '...\makensis.exe' /DARCH64 ...`。
> 少了 `&`，PowerShell 会把 `'...makensis.exe'` 当字符串、把 `/DARCH64` 当除法，报
> `必须在"/"运算符后面提供一个值表达式` / `意外的标记"DARCH64"`。
> 在 cmd 或 `npp` 快捷方式里直接写带引号的完整路径即可，不需要 `&`。
>
> ⚠️ 必须在 `PowerEditor\installer` 目录下执行（脚本里全是 `..\bin`、`..\bin64` 相对路径），
> 且 `build\` 目录要先存在。

产物：`PowerEditor\installer\build\npp.8.3.3.Installer.x64.exe`（**约 3.48 MB**，版本资源 `8.3.3.0`）。

### 6.4 完整包路线（要插件 + 自动更新器）

1. 从官方 8.3.3 x64 便携包（或对应插件仓库的 release）取出 6.2 表格里的目录，放进 `PowerEditor\bin64\`（`bin\updater\translations\` 也要）；
2. 32 位包还要把 `PowerEditor\bin\notepad++.exe` 补上（编 `Release|Win32`）；
3. 去掉 `NPP_MINIMAL`，改用上游脚本：

```cmd
rem 必须在 PowerEditor\installer 目录下运行（脚本里全是 ..\bin、..\bin64 相对路径）
cd /d PowerEditor\installer
set SIGN=0
packageAll.bat
```

或者跳过便携包步骤，直接 `makensis /DARCH64 nppSetup.nsi`。

### 6.5 签名（正式发布才需要）

```cmd
signtool sign /f %NPP_CERT% /p %NPP_CERT_PWD% /d "Notepad++" /du https://notepad-plus-plus.org/ ^
  /t http://timestamp.digicert.com/ PowerEditor\bin64\Notepad++.exe
```

`packageAll.bat` 里 `SIGN=1` 时会自动对 exe、NppShell、插件、GUP、安装包统一签名。**未签名的安装包分发会触发 SmartScreen「未知发布者」。**

---

## 7. 验证与自测

### 7.1 安装包自检（静默安装 → 检查 → 静默卸载）

```powershell
$setup = 'C:\Temp\npp.8.3.3.Installer.x64.exe'   # 建议复制到 C:\Temp 再跑，原因见第 8 节倒数第二条
$dir   = 'C:\Temp\npp_verify'
Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
Start-Process $setup -ArgumentList '/S', "/D=$dir" -Wait
(Get-ChildItem $dir -Recurse -File).Count                    # 期望 96
Start-Process "$dir\uninstall.exe" -ArgumentList '/S' -Wait
Test-Path $dir                                               # 期望 False
Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++'   # 期望 False
```

本次实测结果：

| 检查项 | 结果 |
|---|---|
| 安装文件数 / 体积 | 96 个 / 11.0 MB |
| 包内 `notepad++.exe` 与构建产物 | SHA256 完全一致 |
| 关键文件 | `notepad++.exe`、`uninstall.exe`、4 个 model xml、`NppShell_06.dll`、`localization\`、`themes\`、`functionList\`、`autoCompletion\` 全部就位 |
| 卸载后 | 目录、注册表卸载项、App Paths、开始菜单快捷方式全部清除 |

### 7.2 安装包里有什么

**包含**：`notepad++.exe`(8.33 x64)、`langs/stylers/contextMenu/shortcuts.xml`、`LICENSE`、`readme.txt`、`change.log`、22 个主题（默认全选）、27 个 autoCompletion API、34 个 functionList 定义、Markdown UDL、右键菜单 shell 扩展、卸载器、注册表登记（含 `EstimatedSize`）。界面语言共 94 个随包发布，默认只安装 `english.xml`，其余在组件页按需勾选。

**不含**：NppExport / mimeTools / NppConverter 三个插件、Plugins Admin、GUP 自动更新器。

---

## 8. 已知坑与排查表

| 现象 | 原因 | 处理 |
|---|---|---|
| `MSB8020` 找不到 v141 | 工程写死 v141，本机只有 v142 | 见第 3 节：改成 v142，或 `-p:PlatformToolset=v142` |
| `C2220 以下警告被视为错误` + `C4819` | 源码含 CP936 无法表示的字节；`/WX` 把警告升级为错误 | 见第 4 节：修字节 + 补 BOM |
| 重定向后仍有工程报 MSB8020 | 「重定解决方案目标」只改 sln 内的 2 个工程 | 手工改剩下 4 个（或在 IDE 里逐个打开重定） |
| `MSB8036` 找不到 Windows SDK 版本 | 上游 8.3.3 里 `UnitTester.vcxproj` 钉 `10.0.16299.0`、`NppShell.vcxproj` 钉 `10.0.17763.0`，本机只有 `10.0.19041.0` | 本仓库已把 `UnitTester` 移出、`NppShell` 的 SDK 改为 `10.0.19041.0`；若从原始源码重来，照此处理 |
| 选 ARM64 平台报错 | 没有 ARM64 编译工具链 | 只编 Win32/x64，或补装 ARM64 组件 |
| `makensis` 报 `File: ... not found` | 引用了 6.2 表格里的外部载荷 | 走精简路线（`/DNPP_MINIMAL`）或补齐载荷 |
| `packageAll.bat` 一跑就结束 | 没设 `SIGN=0`，走了 signtool 分支 | `set SIGN=0` |
| 卸载后残留空的 `themes\`、`functionList\` | 上游 section 顺序问题 | 已修（第 6.3 节第 3 行） |
| NSIS 卸载器弹 “Error writing temporary file” | 在受限/重定向的临时目录里运行（例如把包放在工作区的 `.tools\` 下测试） | 把安装包复制到 `C:\Temp` 之类常规路径再跑；正常用户环境不受影响 |
| 安装包被 SmartScreen 拦截 | 未签名 | 用证书签名（6.5 节） |

---

## 9. 本仓库当前状态

> ⚠️ 本目录**不是 git 仓库**（没有 `.git`），改动无法 `git diff`/`git checkout` 还原。后续开发建议先 `git init` 提交一次基线，或保留原始源码包备份。

已完成的改动清单：

| # | 位置 | 内容 |
|---|---|---|
| 1 | `notepadPlus.vcxproj`、`SciLexer.vcxproj` | 工具集 → **v142**（解决方案内的 2 个工程，6+1 处） |
| 2 | `ScintillaEditView.h` | 935 行 `0x92` → `’`；补 UTF‑8 BOM |
| 3 | `ScintillaEditView.cpp` | 1420 行 `0xE9` → `é`；补 UTF‑8 BOM |
| 4 | `NppCommands.cpp`、`Parameters.cpp` | 补 UTF‑8 BOM |
| 5 | `NppShell.rc` | 31 行 `0xA9` → `©`（该工程不在主构建内，仅为编码一致性） |
| 6 | `installer\nsisInclude\binariesComponents.nsh`、`nppSetup.nsi`、`nsisInclude\uninstall.nsh` | `NPP_MINIMAL` 守卫、NppShell 文件名适配、卸载残留目录修复 |
| 7 | `PowerEditor\bin\` | 补 4 个 model xml |
| 8 | `scintilla\win32\Scintilla.vcxproj`、`scintilla\lexilla\src\Lexilla.vcxproj`、`scintilla\test\unit\UnitTester.vcxproj`、`scintilla\lexilla\test\TestLexers.vcxproj` | **已删除**：都是独立 DLL / 单元测试工程，与出 exe 无关（见下表） |
| 9 | `PowerEditor\src\tools\NppShell\project\NppShell.vcxproj` | 工具集 → **v142**，SDK `10.0.17763.0` → `10.0.19041.0`（实测可编，0 错误） |

### 9.1 已删除的 4 个工程

| 工程 | 它产出什么 | 为什么多余 | 恢复方式 |
|---|---|---|---|
| `scintilla\win32\Scintilla.vcxproj` | `Scintilla.dll`（动态库版 Scintilla） | Notepad++ 用的是 `SciLexer.vcxproj`（把 `scintilla\lexers\*.cxx` + `lexlib\*.cxx` + `src\*.cxx` **静态**编进 `libSciLexer.lib`）；`dumpbin /dependents Notepad++.exe` 的导入表里只有系统 DLL，没有任何 Scintilla/Lexilla DLL | 从原始 8.3.3 源码包取回该文件 |
| `scintilla\lexilla\src\Lexilla.vcxproj` | `Lexilla.dll`（把词法器做成独立共享库） | 同上，词法器已静态并入 `libSciLexer.lib`；`scintilla\lexilla\src\` 下只剩 `Lexilla.cxx/.h/.def` 这套「加载器」源码，Notepad++ 不需要 | 同上 |
| `scintilla\test\unit\UnitTester.vcxproj` | Scintilla 单元测试（`catch.hpp`） | 不做测试就不需要；它还钉了未安装的 SDK `10.0.16299.0` | 同上 |
| `scintilla\lexilla\test\TestLexers.vcxproj` | Lexilla 词法器测试 | 同上 | 同上 |

> 只删除了工程文件，**源码全部保留**（`scintilla\lexers\`、`lexlib\`、`test\unit\*.cxx` 都还在）。
> 这 4 个 `.vcxproj` 已彻底删除、无本地备份。它们都是上游原样文件，需要时可从 8.3.3 源码包（或 GitHub `v8.3.3` tag）原样取回，再按第 3 节把 `v141` 改成 `v142`。

**保留的 `NppShell.vcxproj` 说明**：它是资源管理器右键菜单扩展（产出 `NppShell.dll` / `NppShell64.dll`），不属于插件或更新器。安装包用的是 `PowerEditor\bin\` 里随源码分发的预编译 DLL，所以平时不必编它；需要重新编时用：

```powershell
& $msb PowerEditor\src\tools\NppShell\project\NppShell.sln /p:Configuration=Release /p:Platform=x64
# 产物: PowerEditor\src\tools\NppShell\build_x64\NppShell64.dll（OutputFile 定义名）
```

---

## 10. 命令速查

```powershell
# ---- 环境自检 ----
Get-ChildItem 'C:\Program Files (x86)\Microsoft Visual Studio\2019\Enterprise\VC\Tools\MSVC' -Directory   # 工具集版本
Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\Include' -Directory                                    # SDK 版本
Test-Path 'C:\Program Files (x86)\NSIS\makensis.exe'                                                          # NSIS

# ---- 编译 ----
& 'C:\Program Files (x86)\Microsoft Visual Studio\2019\Enterprise\MSBuild\Current\Bin\MSBuild.exe' `
  'PowerEditor\visual.net\notepadPlus.sln' /p:Configuration=Release /p:Platform=x64 /m /nologo /v:m

# ---- 打精简安装包 ----
cd PowerEditor\installer
& 'C:\Program Files (x86)\NSIS\makensis.exe' /DARCH64 /DNPP_MINIMAL nppSetup.nsi
# 产物: build\npp.8.3.3.Installer.x64.exe

# ---- 校验安装包 ----
Get-FileHash build\npp.8.3.3.Installer.x64.exe -Algorithm SHA256
& 'C:\Program Files\7-Zip\7z.exe' l build\npp.8.3.3.Installer.x64.exe | Select-Object -First 30

# ---- 静默安装 / 卸载（务必在 C:\Temp 之类常规路径下测试）----
Start-Process 'C:\Temp\npp.8.3.3.Installer.x64.exe' -ArgumentList '/S','/D=C:\Temp\npp_verify' -Wait
Start-Process 'C:\Temp\npp_verify\uninstall.exe' -ArgumentList '/S' -Wait
```

---

*文档基于实际执行结果整理，所有命令、路径、字节数均在 `C:\Users\Administrator\AIProjects\npp` 上验证过。*
