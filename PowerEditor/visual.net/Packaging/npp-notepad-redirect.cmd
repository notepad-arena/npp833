@echo off
rem ============================================================================
rem  Notepad++ MSIX: notepad.exe redirector (no compiled launcher).
rem
rem  Installed by Packaging\notepad-redirect.ps1 to
rem      C:\ProgramData\NppMsixRedirect\npp-notepad-redirect.cmd
rem  and registered as the Image File Execution Options "Debugger" of notepad.exe:
rem      HKLM\...\Image File Execution Options\notepad.exe
rem          Debugger = C:\Windows\System32\cmd.exe /c C:\ProgramData\NppMsixRedirect\npp-notepad-redirect.cmd
rem
rem  IFEO appends the debuggee path and the original arguments, so this script gets:
rem      %1 = C:\Windows\System32\notepad.exe   <- must be dropped
rem      %2..%n = original arguments           <- forwarded as is
rem
rem  Why a script instead of pointing Debugger at the packaged exe:
rem    * C:\Program Files\WindowsApps\... denies direct execution (Access is denied);
rem      packaged binaries can only be started through package activation;
rem    * that path embeds version + architecture + publisher hash, so it breaks on updates;
rem    * Notepad++ would open the appended notepad.exe as a document.
rem
rem  Known limits: a console window flashes briefly (cmd.exe), and switches such as
rem  /p or /pt are forwarded verbatim (they are not translated to print verbs).
rem  Keep this file pure ASCII: cmd.exe reads it in the OEM codepage.
rem ============================================================================

setlocal EnableExtensions DisableDelayedExpansion

set "NPP=%LOCALAPPDATA%\Microsoft\WindowsApps\npp.exe"
if not exist "%NPP%" exit /b 3

set "SKIP=1"
set "ARGS="

:collect
if "%~1"=="" goto launch
if defined SKIP (
    set "SKIP="
) else (
    set "ARGS=%ARGS% "%~1""
)
shift
goto collect

:launch
rem "start" so cmd.exe does not wait for the editor; the empty title is required
rem because the first quoted argument of "start" would be taken as the window title.
start "" "%NPP%" %ARGS%
exit /b 0
