#requires -version 5.1
param([switch]$NoMessage, [switch]$SelfTest)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$launcher = Join-Path $root 'Chay-CMP40HX-DriverToggle.vbs'
function New-Shortcut {
    param([string]$Destination)
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $null
    try {
        $shortcut = $shell.CreateShortcut($Destination)
        $shortcut.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
        $shortcut.Arguments = '"{0}"' -f $launcher
        $shortcut.WorkingDirectory = $root
        $shortcut.Description = 'CMP 40HX Driver Toggle'
        $shortcut.Save()
    }
    finally {
        if ($null -ne $shortcut) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
    }
}
try {
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw "Không tìm thấy $launcher" }
    if ($SelfTest) {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('cmp40hx-check-' + [Guid]::NewGuid().ToString('N') + '.lnk')
        try {
            New-Shortcut -Destination $tmp
            if (-not (Test-Path -LiteralPath $tmp)) { throw 'Không tạo được shortcut kiểm thử' }
            Write-Output 'PASS: Tạo được shortcut tạm'
        }
        finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
        exit 0
    }
    $desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
    $programs = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
    if (-not $desktop -or -not $programs) { throw 'Không tìm thấy Desktop hoặc Start Menu.' }
    $paths = @((Join-Path $desktop 'CMP40HX Driver Toggle.lnk'), (Join-Path $programs 'CMP40HX Driver Toggle.lnk'))
    foreach ($path in $paths) { New-Shortcut -Destination $path }
    $message = "Đã tạo shortcut tại:`r`n$($paths -join [Environment]::NewLine)"
    Write-Output $message
    if (-not $NoMessage) {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($message,'CMP40HX Driver Toggle','OK','Information') | Out-Null
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
