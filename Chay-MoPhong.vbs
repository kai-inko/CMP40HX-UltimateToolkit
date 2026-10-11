Option Explicit
Dim shell, fso, basePath, scriptPath, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
basePath = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(basePath, "CMP40HX-DriverToggle.ps1")
command = "powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & scriptPath & """ -Simulation"
shell.Run command, 0, False
