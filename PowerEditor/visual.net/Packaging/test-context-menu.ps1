#Requires -Version 5.1
# Smoke test for the packaged context menu handler:
#   * activates the packaged COM surrogate class through CoCreateInstance(CLSCTX_LOCAL_SERVER)
#   * calls IExplorerCommand::GetTitle / GetCanonicalName
#   * lists the verbs File Explorer exposes for a .txt file
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class NppCtxTest
{
    [DllImport("ole32.dll")]
    static extern int CoInitializeEx(IntPtr pvReserved, uint dwCoInit);
    [DllImport("ole32.dll")]
    static extern int CoCreateInstance(ref Guid rclsid, IntPtr pUnkOuter, uint dwClsContext, ref Guid riid, out IntPtr ppv);
    [DllImport("ole32.dll")]
    static extern void CoTaskMemFree(IntPtr p);

    [ComImport, Guid("a08ce4d0-fa25-44ab-b57c-c7b1c323e0b9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IExplorerCommand
    {
        [PreserveSig] int GetTitle(IntPtr psiItemArray, out IntPtr ppszName);
        [PreserveSig] int GetIcon(IntPtr psiItemArray, out IntPtr ppszIcon);
        [PreserveSig] int GetToolTip(IntPtr psiItemArray, out IntPtr ppszInfotip);
        [PreserveSig] int GetCanonicalName(out Guid pguidCommandName);
        [PreserveSig] int GetState(IntPtr psiItemArray, bool fOkToBeSlow, out int pCmdState);
        [PreserveSig] int Invoke(IntPtr psiItemArray, IntPtr pbc);
        [PreserveSig] int GetFlags(out int pFlags);
        [PreserveSig] int EnumSubCommands(out IntPtr ppEnum);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHCreateItemFromParsingName(string pszPath, IntPtr pbc, ref Guid riid, out IntPtr ppv);
    [DllImport("shell32.dll")]
    static extern int SHCreateShellItemArrayFromShellItem(IntPtr psi, ref Guid riid, out IntPtr ppsia);

    // Calls GetState + Invoke with a real one-item IShellItemArray, i.e. the exact path
    // Explorer uses when the user clicks the menu entry.
    public static string InvokeTest(string path)
    {
        CoInitializeEx(IntPtr.Zero, 0x2);

        Guid iidItem = new Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe");   // IShellItem
        IntPtr psi;
        int hr = SHCreateItemFromParsingName(path, IntPtr.Zero, ref iidItem, out psi);
        if (hr != 0) return string.Format("SHCreateItemFromParsingName hr=0x{0:X8}", hr);

        Guid iidArray = new Guid("b63ea76d-1f85-456f-a19c-48159efa858b"); // IShellItemArray
        IntPtr psia;
        hr = SHCreateShellItemArrayFromShellItem(psi, ref iidArray, out psia);
        if (hr != 0) return string.Format("SHCreateShellItemArrayFromShellItem hr=0x{0:X8}", hr);

        Guid clsid = new Guid("8E1B0F5C-1E8B-4D3A-9A2C-5B7E9C4C2A11");
        Guid iidCmd = new Guid("a08ce4d0-fa25-44ab-b57c-c7b1c323e0b9");
        IntPtr ppv;
        hr = CoCreateInstance(ref clsid, IntPtr.Zero, 4, ref iidCmd, out ppv);
        if (hr != 0) { Marshal.Release(psia); Marshal.Release(psi); return string.Format("CoCreateInstance hr=0x{0:X8}", hr); }

        var cmd = (IExplorerCommand)Marshal.GetObjectForIUnknown(ppv);
        int state;
        int hrState = cmd.GetState(psia, true, out state);
        int hrInvoke = cmd.Invoke(psia, IntPtr.Zero);

        Marshal.Release(ppv);
        Marshal.Release(psia);
        Marshal.Release(psi);

        return string.Format("GetState hr=0x{0:X8} state={1} (0=ECS_ENABLED)   Invoke hr=0x{2:X8}", hrState, state, hrInvoke);
    }

    public static string Test()
    {
        CoInitializeEx(IntPtr.Zero, 0x2); // STA
        Guid clsid = new Guid("8E1B0F5C-1E8B-4D3A-9A2C-5B7E9C4C2A11");
        Guid iid = new Guid("a08ce4d0-fa25-44ab-b57c-c7b1c323e0b9");
        IntPtr ppv;
        int hr = CoCreateInstance(ref clsid, IntPtr.Zero, 4 /* CLSCTX_LOCAL_SERVER */, ref iid, out ppv);
        if (hr != 0) return string.Format("CoCreateInstance FAILED hr=0x{0:X8}", hr);

        var cmd = (IExplorerCommand)Marshal.GetObjectForIUnknown(ppv);

        IntPtr title;
        int hrTitle = cmd.GetTitle(IntPtr.Zero, out title);
        string titleText = (hrTitle == 0 && title != IntPtr.Zero) ? Marshal.PtrToStringUni(title) : "";
        if (title != IntPtr.Zero) CoTaskMemFree(title);

        IntPtr icon;
        int hrIcon = cmd.GetIcon(IntPtr.Zero, out icon);
        string iconText = (hrIcon == 0 && icon != IntPtr.Zero) ? Marshal.PtrToStringUni(icon) : "";
        if (icon != IntPtr.Zero) CoTaskMemFree(icon);

        Guid canonical;
        int hrCanonical = cmd.GetCanonicalName(out canonical);

        IntPtr enumPtr;
        int hrEnum = cmd.EnumSubCommands(out enumPtr);

        Marshal.Release(ppv);

        return string.Format(
            "GetTitle      hr=0x{0:X8} '{1}'{2}GetIcon       hr=0x{3:X8} '{4}'{2}GetCanonical  hr=0x{5:X8} {6}{2}EnumSubCmds   hr=0x{7:X8} (E_NOTIMPL expected)",
            hrTitle, titleText, Environment.NewLine,
            hrIcon, iconText,
            hrCanonical, canonical,
            hrEnum);
    }
}
'@

Write-Host "=== packaged COM activation (out of process, dllhost) ==="
Write-Host ([NppCtxTest]::Test())

Write-Host ""
Write-Host "=== Invoke path used by Explorer (GetState + Invoke on a real item) ==="
$sample = Join-Path $env:TEMP 'npp-ctx-test.txt'
Set-Content -Path $sample -Value 'hello from the MSIX context menu test' -Encoding UTF8
Get-Process -Name 'Notepad++' -ErrorAction SilentlyContinue | Stop-Process -Force
Write-Host ([NppCtxTest]::InvokeTest($sample))
Start-Sleep -Seconds 6
$launched = Get-Process -Name 'Notepad++' -ErrorAction SilentlyContinue
if ($launched) {
    Write-Host ("LAUNCHED  PID={0} Title='{1}'" -f $launched.Id, $launched.MainWindowTitle)
    $launched | ForEach-Object { $_.CloseMainWindow() | Out-Null }
} else {
    Write-Host "NOT LAUNCHED"
}

Write-Host ""
Write-Host "=== File Explorer verbs for C:\Windows\win.ini ==="
$shell = New-Object -ComObject Shell.Application
$item = $shell.Namespace('C:\Windows').ParseName('win.ini')
$verbs = $item.Verbs()
Write-Host ("verb count: {0}" -f $verbs.Count)
$verbs | ForEach-Object { Write-Host ("  - '{0}'" -f $_.Name) }

Write-Host ""
Write-Host "Write-Host ""
Write-Host "=== installed manifest declares the handler? ==="
$pkg = Get-AppxPackage NotepadPlusPlus.MSIX
if (-not $pkg) { Write-Host "package not installed"; exit 1 }
$m = Get-AppxPackageManifest $pkg
$cats = @($m.Package.Applications.Application.Extensions.Extension | ForEach-Object { $_.Category })
Write-Host ("extensions: {0}" -f ($cats -join ', '))
Write-Host ("dll present: {0}" -f (Test-Path (Join-Path $pkg.InstallLocation 'NppShellMsix.dll')))