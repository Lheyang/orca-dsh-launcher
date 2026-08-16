' start-dsh-server.vbs - hidden launcher for DSH server (autostart)
' Self-locating: runs the start-dsh-server.ps1 next to this file.
Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.GetParentFolderName(WScript.ScriptFullName)
Set ws = CreateObject("WScript.Shell")
ws.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & base & "\start-dsh-server.ps1""", 0, False
