' start-console.vbs - hidden launcher for Orca console window
' Self-locating: runs the dsh-console.ps1 next to this file.
Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.GetParentFolderName(WScript.ScriptFullName)
Set ws = CreateObject("WScript.Shell")
ws.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & base & "\dsh-console.ps1""", 0, False
