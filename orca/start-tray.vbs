' start-tray.vbs - hidden launcher for Orca tray
' Self-locating: runs the dsh-tray.ps1 next to this file,
' so it works from any install location (plugin dir / Startup folder).
Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.GetParentFolderName(WScript.ScriptFullName)
Set ws = CreateObject("WScript.Shell")
ws.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & base & "\dsh-tray.ps1""", 0, False
