' ============================================================================
'  Notepad++ MSIX: notepad.exe redirector, console-free variant (VBScript).
'
'  Installed by Packaging\replace-notepad.ps1 to
'      C:\ProgramData\NppMsixRedirect\npp-notepad-redirect.vbs
'  and registered as the Image File Execution Options "Debugger" of notepad.exe:
'      HKLM\...\Image File Execution Options\notepad.exe
'          Debugger = "C:\Windows\System32\wscript.exe" //nologo "C:\ProgramData\NppMsixRedirect\npp-notepad-redirect.vbs"
'
'  wscript.exe is a GUI subsystem host, so unlike cmd.exe it never creates a console
'  window: no flash at all.
'
'  IFEO appends the debuggee path and the original arguments, so this script receives:
'      argument 0      = C:\Windows\System32\notepad.exe   <- dropped
'      argument 1..n   = original arguments                <- forwarded as is
'
'  Why a script instead of pointing Debugger at the packaged exe:
'    * C:\Program Files\WindowsApps\... denies direct execution (Access is denied);
'      packaged binaries can only be started through package activation;
'    * that path embeds version + architecture + publisher hash, so it breaks on updates;
'    * Notepad++ would open the appended notepad.exe as a document.
'
'  Keep this file pure ASCII.
' ============================================================================

Option Explicit

Dim shell, fso, localAppData, aliasPath, cmdLine, i, arg, total

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

localAppData = shell.ExpandEnvironmentStrings("%LOCALAPPDATA%")
aliasPath = localAppData & "\Microsoft\WindowsApps\npp.exe"

If Not fso.FileExists(aliasPath) Then
    ' The package was removed (or the alias was disabled) but the IFEO redirect is still there.
    ' Tell the user instead of failing silently. Do NOT start C:\Windows\System32\notepad.exe
    ' here: IFEO would redirect it again and it would loop forever.
    MsgBox "Notepad++ (MSIX package) is not installed, but notepad.exe is still redirected to it." & vbCrLf & vbCrLf & _
           "Run restore-notepad.ps1 (PowerEditor\visual.net\Packaging) to get the default Notepad back.", _
           vbExclamation, "Notepad++ MSIX"
    WScript.Quit 3
End If

cmdLine = """" & aliasPath & """"

total = WScript.Arguments.Count
For i = 1 To total - 1       ' skip argument 0 (the notepad.exe path appended by IFEO)
    arg = WScript.Arguments(i)
    If Len(arg) > 0 Then
        cmdLine = cmdLine & " """ & arg & """"
    End If
Next

' 1 = normal window (Notepad++ draws its own UI), False = do not wait for it
shell.Run cmdLine, 1, False
