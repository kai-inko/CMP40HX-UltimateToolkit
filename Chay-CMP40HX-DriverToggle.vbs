Option Explicit
Dim shell, fso, basePath, scriptPath, arguments
Set shell = CreateObject("Shell.Application")
Set fso = CreateObject("Scripting.FileSystemObject")
basePath = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(basePath, "CMP40HX-DriverToggle.ps1")
arguments = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & scriptPath & """"
shell.ShellExecute "powershell.exe", arguments, basePath, "runas", 0
