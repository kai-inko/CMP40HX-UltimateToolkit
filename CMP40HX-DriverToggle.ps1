#requires -version 5.1

param(
    [switch]$CheckOnly,
    [string]$ValidateGameInf = '',
    [string]$ScanFolder = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:HardwareId = 'PCI\VEN_10DE&DEV_1F0B'
$script:GameModel = ''
$script:Version = '1.3.3-public' 
$script:AppDirectory = Split-Path -Parent $PSCommandPath
$script:LauncherPath = Join-Path $script:AppDirectory 'Chay-CMP40HX-DriverToggle.vbs'
$script:DesktopShortcutName = 'CMP40HX Ultimate Toolkit.lnk'
$script:StartMenuShortcutName = 'CMP40HX Ultimate Toolkit.lnk'
$script:ConfigPath = Join-Path $script:AppDirectory 'cmp40hx-profiles.json'
$script:LogPath = Join-Path $script:AppDirectory 'cmp40hx-switch.log'

function Write-AppLog {
    param([string]$Message)

    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
}

function Update-DesktopShortcut {
    param(
        [ValidateSet('Work', 'Game')][string]$Profile,
        [switch]$CreateIfMissing
    )
    if (-not (Test-Path -LiteralPath $script:LauncherPath -PathType Leaf)) {
        throw "Không tìm thấy launcher: $($script:LauncherPath)"
    }
    $desktopPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
    $programsPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
    if (-not $desktopPath -or -not $programsPath) { return }
    $shortcutPaths = @(
        (Join-Path $desktopPath $script:DesktopShortcutName),
        (Join-Path $programsPath $script:StartMenuShortcutName)
    )
    if (-not $CreateIfMissing -and -not ($shortcutPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })) { return }
    $shell = New-Object -ComObject WScript.Shell
    try {
        foreach ($shortcutPath in $shortcutPaths) {
            $shortcut = $null
            try {
                $shortcut = $shell.CreateShortcut($shortcutPath)
                $shortcut.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
                $shortcut.Arguments = '"{0}"' -f $script:LauncherPath
                $shortcut.WorkingDirectory = $script:AppDirectory
                $shortcut.Description = if ($Profile -eq 'Game') { 'CMP 40HX - chế độ chơi game' } else { 'CMP 40HX - chế độ làm việc' }
                $shortcut.Save()
            }
            finally {
                if ($shortcut) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
            }
        }
    }
    finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
    Write-AppLog "Đã cập nhật shortcut Desktop và Start Menu: $Profile"
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-ElevatedCopy {
    $arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath.Replace('"', '\"')
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments | Out-Null
}

function Get-DriverStorePackages {
    $raw = (& pnputil.exe /enum-drivers 2>&1 | Out-String)
    $blocks = $raw -split '(?:\r?\n){2,}'
    $results = @()

    foreach ($block in $blocks) {
        if ($block -notmatch '(?im)^Published Name:\s*(oem\d+\.inf)\s*$') {
            continue
        }

        $publishedName = $Matches[1]
        $originalName = if ($block -match '(?im)^Original Name:\s*(.+?)\s*$') { $Matches[1].Trim() } else { '' }
        $provider = if ($block -match '(?im)^Provider Name:\s*(.+?)\s*$') { $Matches[1].Trim() } else { '' }
        $version = if ($block -match '(?im)^Driver Version:\s*(.+?)\s*$') { $Matches[1].Trim() } else { '' }
        $signer = if ($block -match '(?im)^Signer Name:\s*(.+?)\s*$') { $Matches[1].Trim() } else { '' }

        $results += [pscustomobject]@{
            PublishedName = $publishedName
            OriginalName  = $originalName
            Provider      = $provider
            Version       = $version
            Signer        = $signer
        }
    }

    return $results
}

function Get-CmpDeviceInfo {
    $raw = (& pnputil.exe /enum-devices /class Display /drivers 2>&1 | Out-String)
    $blocks = [regex]::Split($raw, '(?im)(?=^Instance ID:\s*)')
    $deviceBlock = $blocks | Where-Object { $_ -match [regex]::Escape($script:HardwareId) } | Select-Object -First 1

    if (-not $deviceBlock) {
        throw "Không tìm thấy CMP 40HX có hardware ID $($script:HardwareId)."
    }

    $instanceId = if ($deviceBlock -match '(?im)^Instance ID:\s*(.+?)\s*$') { $Matches[1].Trim() } else { '' }
    $description = if ($deviceBlock -match '(?im)^Device Description:\s*(.+?)\s*$') { $Matches[1].Trim() } else { 'CMP 40HX' }
    $status = if ($deviceBlock -match '(?im)^Status:\s*(.+?)\s*$') { $Matches[1].Trim() } else { 'Unknown' }
    $publishedName = if ($deviceBlock -match '(?im)^Driver Name:\s*(oem\d+\.inf)\s*$') { $Matches[1].Trim() } else { '' }
    $package = Get-DriverStorePackages | Where-Object { $_.PublishedName -ieq $publishedName } | Select-Object -First 1

    return [pscustomobject]@{
        InstanceId    = $instanceId
        Description   = $description
        Status        = $status
        PublishedName = $publishedName
        OriginalName  = if ($package) { $package.OriginalName } else { '' }
        Version       = if ($package) { $package.Version } else { '' }
        Signer        = if ($package) { $package.Signer } else { '' }
    }
}

function Get-DriverStoreInfPath {
    param([Parameter(Mandatory = $true)][string]$PublishedName)

    # Windows keeps each published OEM INF here. Reading it directly avoids the
    # very slow Get-WindowsDriver/DISM scan that can make startup appear frozen.
    $windowsDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    $publishedInf = Join-Path (Join-Path $windowsDirectory 'INF') $PublishedName
    if (Test-Path -LiteralPath $publishedInf -PathType Leaf) {
        return $publishedInf
    }

    Write-AppLog "Không tìm thấy INF hiện tại tại $publishedInf"
    return ''
}

function Get-InfVersion {
    param([string]$InfPath)

    if (-not $InfPath -or -not (Test-Path -LiteralPath $InfPath)) {
        return ''
    }

    $line = Select-String -LiteralPath $InfPath -Pattern '^\s*DriverVer\s*=\s*(.+)$' -CaseSensitive:$false |
        Select-Object -First 1
    if (-not $line) {
        return ''
    }

    $value = $line.Matches[0].Groups[1].Value.Trim()
    if ($value -match ',\s*([0-9.]+)\s*$') {
        return $Matches[1]
    }
    return $value
}

# Chi quet/phan tich INF, KHONG goi API cai driver.
# Khoanh vung dong khai bao model = InstallSection,PCI\\VEN_10DE&DEV_1F0B.
# Loai tru comment va dong mo ta [Strings] chi nhac toi Hardware ID.
function Test-InfHasCmp40HxInstallEntry {
    param([Parameter(Mandatory = $true)][string]$InfPath)
    if (-not (Test-Path -LiteralPath $InfPath -PathType Leaf)) { return $false }

    $escapedId = [regex]::Escape($script:HardwareId)
    $entryPattern = '^\s*[^;#\[\]\r\n]+?\s*=\s*[^,;\r\n]+,\s*' + $escapedId + '(?=&|\s*(?:;|$))'
    $inNvidiaModelsSection = $false
    foreach ($line in [IO.File]::ReadLines($InfPath)) {
        if ($line -match '^\s*\[([^\]]+)\]') {
            $inNvidiaModelsSection = ($Matches[1] -match '\.NTamd64(?:\.|$)')
            continue
        }
        if ($inNvidiaModelsSection -and $line -match $entryPattern) { return $true }
    }
    return $false
}

function Get-DriverFolderFromInf {
    param([string]$InfPath)
    if (-not $InfPath) { return '' }
    $parent = Split-Path -Parent $InfPath
    if ((Split-Path -Leaf $parent) -ieq 'Display.Driver') {
        return (Split-Path -Parent $parent)
    }
    return $parent
}

function Resolve-DriverFolder {
    param([Parameter(Mandatory = $true)][string]$FolderPath)

    $folder = $FolderPath.Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        throw "Không tìm thấy thư mục driver: $folder"
    }
    $fullFolder = (Get-Item -LiteralPath $folder -ErrorAction Stop).FullName
    $files = @(Get-ChildItem -LiteralPath $fullFolder -Filter '*.inf' -File -Recurse -ErrorAction Stop)
    if ($files.Count -eq 0) {
        throw "Thư mục không chứa file INF: $fullFolder"
    }

    $candidates = @()
    foreach ($file in $files) {
        # Chi xet INF driver man hinh co DriverVer va device-install entry that.
        # Khong nhan INF chỉ nhac ma 1F0B trong comment, [Strings] hay ghi chu.
        $header = Select-String -LiteralPath $file.FullName -Pattern '^\s*Class\s*=\s*Display\s*(?:;.*)?$' -CaseSensitive:$false -Quiet
        if (-not $header) { continue }
        if (-not (Test-InfHasCmp40HxInstallEntry -InfPath $file.FullName)) { continue }
        $version = Get-InfVersion -InfPath $file.FullName
        if ([string]::IsNullOrWhiteSpace($version)) { continue }
        $candidates += [pscustomobject]@{ Path = $file.FullName; Version = $version }
    }

    if ($candidates.Count -eq 0) {
        throw "Không tìm thấy INF Display hợp lệ có dòng cài đặt $($script:HardwareId) trong '$fullFolder'. Kiểm tra bộ driver đã giải nén hoặc bản mod."
    }
    if ($candidates.Count -gt 1) {
        $items = ($candidates | ForEach-Object { " - $($_.Path) (DriverVer $($_.Version))" }) -join "`r`n"
        throw "Phát hiện $($candidates.Count) INF cùng hỗ trợ CMP 40HX trong một thư mục. Không tự chọn để tránh cài nhầm. Hãy chọn thư mục con chỉ chứa đúng bộ driver cần dùng.`r`n$items"
    }

    Write-AppLog "Tự tìm INF trong '$fullFolder' -> $($candidates[0].Path), DriverVer=$($candidates[0].Version)"
    return [pscustomobject]@{
        Folder = $fullFolder
        InfPath = $candidates[0].Path
        Version = $candidates[0].Version
    }
}

function Assert-DriverProfileFolder {
    param($Config, [ValidateSet('Work', 'Game')][string]$Profile)

    $folder = if ($Profile -eq 'Work') { [string]$Config.WorkDirectory } else { [string]$Config.GameDirectory }
    $savedInf = if ($Profile -eq 'Work') { [string]$Config.WorkInf } else { [string]$Config.GameInf }
    $savedVer = if ($Profile -eq 'Work') { [string]$Config.WorkVersion } else { [string]$Config.GameVersion }
    if (-not $folder) { throw "Chưa chọn thư mục driver $Profile. Mở Thiết lập driver để chọn." }
    $found = Resolve-DriverFolder -FolderPath $folder
    if ($found.InfPath -ine $savedInf -or $found.Version -ne $savedVer) {
        throw "Thư mục driver $Profile đã thay đổi so với khi lưu cấu hình. Mở Thiết lập driver, kiểm tra và lưu lại trước khi chuyển."
    }
    return $found
}

function Test-InfSupportsCmp40Hx {
    param([string]$InfPath)

    if (-not $InfPath -or -not (Test-Path -LiteralPath $InfPath -PathType Leaf)) {
        return $false
    }

    return (Test-InfHasCmp40HxInstallEntry -InfPath $InfPath)
}

function Test-InfContainsGameModel {
    param([string]$InfPath, [string]$ModelName)

    if ([string]::IsNullOrWhiteSpace($ModelName) -or -not $InfPath -or -not (Test-Path -LiteralPath $InfPath -PathType Leaf)) {
        return $false
    }

    # Kiểm tra sơ bộ: khi cài thật, SetupAPI còn xác thực model trong danh sách driver.
    return $null -ne (Select-String -LiteralPath $InfPath -SimpleMatch $ModelName -CaseSensitive:$false | Select-Object -First 1)
}

function Get-GameInstallSelection {
    param([string]$InfPath, [string]$ModelName, [switch]$ValidateWithSetupApi)

    if (-not $InfPath -or -not (Test-Path -LiteralPath $InfPath -PathType Leaf)) {
        throw 'Chưa chọn file INF hợp lệ cho chế độ chơi game.'
    }
    if (Test-InfSupportsCmp40Hx -InfPath $InfPath) {
        return [pscustomobject]@{ Mode = 'Compatible'; ModelName = '' }
    }
    if (-not (Test-InfContainsGameModel -InfPath $InfPath -ModelName $ModelName)) {
        throw 'INF game không chứa DEV_1F0B. Hãy nhập đúng tên model trong INF hoặc dùng INF đã hỗ trợ CMP 40HX.'
    }
    if ($ValidateWithSetupApi) {
        Initialize-ForcedModelDriverApi
        $device = Get-CmpDeviceInfo
        if (-not [Cmp40Hx.ForcedModelDriverApi]::ContainsModel($device.InstanceId, ([IO.Path]::GetFullPath($InfPath)), $ModelName)) {
            throw "SetupAPI không tìm thấy model '$ModelName' trong INF dành cho thiết bị hiện tại."
        }
    }
    return [pscustomobject]@{ Mode = 'ForcedModel'; ModelName = $ModelName }
}

function New-DefaultConfig {
    # Không dùng C:\Windows\INF\oem*.inf làm bộ cài nguồn: API cài driver
    # yêu cầu đường dẫn gói INF đầy đủ, có các file driver đi kèm.
    return [pscustomobject]@{
        HardwareId = $script:HardwareId
        WorkInf     = ''
        WorkVersion = ''
        WorkDirectory = ''
        GameDirectory = ''
        GameInf     = ''
        GameVersion = ''
        GameModel   = $script:GameModel
    }
}

function Save-Config {
    param($Config)

    if (-not ($Config.PSObject.Properties.Name -contains 'GameModel')) {
        $Config | Add-Member -NotePropertyName GameModel -NotePropertyValue $script:GameModel
    }
    if (-not ($Config.PSObject.Properties.Name -contains 'WorkDirectory')) {
        $Config | Add-Member -NotePropertyName WorkDirectory -NotePropertyValue (Get-DriverFolderFromInf -InfPath $Config.WorkInf)
    }
    if (-not ($Config.PSObject.Properties.Name -contains 'GameDirectory')) {
        $Config | Add-Member -NotePropertyName GameDirectory -NotePropertyValue (Get-DriverFolderFromInf -InfPath $Config.GameInf)
    }
    # Giữ đúng model mà người dùng chọn; không tự ép model của GPU khác.
    $Config.GameModel = ([string]$Config.GameModel).Trim()
    $Config.WorkVersion = Get-InfVersion -InfPath $Config.WorkInf
    $Config.GameVersion = Get-InfVersion -InfPath $Config.GameInf
    $Config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
}

function Get-Config {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        $config = New-DefaultConfig
        Save-Config -Config $config
        return $config
    }

    try {
        $config = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $config.HardwareId -or $config.HardwareId -ne $script:HardwareId) {
            throw 'Hardware ID trong cấu hình không hợp lệ.'
        }
        $migrated = $false
        if (-not ($config.PSObject.Properties.Name -contains 'GameModel')) {
            $config | Add-Member -NotePropertyName GameModel -NotePropertyValue $script:GameModel
            $migrated = $true
        }
        if (-not ($config.PSObject.Properties.Name -contains 'WorkDirectory')) {
            $config | Add-Member -NotePropertyName WorkDirectory -NotePropertyValue (Get-DriverFolderFromInf -InfPath $config.WorkInf)
            $migrated = $true
        }
        if (-not ($config.PSObject.Properties.Name -contains 'GameDirectory')) {
            $config | Add-Member -NotePropertyName GameDirectory -NotePropertyValue (Get-DriverFolderFromInf -InfPath $config.GameInf)
            $migrated = $true
        }
        if ($migrated) { Save-Config -Config $config }
        return $config
    }
    catch {
        $backup = "$($script:ConfigPath).invalid-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Move-Item -LiteralPath $script:ConfigPath -Destination $backup
        Write-AppLog "Cấu hình lỗi đã được chuyển sang $backup"
        $config = New-DefaultConfig
        Save-Config -Config $config
        return $config
    }
}

function Initialize-NativeDriverApi {
    if ('Cmp40Hx.NativeDriverApi' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Cmp40Hx
{
    public static class NativeDriverApi
    {
        [DllImport("newdev.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool UpdateDriverForPlugAndPlayDevicesW(
            IntPtr hwndParent,
            string hardwareId,
            string fullInfPath,
            uint installFlags,
            out bool rebootRequired);

        private const uint INSTALLFLAG_FORCE = 0x00000001;
        private const uint INSTALLFLAG_NONINTERACTIVE = 0x00000004;

        public static bool ForceInstall(string hardwareId, string fullInfPath)
        {
            bool rebootRequired;
            bool ok = UpdateDriverForPlugAndPlayDevicesW(
                IntPtr.Zero,
                hardwareId,
                fullInfPath,
                INSTALLFLAG_FORCE | INSTALLFLAG_NONINTERACTIVE,
                out rebootRequired);

            if (!ok)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            return rebootRequired;
        }
    }
}
'@
}

function Initialize-ForcedModelDriverApi {
    if ('Cmp40Hx.ForcedModelDriverApi' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Cmp40Hx
{
    public static class ForcedModelDriverApi
    {
        private const uint SPDIT_CLASSDRIVER = 0x00000001;
        private const uint DI_SHOWALL = 0x00000007;
        private const uint DI_ENUMSINGLEINF = 0x00010000;
        private const uint DI_QUIETINSTALL = 0x00800000;
        private const uint DI_FLAGSEX_ALLOWEXCLUDEDDRVS = 0x00000800;
        private static readonly IntPtr InvalidHandleValue = new IntPtr(-1);

        [StructLayout(LayoutKind.Sequential)]
        private struct SP_DEVINFO_DATA
        {
            public uint cbSize;
            public Guid ClassGuid;
            public uint DevInst;
            public IntPtr Reserved;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct SP_DEVINSTALL_PARAMS
        {
            public uint cbSize;
            public uint Flags;
            public uint FlagsEx;
            public IntPtr hwndParent;
            public IntPtr InstallMsgHandler;
            public IntPtr InstallMsgHandlerContext;
            public IntPtr FileQueue;
            public IntPtr ClassInstallReserved;
            public uint Reserved;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string DriverPath;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct SP_DRVINFO_DATA
        {
            public uint cbSize;
            public uint DriverType;
            public IntPtr Reserved;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
            public string Description;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
            public string MfgName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
            public string ProviderName;
            public System.Runtime.InteropServices.ComTypes.FILETIME DriverDate;
            public ulong DriverVersion;
        }

        [DllImport("setupapi.dll", SetLastError = true)]
        private static extern IntPtr SetupDiCreateDeviceInfoList(IntPtr ClassGuid, IntPtr hwndParent);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool SetupDiOpenDeviceInfoW(IntPtr DeviceInfoSet, string DeviceInstanceId, IntPtr hwndParent, uint OpenFlags, ref SP_DEVINFO_DATA DeviceInfoData);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool SetupDiGetDeviceInstallParamsW(IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData, ref SP_DEVINSTALL_PARAMS DeviceInstallParams);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool SetupDiSetDeviceInstallParamsW(IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData, ref SP_DEVINSTALL_PARAMS DeviceInstallParams);

        [DllImport("setupapi.dll", SetLastError = true)]
        private static extern bool SetupDiBuildDriverInfoList(IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData, uint DriverType);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool SetupDiEnumDriverInfoW(IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData, uint DriverType, uint MemberIndex, ref SP_DRVINFO_DATA DriverInfoData);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool SetupDiSetSelectedDriverW(IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData, ref SP_DRVINFO_DATA DriverInfoData);

        [DllImport("newdev.dll", SetLastError = true)]
        private static extern bool DiInstallDevice(IntPtr hwndParent, IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData, ref SP_DRVINFO_DATA DriverInfoData, uint Flags, out bool NeedReboot);

        [DllImport("setupapi.dll", SetLastError = true)]
        private static extern bool SetupDiDestroyDriverInfoList(IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData, uint DriverType);

        [DllImport("setupapi.dll", SetLastError = true)]
        private static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);

        private static void ThrowLastError(string operation)
        {
            int code = Marshal.GetLastWin32Error();
            throw new Win32Exception(code, operation + " failed with Windows error " + code);
        }

        private static IntPtr BuildSingleInfList(string instanceId, string infPath, out SP_DEVINFO_DATA device)
        {
            IntPtr set = SetupDiCreateDeviceInfoList(IntPtr.Zero, IntPtr.Zero);
            if (set == InvalidHandleValue) ThrowLastError("SetupDiCreateDeviceInfoList");

            device = new SP_DEVINFO_DATA();
            device.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
            try
            {
                if (!SetupDiOpenDeviceInfoW(set, instanceId, IntPtr.Zero, 0, ref device)) ThrowLastError("SetupDiOpenDeviceInfo");

                SP_DEVINSTALL_PARAMS parameters = new SP_DEVINSTALL_PARAMS();
                parameters.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVINSTALL_PARAMS));
                if (!SetupDiGetDeviceInstallParamsW(set, ref device, ref parameters)) ThrowLastError("SetupDiGetDeviceInstallParams");
                parameters.Flags |= DI_SHOWALL | DI_ENUMSINGLEINF | DI_QUIETINSTALL;
                parameters.FlagsEx |= DI_FLAGSEX_ALLOWEXCLUDEDDRVS;
                parameters.DriverPath = infPath;
                if (!SetupDiSetDeviceInstallParamsW(set, ref device, ref parameters)) ThrowLastError("SetupDiSetDeviceInstallParams");
                if (!SetupDiBuildDriverInfoList(set, ref device, SPDIT_CLASSDRIVER)) ThrowLastError("SetupDiBuildDriverInfoList");
                return set;
            }
            catch
            {
                SetupDiDestroyDeviceInfoList(set);
                throw;
            }
        }

        private static SP_DRVINFO_DATA FindModel(IntPtr set, ref SP_DEVINFO_DATA device, string modelName)
        {
            for (uint index = 0; ; index++)
            {
                SP_DRVINFO_DATA driver = new SP_DRVINFO_DATA();
                driver.cbSize = (uint)Marshal.SizeOf(typeof(SP_DRVINFO_DATA));
                if (!SetupDiEnumDriverInfoW(set, ref device, SPDIT_CLASSDRIVER, index, ref driver))
                {
                    int error = Marshal.GetLastWin32Error();
                    if (error == 259) break;
                    throw new Win32Exception(error, "SetupDiEnumDriverInfo failed");
                }
                if (String.Equals(driver.Description, modelName, StringComparison.OrdinalIgnoreCase)) return driver;
            }
            throw new InvalidOperationException("The selected INF does not contain model: " + modelName);
        }

        public static bool ContainsModel(string instanceId, string infPath, string modelName)
        {
            SP_DEVINFO_DATA device;
            IntPtr set = BuildSingleInfList(instanceId, infPath, out device);
            try
            {
                FindModel(set, ref device, modelName);
                return true;
            }
            catch (InvalidOperationException)
            {
                return false;
            }
            finally
            {
                SetupDiDestroyDriverInfoList(set, ref device, SPDIT_CLASSDRIVER);
                SetupDiDestroyDeviceInfoList(set);
            }
        }

        public static bool ForceInstallModel(string instanceId, string infPath, string modelName)
        {
            SP_DEVINFO_DATA device;
            IntPtr set = BuildSingleInfList(instanceId, infPath, out device);
            try
            {
                SP_DRVINFO_DATA driver = FindModel(set, ref device, modelName);
                if (!SetupDiSetSelectedDriverW(set, ref device, ref driver)) ThrowLastError("SetupDiSetSelectedDriver");
                bool rebootRequired;
                if (!DiInstallDevice(IntPtr.Zero, set, ref device, ref driver, 0, out rebootRequired)) ThrowLastError("DiInstallDevice");
                return rebootRequired;
            }
            finally
            {
                SetupDiDestroyDriverInfoList(set, ref device, SPDIT_CLASSDRIVER);
                SetupDiDestroyDeviceInfoList(set);
            }
        }
    }
}
'@
}

function Install-CmpDriver {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileName,
        [Parameter(Mandatory = $true)][string]$InfPath,
        [ValidateSet('Compatible', 'ForcedModel')][string]$InstallMode = 'Compatible',
        [string]$ModelName = ''
    )

    $fullPath = [IO.Path]::GetFullPath($InfPath)
    Write-AppLog "Bắt đầu chuyển sang '$ProfileName': $fullPath"

    if ($InstallMode -eq 'ForcedModel') {
        if (-not $ModelName) {
            throw 'Chưa cấu hình model giả lập cho GPU chơi LOL / Valorant.'
        }
        Initialize-ForcedModelDriverApi
        $deviceBefore = Get-CmpDeviceInfo
        if (-not [Cmp40Hx.ForcedModelDriverApi]::ContainsModel($deviceBefore.InstanceId, $fullPath, $ModelName)) {
            throw "INF LOL / Valorant không chứa model '$ModelName'."
        }
        $rebootRequired = [Cmp40Hx.ForcedModelDriverApi]::ForceInstallModel($deviceBefore.InstanceId, $fullPath, $ModelName)
    }
    else {
        if (-not (Test-InfSupportsCmp40Hx -InfPath $fullPath)) {
            throw "INF GPU công suất tối đa không chứa $($script:HardwareId)."
        }
        Initialize-NativeDriverApi
        $rebootRequired = [Cmp40Hx.NativeDriverApi]::ForceInstall($script:HardwareId, $fullPath)
    }

    Start-Sleep -Seconds 2
    $after = Get-CmpDeviceInfo
    Write-AppLog "Hoàn tất '$ProfileName': $($after.Description), $($after.PublishedName), $($after.Version), reboot=$rebootRequired"
    if (-not $rebootRequired) {
        $expectedVersion = Get-InfVersion -InfPath $fullPath
        $actualVersion = Convert-DriverVersionForComparison -Value $after.Version
        if ($expectedVersion -and $actualVersion -and $expectedVersion -ne $actualVersion) {
            throw "API trả về thành công nhưng driver hiện tại ($actualVersion) chưa trùng INF đã chọn ($expectedVersion). Kiểm tra Device Manager và nhật ký; KHÔNG coi chuyển đổi đã hoàn tất."
        }
    }

    return [pscustomobject]@{
        RebootRequired = $rebootRequired
        Device         = $after
    }
}

function Select-DriverFolder {
    param(
        [string]$InitialPath,
        [string]$DialogTitle = 'Chọn thư mục driver đã giải nén'
    )
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $DialogTitle
    $dialog.ShowNewFolderButton = $false
    if ($InitialPath -and (Test-Path -LiteralPath $InitialPath -PathType Container)) {
        $dialog.SelectedPath = $InitialPath
    }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.SelectedPath
    }
    return ''
}

function Show-SettingsDialog {
    param($Config)

    $settings = New-Object System.Windows.Forms.Form
    $settings.Text = 'Thiết lập thư mục driver CMP 40HX'
    $settings.StartPosition = 'CenterParent'
    $settings.Size = New-Object Drawing.Size(760, 470)
    $settings.FormBorderStyle = 'FixedDialog'
    $settings.MaximizeBox = $false
    $settings.MinimizeBox = $false

    $info = New-Object System.Windows.Forms.Label
    $info.Location = New-Object Drawing.Point(20, 14)
    $info.Size = New-Object Drawing.Size(710, 48)
    $info.Text = 'Chỉ chọn THƯ MỤC chứa bộ driver đã giải nén (có thể là thư mục cha của Display.Driver). Phần mềm sẽ tự tìm INF Display chứa DEV_1F0B; không cài driver khi bấm Lưu.'
    $settings.Controls.Add($info)

    $workLabel = New-Object System.Windows.Forms.Label
    $workLabel.Location = New-Object Drawing.Point(20, 74)
    $workLabel.Size = New-Object Drawing.Size(150, 24)
    $workLabel.Text = 'GPU công suất tối đa:'
    $settings.Controls.Add($workLabel)

    $workText = New-Object System.Windows.Forms.TextBox
    $workText.Location = New-Object Drawing.Point(170, 72)
    $workText.Size = New-Object Drawing.Size(480, 24)
    $workText.Text = [string]$Config.WorkDirectory
    $settings.Controls.Add($workText)

    $workResult = New-Object System.Windows.Forms.Label
    $workResult.Location = New-Object Drawing.Point(170, 103)
    $workResult.Size = New-Object Drawing.Size(560, 34)
    $workResult.ForeColor = [Drawing.Color]::DimGray
    $workResult.Text = if ($Config.WorkInf) { "INF đã lưu: $([IO.Path]::GetFileName([string]$Config.WorkInf)) - $($Config.WorkVersion)" } else { 'Chưa tìm INF' }
    $settings.Controls.Add($workResult)

    $workBrowse = New-Object System.Windows.Forms.Button
    $workBrowse.Location = New-Object Drawing.Point(660, 70)
    $workBrowse.Size = New-Object Drawing.Size(70, 28)
    $workBrowse.Text = 'Chọn...'
    $workBrowse.Add_Click({
        $selected = Select-DriverFolder -InitialPath $workText.Text -DialogTitle 'Chọn THƯ MỤC driver tác vụ AI / làm việc'
        if ($selected) {
            $workText.Text = $selected
            try {
                $resolved = Resolve-DriverFolder -FolderPath $selected
                $workResult.Text = "Tìm thấy: $([IO.Path]::GetFileName($resolved.InfPath)) - DriverVer $($resolved.Version)"
            }
            catch { $workResult.Text = "Không hợp lệ: $($_.Exception.Message)" }
        }
    })
    $settings.Controls.Add($workBrowse)

    $gameLabel = New-Object System.Windows.Forms.Label
    $gameLabel.Location = New-Object Drawing.Point(20, 146)
    $gameLabel.Size = New-Object Drawing.Size(150, 24)
    $gameLabel.Text = 'GPU LOL / Valorant:'
    $settings.Controls.Add($gameLabel)

    $gameText = New-Object System.Windows.Forms.TextBox
    $gameText.Location = New-Object Drawing.Point(170, 144)
    $gameText.Size = New-Object Drawing.Size(480, 24)
    $gameText.Text = [string]$Config.GameDirectory
    $settings.Controls.Add($gameText)

    $gameResult = New-Object System.Windows.Forms.Label
    $gameResult.Location = New-Object Drawing.Point(170, 175)
    $gameResult.Size = New-Object Drawing.Size(560, 34)
    $gameResult.ForeColor = [Drawing.Color]::DimGray
    $gameResult.Text = if ($Config.GameInf) { "INF đã lưu: $([IO.Path]::GetFileName([string]$Config.GameInf)) - $($Config.GameVersion)" } else { 'Chưa tìm INF' }
    $settings.Controls.Add($gameResult)

    $gameBrowse = New-Object System.Windows.Forms.Button
    $gameBrowse.Location = New-Object Drawing.Point(660, 142)
    $gameBrowse.Size = New-Object Drawing.Size(70, 28)
    $gameBrowse.Text = 'Chọn...'
    $gameBrowse.Add_Click({
        $selected = Select-DriverFolder -InitialPath $gameText.Text -DialogTitle 'Chọn THƯ MỤC driver 460 mod chơi LOL'
        if ($selected) {
            $gameText.Text = $selected
            try {
                $resolved = Resolve-DriverFolder -FolderPath $selected
                $gameResult.Text = "Tìm thấy: $([IO.Path]::GetFileName($resolved.InfPath)) - DriverVer $($resolved.Version)"
            }
            catch { $gameResult.Text = "Không hợp lệ: $($_.Exception.Message)" }
        }
    })
    $settings.Controls.Add($gameBrowse)

    $modelLabel = New-Object System.Windows.Forms.Label
    $modelLabel.Location = New-Object Drawing.Point(20, 218)
    $modelLabel.Size = New-Object Drawing.Size(150, 35)
    $modelLabel.Text = 'Model ép (nếu cần):'
    $settings.Controls.Add($modelLabel)

    $modelText = New-Object System.Windows.Forms.TextBox
    $modelText.Location = New-Object Drawing.Point(170, 216)
    $modelText.Size = New-Object Drawing.Size(560, 24)
    $modelText.Text = [string]$Config.GameModel
    $settings.Controls.Add($modelText)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Location = New-Object Drawing.Point(20, 263)
    $hint.Size = New-Object Drawing.Size(710, 76)
    $hint.ForeColor = [Drawing.Color]::DimGray
    $hint.Text = 'Cả hai bộ driver 460 mod và 617.14 bạn đang dùng đều có DEV_1F0B: để trống Model ép. Nếu nhiều INF cùng khớp, công cụ sẽ DỪNG chứ không chọn bừa. Đổi thư mục hoặc sửa INF phải vào đây lưu lại.'
    $settings.Controls.Add($hint)

    $save = New-Object System.Windows.Forms.Button
    $save.Location = New-Object Drawing.Point(540, 351)
    $save.Size = New-Object Drawing.Size(90, 32)
    $save.Text = 'Lưu'
    $save.Add_Click({
        try {
            $work = Resolve-DriverFolder -FolderPath $workText.Text
            $game = Resolve-DriverFolder -FolderPath $gameText.Text
            $choice = Get-GameInstallSelection -InfPath $game.InfPath -ModelName $modelText.Text -ValidateWithSetupApi
            if ($work.Version -eq $game.Version) {
                throw 'Hai INF có cùng DriverVer nên không phân biệt được hai chế độ. Chọn hai phiên bản driver khác nhau.'
            }
            if ($choice.Mode -eq 'ForcedModel') {
                throw 'Chế độ tự chọn thư mục chỉ hỗ trợ INF cài trực tiếp cho DEV_1F0B, không tự ép model khác.'
            }
            $Config.WorkDirectory = $work.Folder
            $Config.GameDirectory = $game.Folder
            $Config.WorkInf = $work.InfPath
            $Config.GameInf = $game.InfPath
            $Config.GameModel = $modelText.Text.Trim()
            Save-Config -Config $Config
            $settings.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $settings.Close()
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'CMP 40HX - Không thể lưu', 'OK', 'Warning') | Out-Null
        }
    })
    $settings.Controls.Add($save)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Location = New-Object Drawing.Point(640, 351)
    $cancel.Size = New-Object Drawing.Size(90, 32)
    $cancel.Text = 'Hủy'
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $settings.Controls.Add($cancel)

    return $settings.ShowDialog()
}

function Convert-DriverVersionForComparison {
    param([string]$Value)
    if (-not $Value) { return '' }
    if ($Value -match '([0-9]+(?:\.[0-9]+){2,})\s*$') { return $Matches[1] }
    return $Value.Trim()
}

function Start-Gui {
    Write-AppLog "ApartmentState=$([Threading.Thread]::CurrentThread.ApartmentState)"
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    Write-AppLog 'Đã nạp Windows Forms.'

    Write-AppLog 'Đang đọc cấu hình.'
    $script:Config = Get-Config
    Write-AppLog 'Đã đọc cấu hình; đang tạo giao diện.'

    $navy = [Drawing.Color]::FromArgb(19, 42, 76)
    $blue = [Drawing.Color]::FromArgb(37, 99, 235)
    $green = [Drawing.Color]::FromArgb(22, 163, 74)
    $orange = [Drawing.Color]::FromArgb(194, 65, 12)
    $surface = [Drawing.Color]::White
    $background = [Drawing.Color]::FromArgb(241, 245, 249)
    $muted = [Drawing.Color]::FromArgb(71, 85, 105)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'CMP40HX Ultimate Toolkit'
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = $background
    $form.Font = New-Object Drawing.Font('Segoe UI', 9)
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox = $false
    $form.ClientSize = New-Object Drawing.Size(720, 768)   # 88 header + 680 tabs, no leftover strip
    $form.Add_Shown({
        $form.Activate()
        $form.BringToFront()
    })

    $header = New-Object System.Windows.Forms.Panel
    $header.Location = New-Object Drawing.Point(0, 0)
    $header.Size = New-Object Drawing.Size(720, 88)
    $header.BackColor = $navy
    $form.Controls.Add($header)

    $title = New-Object System.Windows.Forms.Label
    $title.Location = New-Object Drawing.Point(24, 17)
    $title.Size = New-Object Drawing.Size(470, 32)
    $title.Font = New-Object Drawing.Font('Segoe UI Semibold', 18, [Drawing.FontStyle]::Bold)
    $title.ForeColor = [Drawing.Color]::White
    $title.Text = 'CMP40HX Ultimate Toolkit'
    $header.Controls.Add($title)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Location = New-Object Drawing.Point(27, 53)
    $subtitle.Size = New-Object Drawing.Size(500, 22)
    $subtitle.ForeColor = [Drawing.Color]::FromArgb(203, 213, 225)
    $subtitle.Text = 'Chuyển hồ sơ driver có kiểm tra - Unlock driver đến hiệu năng tối đa • Bản CMP 40HX'
    $header.Controls.Add($subtitle)

    $btnUpdate = New-Object System.Windows.Forms.Button
    $btnUpdate.Location  = New-Object Drawing.Point(536, 26)
    $btnUpdate.Size      = New-Object Drawing.Size(156, 36)
    $btnUpdate.Text      = 'Tải về bản mới nhất'
    $btnUpdate.FlatStyle = 'Flat'
    $btnUpdate.FlatAppearance.BorderSize = 0
    $btnUpdate.BackColor = $blue
    $btnUpdate.ForeColor = [Drawing.Color]::White
    $btnUpdate.Font      = New-Object Drawing.Font('Segoe UI Semibold', 9, [Drawing.FontStyle]::Bold)
    $btnUpdate.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $header.Controls.Add($btnUpdate)

    $modePanel = New-Object System.Windows.Forms.Panel
    $modePanel.Location = New-Object Drawing.Point(24, 108)
    $modePanel.Size = New-Object Drawing.Size(672, 160)
    $modePanel.BackColor = $navy
    $form.Controls.Add($modePanel)

    $modeHeading = New-Object System.Windows.Forms.Label
    $modeHeading.Location = New-Object Drawing.Point(25, 40)
    $modeHeading.Size = New-Object Drawing.Size(620, 43)
    $modeHeading.TextAlign = 'MiddleCenter'
    $modeHeading.Font = New-Object Drawing.Font('Segoe UI Semibold', 18, [Drawing.FontStyle]::Bold)
    $modeHeading.ForeColor = [Drawing.Color]::White
    $modePanel.Controls.Add($modeHeading)

    $modeDetail = New-Object System.Windows.Forms.Label
    $modeDetail.Location = New-Object Drawing.Point(30, 92)
    $modeDetail.Size = New-Object Drawing.Size(610, 35)
    $modeDetail.TextAlign = 'MiddleCenter'
    $modeDetail.ForeColor = [Drawing.Color]::FromArgb(203, 213, 225)
    $modePanel.Controls.Add($modeDetail)

    $deviceCard = New-Object System.Windows.Forms.Panel
    $deviceCard.Location = New-Object Drawing.Point(24, 284)
    $deviceCard.Size = New-Object Drawing.Size(672, 156)
    $deviceCard.BackColor = $surface
    $deviceCard.BorderStyle = 'FixedSingle'
    $form.Controls.Add($deviceCard)

    $sectionTitle = New-Object System.Windows.Forms.Label
    $sectionTitle.Location = New-Object Drawing.Point(18, 14)
    $sectionTitle.Size = New-Object Drawing.Size(250, 20)
    $sectionTitle.Font = New-Object Drawing.Font('Segoe UI Semibold', 9, [Drawing.FontStyle]::Bold)
    $sectionTitle.ForeColor = $muted
    $sectionTitle.Text = 'TRẠNG THÁI HIỆN TẠI'
    $deviceCard.Controls.Add($sectionTitle)

    $profileLabel = New-Object System.Windows.Forms.Label
    $profileLabel.Location = New-Object Drawing.Point(18, 39)
    $profileLabel.Size = New-Object Drawing.Size(623, 30)
    $profileLabel.Font = New-Object Drawing.Font('Segoe UI Semibold', 15, [Drawing.FontStyle]::Bold)
    $profileLabel.ForeColor = $navy
    $deviceCard.Controls.Add($profileLabel)

    $deviceLabel = New-Object System.Windows.Forms.Label
    $deviceLabel.Location = New-Object Drawing.Point(20, 76)
    $deviceLabel.Size = New-Object Drawing.Size(621, 70)
    $deviceLabel.Font = New-Object Drawing.Font('Segoe UI', 9)
    $deviceLabel.ForeColor = $muted
    $deviceCard.Controls.Add($deviceLabel)

    $warningPanel = New-Object System.Windows.Forms.Panel
    $warningPanel.Location = New-Object Drawing.Point(24, 456)
    $warningPanel.Size = New-Object Drawing.Size(672, 54)
    $warningPanel.BackColor = [Drawing.Color]::FromArgb(255, 237, 213)
    $form.Controls.Add($warningPanel)

    $warningIcon = New-Object System.Windows.Forms.Label
    $warningIcon.Location = New-Object Drawing.Point(16, 14)
    $warningIcon.Size = New-Object Drawing.Size(28, 28)
    $warningIcon.Font = New-Object Drawing.Font('Segoe UI Symbol', 14, [Drawing.FontStyle]::Bold)
    $warningIcon.ForeColor = $orange
    $warningIcon.Text = '!'
    $warningPanel.Controls.Add($warningIcon)

    $warning = New-Object System.Windows.Forms.Label
    $warning.Location = New-Object Drawing.Point(49, 9)
    $warning.Size = New-Object Drawing.Size(600, 38)
    $warning.TextAlign = 'MiddleLeft'
    $warning.ForeColor = $orange
    $warning.Text = 'Đóng game và mọi ứng dụng dùng GPU trước khi chuyển. Màn hình có thể chớp trong vài giây.'
    $warningPanel.Controls.Add($warning)

    $actionTitle = New-Object System.Windows.Forms.Label
    $actionTitle.Location = New-Object Drawing.Point(24, 527)
    $actionTitle.Size = New-Object Drawing.Size(250, 20)
    $actionTitle.Font = New-Object Drawing.Font('Segoe UI Semibold', 9, [Drawing.FontStyle]::Bold)
    $actionTitle.ForeColor = $muted
    $actionTitle.Text = 'THAO TÁC TIẾP THEO'
    $form.Controls.Add($actionTitle)

    $toggle = New-Object System.Windows.Forms.Button
    $toggle.Location = New-Object Drawing.Point(24, 552)
    $toggle.Size = New-Object Drawing.Size(672, 64)
    $toggle.FlatStyle = 'Flat'
    $toggle.FlatAppearance.BorderSize = 0
    $toggle.Font = New-Object Drawing.Font('Segoe UI Semibold', 13, [Drawing.FontStyle]::Bold)
    $toggle.ForeColor = [Drawing.Color]::White
    $toggle.Cursor = [System.Windows.Forms.Cursors]::Hand
    $form.Controls.Add($toggle)

    $progressTitle = New-Object System.Windows.Forms.Label
    $progressTitle.Location = New-Object Drawing.Point(27, 627)
    $progressTitle.Size = New-Object Drawing.Size(105, 22)
    $progressTitle.Font = New-Object Drawing.Font('Segoe UI Semibold', 9, [Drawing.FontStyle]::Bold)
    $progressTitle.ForeColor = $muted
    $progressTitle.Text = 'TIẾN TRÌNH'
    $form.Controls.Add($progressTitle)

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object Drawing.Point(139, 626)
    $progress.Size = New-Object Drawing.Size(493, 23)
    $progress.Minimum = 0
    $progress.Maximum = 100
    $progress.Value = 0
    $progress.Style = 'Continuous'
    $form.Controls.Add($progress)

    $progressPercent = New-Object System.Windows.Forms.Label
    $progressPercent.Location = New-Object Drawing.Point(640, 625)
    $progressPercent.Size = New-Object Drawing.Size(56, 24)
    $progressPercent.TextAlign = 'MiddleRight'
    $progressPercent.Font = New-Object Drawing.Font('Segoe UI Semibold', 10, [Drawing.FontStyle]::Bold)
    $progressPercent.ForeColor = $navy
    $progressPercent.Text = '0%'
    $form.Controls.Add($progressPercent)

    $confirm = New-Object System.Windows.Forms.CheckBox
    $confirm.Location = New-Object Drawing.Point(27, 658)
    $confirm.Size = New-Object Drawing.Size(360, 25)
    $confirm.Text = 'Tôi đã đóng game và các ứng dụng đang dùng GPU'
    $confirm.ForeColor = $muted
    $form.Controls.Add($confirm)

    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object Drawing.Point(27, 691)
    $status.Size = New-Object Drawing.Size(380, 28)
    $status.Font = New-Object Drawing.Font('Segoe UI Semibold', 9)
    $status.ForeColor = $muted
    $status.Text = '● Sẵn sàng'
    $form.Controls.Add($status)

    $refreshButton = New-Object System.Windows.Forms.Button
    $refreshButton.Location = New-Object Drawing.Point(424, 686)
    $refreshButton.Size = New-Object Drawing.Size(82, 32)
    $refreshButton.Text = 'Làm mới'
    $form.Controls.Add($refreshButton)

    $settingsButton = New-Object System.Windows.Forms.Button
    $settingsButton.Location = New-Object Drawing.Point(514, 686)
    $settingsButton.Size = New-Object Drawing.Size(182, 32)
    $settingsButton.Text = 'Thiết lập driver...'
    $form.Controls.Add($settingsButton)

    # ================= TABS =================
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object Drawing.Point(0, 88)      # right below the header
$tabs.Size     = New-Object Drawing.Size(720, 680)
$tabs.SizeMode = 'Fixed'
$tabs.ItemSize = New-Object Drawing.Size(160, 30)
$tabs.Font     = New-Object Drawing.Font('Segoe UI Semibold', 9.5)

# Tab 1: existing driver-switch UI
$tabDriver = New-Object System.Windows.Forms.TabPage
$tabDriver.Text = 'Chuyển driver'
$tabDriver.UseVisualStyleBackColor = $false
$tabDriver.BackColor = $background

# Wrapper panel shifted up by the header height so existing coordinates still work
$pageDriver = New-Object System.Windows.Forms.Panel
$pageDriver.Location = New-Object Drawing.Point(0, -88)
$pageDriver.Size     = New-Object Drawing.Size(720, 728)
$pageDriver.BackColor = $background
$tabDriver.Controls.Add($pageDriver)

# Move every existing control (except the header) into the wrapper
foreach ($c in @($form.Controls)) {
    if ($c -ne $header) { $pageDriver.Controls.Add($c) }
}

# ================= Tab 2: CMP 40HX Unlock Manager =================
$tabNew = New-Object System.Windows.Forms.TabPage
$tabNew.Text = 'Quản lý Unlocker'
$tabNew.UseVisualStyleBackColor = $false
$tabNew.BackColor = $background

$unlockerDir  = Join-Path $script:AppDirectory 'cmpunlocker'



# ---------- helpers ----------
function Add-UnlockLog {
    param([string]$Text)
    $logBox.AppendText(("{0}{1}" -f $Text, [Environment]::NewLine))
}

$installerExe = Join-Path $unlockerDir '40HXInstaller.exe'

function Invoke-Installer {
    # $Arguments: mode switch first (e.g. '-rebar'); empty = full installation
    param([string[]]$Arguments = @(), [string]$ExePath = $installerExe)
    if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
        Add-UnlockLog "[!] Không tìm thấy: $ExePath"
        return
    }
    $log   = Join-Path $env:TEMP ('40HX_ui_{0}.log' -f [guid]::NewGuid().ToString('N'))
    $state = @{ Offset = 0L }
    $all   = @($Arguments) + @('-log', ('"{0}"' -f $log))

    $pump = {
        param([bool]$Final)
        if (-not (Test-Path -LiteralPath $log)) { return }
        $fs = $null
        try {
            $fs = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
            $len = $fs.Length
            if ($len -le $state.Offset) { return }
            [void]$fs.Seek($state.Offset, 'Begin')
            $buf = New-Object byte[] ($len - $state.Offset)
            $n = $fs.Read($buf, 0, $buf.Length)
            if ($n -le 0) { return }
            # only consume whole lines so multi-byte UTF-8 characters are never split
            $take = $n
            if (-not $Final) {
                $nl = [Array]::LastIndexOf($buf, [byte]10, $n - 1)
                if ($nl -lt 0) { return }
                $take = $nl + 1
            }
            $state.Offset += $take
            $text = [Text.Encoding]::UTF8.GetString($buf, 0, $take)
            foreach ($l in ($text -split '\r?\n')) { if ($l.Trim()) { Add-UnlockLog $l } }
        }
        catch { }
        finally { if ($fs) { $fs.Dispose() } }
    }

    try {
        Write-AppLog "Installer: $($all -join ' ')"
        $p = Start-Process -FilePath $ExePath -ArgumentList $all `
             -WorkingDirectory $unlockerDir -WindowStyle Hidden -PassThru
        while (-not $p.HasExited) {
            & $pump $false
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 150
        }
        & $pump $true
    }
    catch { Add-UnlockLog "[!] Error: $($_.Exception.Message)" }
    finally { Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue }
}

$checkerExe = Join-Path $unlockerDir '40HXCheck.exe'
$uninstallerExe = Join-Path $unlockerDir '40HXUninstaller.exe'

# StrictMode-safe property read: the JSON omits fields that are zero/unknown
function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $Default
}

function Invoke-Checker {
    if (-not (Test-Path -LiteralPath $checkerExe -PathType Leaf)) {
        Add-UnlockLog "[!] Không tìm thấy: $checkerExe"
        return $null
    }
    $out = Join-Path $env:TEMP ('40HX_chk_{0}.json' -f [guid]::NewGuid().ToString('N'))
    $err = "$out.err"
    try {
        $p = Start-Process -FilePath $checkerExe -ArgumentList '-json' `
             -WorkingDirectory $unlockerDir -WindowStyle Hidden -PassThru `
             -RedirectStandardOutput $out -RedirectStandardError $err
        while (-not $p.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }
        $raw = ''
        if (Test-Path -LiteralPath $out) { $raw = Get-Content -LiteralPath $out -Raw -Encoding UTF8 }
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $e = ''
            if (Test-Path -LiteralPath $err) { $e = (Get-Content -LiteralPath $err -Raw -Encoding UTF8) }
            Add-UnlockLog "[!] 40HXCheck không trả về dữ liệu (mã thoát $($p.ExitCode)). $e"
            return $null
        }
        $report = $raw | ConvertFrom-Json
        $report | Add-Member -NotePropertyName ExitCode -NotePropertyValue $p.ExitCode -Force
        return $report
    }
    catch {
        Add-UnlockLog "[!]  Kiểm tra thất bại: $($_.Exception.Message)"
        return $null
    }
    finally { Remove-Item -LiteralPath $out, $err -ErrorAction SilentlyContinue }
}

function Show-CheckReport {
    param($r)
    $fw = $r.firmware; $gpu = $r.gpu; $cmp = $r.compute; $pci = $r.pcie; $rb = $r.rebar

    $bdf = Get-Prop $gpu 'bdf' '-'
    Add-UnlockLog ("[GPU]      Có CMP 40HX: {0} | GSP: {1} | BDF: {2}" -f $gpu.cmp40hx_present, $gpu.gsp, $bdf)
    Add-UnlockLog ("[Boot]     {0} | Secure Boot: {1} | Test signing: {2} | Khởi động nhanh: {3}" -f $fw.boot_mode, $fw.secure_boot, $fw.test_signing, $fw.fast_startup)
    Add-UnlockLog ("[EFI]      EFI mở khoá: {0}" -f $fw.unlock_efi_state)

    if ($cmp.measured) {
        $ss0 = '0x{0:X8}' -f [uint32](Get-Prop $cmp 'ss0' 0)
        $ss1 = '0x{0:X8}' -f [uint32](Get-Prop $cmp 'ss1' 0)
        Add-UnlockLog ("[Tính toán] đã mở khoá: {0} (SS0={1}, SS1={2})" -f $cmp.unlocked, $ss0, $ss1)
    } else {
        Add-UnlockLog '[Tính toán] chưa đo được (driver chưa chạy)'
    }

    if ($pci.measured) {
        Add-UnlockLog ("[PCIe]     Gen{0} x{1} | mục tiêu Gen{2} | ASPM: {3}" -f (Get-Prop $pci 'link_speed_gen' 0), (Get-Prop $pci 'link_width' 0), (Get-Prop $pci 'target_speed_gen' 0), $pci.aspm)
    } else {
        Add-UnlockLog ("[PCIe]     chưa đo được | ASPM: {0}" -f $pci.aspm)
    }

    if ($rb.measured) {
        Add-UnlockLog ("[ReBAR]    đã bật: {0} | BAR1: {1} MiB" -f $rb.enabled, (Get-Prop $rb 'bar1_mib' 0))
    } else {
        Add-UnlockLog '[ReBAR]    chưa đo được'
    }

    $text = @{
        unlock_ok                       = 'Mở khoá OK - đã mở khoá tính toán và đạt PCIe Gen2.'
        compute_only                    = 'Đã mở khoá tính toán, nhưng PCIe vẫn dưới Gen2.'
        not_unlocked                    = 'Chưa mở khoá.'
        driver_not_loaded               = 'Driver chưa nạp - không đo được gì.'
        legacy_boot_no_efi              = 'Khởi động Legacy: EFI mở khoá không thể chạy. Hãy chuyển sang UEFI.'
        secure_boot_blocks_unsigned_efi = 'Secure Boot đang chặn EFI mở khoá chưa ký. Hãy tắt trong BIOS.'
        inconclusive                    = 'Kết quả chưa rõ ràng.'
    }
    $status = [string]$r.verdict.status
    $msg = if ($text.ContainsKey($status)) { $text[$status] } else { $status }
    Add-UnlockLog ("[Kết luận] {0} (mã thoát {1})" -f $msg, $r.ExitCode)
    Add-UnlockLog '[i] Báo cáo đầy đủ: chạy 40HXCheck.exe không kèm -json (ghi vào %LOCALAPPDATA%\40HXUnlock\logs\diagnose.txt).'

    $lblState.Text = $msg
}

function Set-ComponentPreselect {
    param($r)
    $todo = @()

    $chkGsp.Checked = ($r.gpu.gsp -ne 'enabled')
    if ($chkGsp.Checked) { $todo += 'GSP' }

    $chkEfi.Checked = ($r.firmware.unlock_efi_state -eq 'not_deployed')
    if ($chkEfi.Checked) { $todo += 'EFI' }

    if ($r.rebar.measured) {
        $chkRebar.Checked = (-not $r.rebar.enabled)
        if ($chkRebar.Checked) { $todo += 'ReBAR' }
    }

    $chkFastStart.Checked = [bool]$r.firmware.fast_startup
    if ($chkFastStart.Checked) { $todo += 'Khởi động nhanh' }

    $chkAspm.Checked = ($r.pcie.aspm -eq 'on')
    if ($chkAspm.Checked) { $todo += 'ASPM' }

    $chkAutostart.Checked = -not (Test-Gen2TaskExists)
    if ($chkAutostart.Checked) { $todo += 'Tự khởi động đăng nhập' }

    $chkDrivers.Checked = -not (Test-Gen2DriverBackup)
    if ($chkDrivers.Checked) { $todo += 'Driver Gen2' }

    try {
        $plan = (& powercfg /getactivescheme) -join ' '
        $chkHighPerf.Checked = ($plan -notmatch '8c5e7fda')
        if ($chkHighPerf.Checked) { $todo += 'Chế độ hiệu năng cao' }
    } catch { }

    if ($todo.Count -gt 0) { Add-UnlockLog ('[i] Đã tự chọn: ' + ($todo -join ' / ')) }
    else { Add-UnlockLog '[i] Mọi mục đo được đều đã sẵn sàng; không có gì cần chọn sẵn.' }
}

function Test-UnlockerInstalled {
    if (Test-Path -LiteralPath $cfgKey) { return $true }
    if (Test-Gen2DriverBackup) { return $true }
    if (Test-Gen2TaskExists) { return $true }
    return $false
}

function Invoke-PowerStep {
    param([string]$Name, [scriptblock]$Action)
    try { & $Action; Add-UnlockLog "  [Power] $Name - OK" }
    catch { Add-UnlockLog "  [!] $Name failed: $($_.Exception.Message)" }
}

$cfgKey = 'HKLM:\SOFTWARE\40HXUnlock'

function Get-CfgInt {
    param([string]$Name, [int]$Default)
    try { return [int](Get-ItemProperty -Path $cfgKey -Name $Name -ErrorAction Stop).$Name }
    catch { return $Default }
}

function Import-UnlockPolicy {
    switch (Get-CfgInt 'DriverStrategy' 0) {
        1       { $rbRetry.Checked    = $true }
        2       { $rbWatchdog.Checked = $true }
        default { $rbUnload.Checked   = $true }
    }
    $chkStage2.Checked = ((Get-CfgInt 'Gen2AutoHard' 0) -ne 0)
    $numRetry.Value    = [Math]::Min(12,  [Math]::Max(0, (Get-CfgInt 'Gen2RetryCount' 3)))
    $numInterval.Value = [Math]::Min(240, [Math]::Max(1, (Get-CfgInt 'Gen2RetryIntervalMin' 1)))
}

function Test-Gen2TaskExists {
    # The task file on disk is the authoritative test (schtasks queries can misreport)
    Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\Tasks\40HX PCIe Gen2 Bring-up')
}

function Test-Gen2DriverBackup {
    $dir = Join-Path $env:ProgramData '40HXUnlock\drivers'
    foreach ($f in 'ThrottleStop.sys', 'WinRing0x64.sys') {
        $item = Get-Item -LiteralPath (Join-Path $dir $f) -ErrorAction SilentlyContinue
        if ($item -and $item.Length -gt 0) { return $true }
    }
    return $false
}

function Save-UnlockPolicy {
    try {
        if (-not (Test-Path -LiteralPath $cfgKey)) { New-Item -Path $cfgKey -Force | Out-Null }
        $strat = if ($rbWatchdog.Checked) { 2 } elseif ($rbRetry.Checked) { 1 } else { 0 }
        $auto  = if ($chkStage2.Checked) { 1 } else { 0 }
        $cnt   = [int]$numRetry.Value
        $min   = [int]$numInterval.Value
        Set-ItemProperty -Path $cfgKey -Name DriverStrategy        -Value $strat -Type DWord
        Set-ItemProperty -Path $cfgKey -Name Gen2AutoHard          -Value $auto  -Type DWord
        Set-ItemProperty -Path $cfgKey -Name Gen2RetryCount        -Value $cnt   -Type DWord
        Set-ItemProperty -Path $cfgKey -Name Gen2RetryIntervalMin  -Value $min   -Type DWord
        Add-UnlockLog "[Chính sách] Đã lưu: chế độ=$strat, Stage2=$auto, số lần thử=$cnt, khoảng cách=$min phút"
        if ($strat -eq 2 -and -not (Test-Gen2TaskExists)) {
            Add-UnlockLog '[Lưu ý] Giám sát thường trực cần tác vụ tự khởi động khi đăng nhập: dùng "Chạy Gen2 và cài tự khởi động".'
        }
        return $true
    }
    catch {
        Add-UnlockLog "[Chính sách] Lưu thất bại: $($_.Exception.Message)"
        return $false
    }
}

# ---------- 1. Components and environment ----------
$grp1 = New-Object System.Windows.Forms.GroupBox
$grp1.Text = '1. Thành phần và môi trường (mục còn thiếu đã được chọn sẵn)'
$grp1.Location = New-Object Drawing.Point(12, 6)
$grp1.Size = New-Object Drawing.Size(696, 232)
$tabNew.Controls.Add($grp1)

$lblState = New-Object System.Windows.Forms.Label
$lblState.Location = New-Object Drawing.Point(12, 22)
$lblState.Size = New-Object Drawing.Size(670, 20)
$lblState.Text = 'Chạy 40HXCheck để phát hiện mục còn thiếu.'
$grp1.Controls.Add($lblState)

function New-Check($text, $x, $y, $checked, $w = 300) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $text
    $c.Location = New-Object Drawing.Point($x, $y)
    $c.Size = New-Object Drawing.Size($w, 24)
    $c.Checked = $checked
    $grp1.Controls.Add($c)
    return $c
}

$chkGsp       = New-Check 'Bật GSP (EnableGpuFirmware=1)'     50  44  $true  300
$chkRebar     = New-Check 'Mở khóa Rebar (8 GB BAR1)'              50  70  $true  300
$chkAutostart = New-Check 'Tự khởi động Gen2 khi đăng nhập'                 50  96  $true  300
$chkAspm      = New-Check 'Power: tắt PCIe link power saving' 50  122 $false 300
$chkDefender  = New-Check 'Tắt bảo vệ thời gian thực của WinDefender' 50 148 $true  300
$chkEfi       = New-Check 'Tạo EFI + mục khởi độngfirmware'    380  44  $true  300
$chkDrivers   = New-Check 'Triển khai driver Gen2 + loại trừ Defender' 380 70 $true 300
$chkFastStart = New-Check 'Power: tắt Fast Startup'          380  96  $false 300
$chkHighPerf  = New-Check 'Power: bật High-performance plan'         380 122 $true  300

$btnInstallSel = New-Object System.Windows.Forms.Button
$btnInstallSel.Text = 'Cài đăt các mục đã chọn'
$btnInstallSel.Location = New-Object Drawing.Point(12, 194)
$btnInstallSel.Size = New-Object Drawing.Size(330, 28)
$btnInstallSel.Add_Click({
    $anySelected = $chkGsp.Checked -or $chkRebar.Checked -or $chkAutostart.Checked -or
                   $chkFastStart.Checked -or $chkAspm.Checked -or $chkHighPerf.Checked -or
                   $chkDefender.Checked -or $chkDrivers.Checked -or $chkEfi.Checked
    if (-not $anySelected) {
        Add-UnlockLog '[i] Chưa chọn mục nào - hãy tích chọn trước.'
        return
    }

    if ($chkDrivers.Checked -or $chkEfi.Checked) {
        $a = [System.Windows.Forms.MessageBox]::Show(
            "Driver Gen2 và mục khởi động EFI chỉ có thể cài qua Cài đặt đầy đủ (trình cài không có tuỳ chọn riêng cho hai mục này).`r`n`r`nCó = chạy Cài đặt đầy đủ ngay (gồm tất cả)`r`nKhông = chỉ tiếp tục với các mục đã chọn khác",
            'CMP 40HX', 'YesNoCancel', 'Question')
        if ($a -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
        if ($a -eq [System.Windows.Forms.DialogResult]::Yes) { $btnFull.PerformClick(); return }
    }

    & $setBusy $true
    try {
        Add-UnlockLog '== Đang cài đặt mục đã chọn =='
        if ($chkGsp.Checked)       { Add-UnlockLog '--- Bật GSP ---';            Invoke-Installer @('-gspensure','-y') }
        if ($chkRebar.Checked)     { Add-UnlockLog '--- Mở khoá ReBar ---';       Invoke-Installer @('-rebar','-y') }
        if ($chkAutostart.Checked) { Add-UnlockLog '--- Tự khởi động Gen2 ---';   Invoke-Installer @('-task','-y') }

        if ($chkFastStart.Checked) {
            Invoke-PowerStep 'Tắt Khởi động nhanh' {
                Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
                    -Name HiberbootEnabled -Value 0 -Type DWord
            }
        }
        if ($chkAspm.Checked) {
            Invoke-PowerStep 'Tắt tiết kiệm điện liên kết PCIe' {
                & powercfg /setacvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0 | Out-Null
                & powercfg /setdcvalueindex SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0 | Out-Null
                & powercfg /setactive SCHEME_CURRENT | Out-Null
            }
        }
        if ($chkHighPerf.Checked) {
            Invoke-PowerStep 'Chế độ hiệu năng cao' {
                & powercfg /setactive SCHEME_MIN
                if ($LASTEXITCODE -ne 0) { throw 'powercfg báo lỗi (có thể máy đang ẩn chế độ này)' }
            }
        }
        if ($chkDefender.Checked) {
            Invoke-PowerStep 'Tắt bảo vệ thời gian thực của Defender' {
                Set-MpPreference -DisableRealtimeMonitoring $true
            }
            Add-UnlockLog '  [i] Nếu lỗi, hãy tắt Tamper Protection trong Windows Security trước.'
            Add-UnlockLog '  [i] Khôi phục bằng: Set-MpPreference -DisableRealtimeMonitoring $false'
        }
        Add-UnlockLog '== Hoàn tất =='
    }
    finally { & $setBusy $false }
})
$grp1.Controls.Add($btnInstallSel)

$btnFull = New-Object System.Windows.Forms.Button
$btnFull.Text = 'Cài đặt toàn bộ'
$btnFull.Location = New-Object Drawing.Point(352, 194)
$btnFull.Size = New-Object Drawing.Size(330, 28)
$btnFull.Add_Click({
    & $setBusy $true
    try {
        Add-UnlockLog '== Cài đặt đầy đủ =='
        Invoke-Installer
        Add-UnlockLog '== Hoàn tất. Khởi động lại để thay đổi GSP / EFI có hiệu lực. =='
    }
    finally { & $setBusy $false }
})
$grp1.Controls.Add($btnFull)

# ---------- 2. Gen2 policy ----------
$grp2 = New-Object System.Windows.Forms.GroupBox
$grp2.Text = '2. Policy Gen2 (thay đổi áp dụng ngay)'
$grp2.Location = New-Object Drawing.Point(12, 244)
$grp2.Size = New-Object Drawing.Size(696, 196)
$tabNew.Controls.Add($grp2)

$lblPolicy = New-Object System.Windows.Forms.Label
$lblPolicy.Location = New-Object Drawing.Point(12, 22)
$lblPolicy.Size = New-Object Drawing.Size(670, 36)
$lblPolicy.Text = "Driver policy: cách xử lý hai driver Gen2 sau khi mở khóa`r`n1. Gỡ sau khi sử dụng (mặc định)   2. Thử lại khi lỗi   3. Giám sát liên tục"
$grp2.Controls.Add($lblPolicy)

$rbUnload = New-Object System.Windows.Forms.RadioButton
$rbUnload.Text = 'Gỡ sau khi sử dụng (mặc định)'
$rbUnload.Location = New-Object Drawing.Point(110, 58)
$rbUnload.Size = New-Object Drawing.Size(220, 22)
$rbUnload.Checked = $true
$grp2.Controls.Add($rbUnload)

$rbRetry = New-Object System.Windows.Forms.RadioButton
$rbRetry.Text = 'Thử lại khi lỗi'
$rbRetry.Location = New-Object Drawing.Point(340, 58)
$rbRetry.Size = New-Object Drawing.Size(140, 22)
$grp2.Controls.Add($rbRetry)

$rbWatchdog = New-Object System.Windows.Forms.RadioButton
$rbWatchdog.Text = 'Giám sát liên tục'
$rbWatchdog.Location = New-Object Drawing.Point(490, 58)
$rbWatchdog.Size = New-Object Drawing.Size(180, 22)
$grp2.Controls.Add($rbWatchdog)

$chkStage2 = New-Object System.Windows.Forms.CheckBox
$chkStage2.Text = 'Tự động sử dụng phương án Stage2 khi không đạt Gen2 (Link Disable + PnP recovery)'
$chkStage2.Location = New-Object Drawing.Point(60, 94)
$chkStage2.Size = New-Object Drawing.Size(600, 24)
$chkStage2.Checked = $false
$grp2.Controls.Add($chkStage2)

$lblRetry = New-Object System.Windows.Forms.Label
$lblRetry.Text = 'Số lần thử lại:'
$lblRetry.Location = New-Object Drawing.Point(14, 130)
$lblRetry.Size = New-Object Drawing.Size(80, 22)
$grp2.Controls.Add($lblRetry)

$numRetry = New-Object System.Windows.Forms.NumericUpDown
$numRetry.Location = New-Object Drawing.Point(100, 127)
$numRetry.Size = New-Object Drawing.Size(150, 24)
$numRetry.Minimum = 0; $numRetry.Maximum = 12; $numRetry.Value = 3
$grp2.Controls.Add($numRetry)

$lblInterval = New-Object System.Windows.Forms.Label
$lblInterval.Text = '/ khoảng cách:'
$lblInterval.Location = New-Object Drawing.Point(270, 130)
$lblInterval.Size = New-Object Drawing.Size(70, 22)
$grp2.Controls.Add($lblInterval)

$numInterval = New-Object System.Windows.Forms.NumericUpDown
$numInterval.Location = New-Object Drawing.Point(345, 127)
$numInterval.Size = New-Object Drawing.Size(150, 24)
$numInterval.Minimum = 1; $numInterval.Maximum = 240; $numInterval.Value = 1
$grp2.Controls.Add($numInterval)

$lblMin = New-Object System.Windows.Forms.Label
$lblMin.Text = 'phút'
$lblMin.Location = New-Object Drawing.Point(505, 130)
$lblMin.Size = New-Object Drawing.Size(70, 22)
$grp2.Controls.Add($lblMin)

$btnSavePolicy = New-Object System.Windows.Forms.Button
$btnSavePolicy.Text = 'Lưu policy'
$btnSavePolicy.Location = New-Object Drawing.Point(12, 160)
$btnSavePolicy.Size = New-Object Drawing.Size(150, 28)
$grp2.Controls.Add($btnSavePolicy)

$btnRunNow = New-Object System.Windows.Forms.Button
$btnRunNow.Text = 'Chạy Gen2 ngay bây giờ (chỉ lần này)'
$btnRunNow.Location = New-Object Drawing.Point(172, 160)
$btnRunNow.Size = New-Object Drawing.Size(250, 28)
$grp2.Controls.Add($btnRunNow)

$btnRunInstall = New-Object System.Windows.Forms.Button
$btnRunInstall.Text = 'Chạy Gen2 và cài tự khởi động'
$btnRunInstall.Location = New-Object Drawing.Point(432, 160)
$btnRunInstall.Size = New-Object Drawing.Size(250, 28)
$grp2.Controls.Add($btnRunInstall)

# ---------- Extra tools row ----------
$btnCheck = New-Object System.Windows.Forms.Button
$btnCheck.Text = 'Chạy 40HXCheck.exe'
$btnCheck.Location = New-Object Drawing.Point(12, 446)
$btnCheck.Size = New-Object Drawing.Size(340, 32)
$btnCheck.BackColor = $blue
$btnCheck.ForeColor = [Drawing.Color]::White
$btnCheck.FlatStyle = 'Flat'
$btnCheck.FlatAppearance.BorderSize = 0
$btnCheck.Add_Click({
    & $setBusy $true
    try {
        Add-UnlockLog '== 40HXCheck =='
        $lblState.Text = 'Đang kiểm tra...'
        $r = Invoke-Checker
        if ($r) {
            Show-CheckReport $r
            Set-ComponentPreselect $r
        } else {
            $lblState.Text = 'Kiểm tra thất bại - xem nhật ký.'
        }
    }
    finally { & $setBusy $false }
})
$tabNew.Controls.Add($btnCheck)

$btnUninstall = New-Object System.Windows.Forms.Button
$btnUninstall.Text = 'Chạy 40HXUninstaller.exe'
$btnUninstall.Location = New-Object Drawing.Point(368, 446)
$btnUninstall.Size = New-Object Drawing.Size(340, 32)
$btnUninstall.BackColor = [Drawing.Color]::FromArgb(185, 28, 28)
$btnUninstall.ForeColor = [Drawing.Color]::White
$btnUninstall.FlatStyle = 'Flat'
$btnUninstall.FlatAppearance.BorderSize = 0
$btnUninstall.Add_Click({
    $a = [System.Windows.Forms.MessageBox]::Show(
        "Thao tác này sẽ gỡ bỏ hoàn toàn bản mở khoá:`r`n" +
        " - tác vụ đã lên lịch và tự khởi động Gen2`r`n" +
        " - mục khởi động firmware và EFI trên ESP`r`n" +
        " - driver Gen2 và loại trừ Defender`r`n" +
        " - thiết lập GSP (EnableGpuFirmware)`r`n`r`n" +
        "Cài đặt nguồn điện sẽ không được khôi phục. Tiếp tục?",
        'CMP 40HX - Gỡ cài đặt', 'YesNo', 'Warning')
    if ($a -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    & $setBusy $true
    try {
        Add-UnlockLog '== Gỡ cài đặt =='
        Invoke-Installer -ExePath $uninstallerExe
        Add-UnlockLog '== Gỡ cài đặt xong. Nên khởi động lại máy. =='

        try {
            if (-not (Get-MpComputerStatus).RealTimeProtectionEnabled) {
                $d = [System.Windows.Forms.MessageBox]::Show(
                    'Bảo vệ thời gian thực của Defender đang TẮT. Bật lại không?',
                    'CMP 40HX', 'YesNo', 'Question')
                if ($d -eq [System.Windows.Forms.DialogResult]::Yes) {
                    Set-MpPreference -DisableRealtimeMonitoring $false
                    Add-UnlockLog '[i] Đã bật lại bảo vệ thời gian thực của Defender.'
                }
            }
        }
        catch { Add-UnlockLog "[i] Không thể kiểm tra/khôi phục Defender: $($_.Exception.Message)" }

        Add-UnlockLog '[i] Bấm "Chạy 40HXCheck.exe" để xác nhận trạng thái sau khi khởi động lại.'
    }
    finally { & $setBusy $false }
})
$tabNew.Controls.Add($btnUninstall)

# ---------- 3. Operation log ----------
$grp3 = New-Object System.Windows.Forms.GroupBox
$grp3.Text = '3. Log hoạt động (trực tiếp)'
$grp3.Location = New-Object Drawing.Point(12, 484)
$grp3.Size = New-Object Drawing.Size(696, 146)
$tabNew.Controls.Add($grp3)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.Location = New-Object Drawing.Point(10, 20)
$logBox.Size = New-Object Drawing.Size(676, 118)
$logBox.BackColor = [Drawing.Color]::White
$grp3.Controls.Add($logBox)
Add-UnlockLog 'Quản lý Unlocker đã khởi động (quyền administrator).'

# ---------- load saved policy ----------
Import-UnlockPolicy

# ---------- button actions ----------
$setBusy = { param($busy) foreach ($b in @($btnInstallSel,$btnFull,$btnSavePolicy,$btnRunNow,$btnRunInstall,$btnCheck,$btnUninstall)) { $b.Enabled = -not $busy } }

$btnSavePolicy.Add_Click({ [void](Save-UnlockPolicy) })

$btnRunNow.Add_Click({
    & $setBusy $true
    try {
        Add-UnlockLog '== Chạy Gen2 ngay (chỉ phiên này) =='
        Invoke-Installer @('-gen2')
    }
    finally { & $setBusy $false }
})

$btnRunInstall.Add_Click({
    & $setBusy $true
    try {
        [void](Save-UnlockPolicy)
        Add-UnlockLog '== Chạy Gen2 và cài tự khởi động =='
        Add-UnlockLog '[Gen2] Bước 1/2: mở khoá phiên này...'
        Invoke-Installer @('-gen2')
        Add-UnlockLog '[Gen2] Bước 2/2: đăng ký tự khởi động khi đăng nhập...'
        if (Test-Gen2DriverBackup) {
            Invoke-Installer @('-task', '-y')
        } else {
            Add-UnlockLog '[!] Chưa có bản sao lưu driver Gen2 nên tác vụ đăng nhập sẽ không có gì để nạp.'
            Add-UnlockLog '[!] Hãy chạy "Cài đặt đầy đủ" trước (sẽ triển khai driver), rồi bấm nút này lại.'
        }
    }
    finally { & $setBusy $false }
})

# ================= END Tab 2 =================

# ================= Tab: GPU mặc định =================
$tabDefault = New-Object System.Windows.Forms.TabPage
$tabDefault.Text = 'GPU mặc định'
$tabDefault.UseVisualStyleBackColor = $false
$tabDefault.BackColor = $background

# ---------- helpers (dựa theo select_default_GPU của nethe-GitHub, viết lại bằng PowerShell) ----------

$glCompatPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\OpenGLDrivers\MSOGL'
$dxPath       = 'HKCU:\Software\Microsoft\DirectX'

function Get-RegProp {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-GpuAdapters {
    $classPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    $enumPci   = 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI'
    $adapters = @()
    if (-not (Test-Path -LiteralPath $classPath)) { return $adapters }

    $driverMap = @{}
    Get-ChildItem -LiteralPath $enumPci -ErrorAction SilentlyContinue | ForEach-Object {
        $pciKey = $_.PSChildName
        Get-ChildItem -LiteralPath $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            $drv = Get-RegProp $p 'Driver'
            if ($drv) { $driverMap[$drv] = ($pciKey -replace '&REV_[0-9A-Fa-f]+$', '') }
        }
    }

    Get-ChildItem -LiteralPath $classPath -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\d{4}$' } |
        ForEach-Object {
            $sub = $_.PSChildName
            $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            $matchId = Get-RegProp $p 'MatchingDeviceId'
            $desc    = Get-RegProp $p 'DriverDesc'
            if (-not $matchId -or -not $desc) { return }

            $driverVal = $driverMap.Keys | Where-Object { $_ -like "*\$sub" } | Select-Object -First 1
            if (-not $driverVal -or -not $driverMap[$driverVal]) { return }

            $glPath   = Get-RegProp $p 'OpenGLDriverName'
            if (-not $glPath) { $glPath = Get-RegProp $p '_OpenGLDriverName' }
            $glPath32 = Get-RegProp $p 'OpenGLDriverNameWow'
            if (-not $glPath32) { $glPath32 = Get-RegProp $p '_OpenGLDriverNameWow' }

            $adapters += [pscustomobject]@{
                ClassSub    = $sub
                ClassPath   = $_.PSPath
                Description = $desc
                DeviceId    = $driverMap[$driverVal]
                GLPath      = $glPath
                GLPath32    = $glPath32
            }
        }
    return $adapters
}

# ---------- log helpers ----------
function Add-DefLog {
    param([string]$Text)
    $line = '[{0:HH:mm:ss}] {1}' -f (Get-Date), $Text
    $defLog.AppendText($line + [Environment]::NewLine)
    Write-AppLog "GPU mặc định: $Text"
    [System.Windows.Forms.Application]::DoEvents()
}

function Add-DefChange {
    param([string]$Label, $Old, $New)
    $o = if ($null -eq $Old -or "$Old" -eq '') { '(chưa có)' } else { "$Old" }
    $n = if ($null -eq $New -or "$New" -eq '') { '(đã xoá)' } else { "$New" }
    if ($o -eq $n) { Add-DefLog "  = $Label : giữ nguyên [$n]" }
    else           { Add-DefLog "  ~ $Label : $o  →  $n" }
}

function Get-MsoglValue {
    param([int]$View, [string]$Name)
    $rv = if ($View -eq 32) { [Microsoft.Win32.RegistryView]::Registry32 } else { [Microsoft.Win32.RegistryView]::Registry64 }
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $rv)
    try {
        $k = $base.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\OpenGLDrivers\MSOGL')
        if (-not $k) { return $null }
        try { return $k.GetValue($Name, $null) } finally { $k.Dispose() }
    }
    finally { $base.Dispose() }
}

function Invoke-RegExe {
    param([string[]]$Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'      # reg.exe writes errors to stderr
    try {
        $out = & reg.exe @Arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prev }
    if ($code -ne 0) { throw "reg.exe $($Arguments -join ' ') lỗi (mã $code): $($out.Trim())" }
}

function Set-MsoglValue {
    param([int]$View, [string]$Name, [string]$Type, [string]$Data)
    $old = Get-MsoglValue -View $View -Name $Name
    Invoke-RegExe @('add', $script:MsoglKey, '/f', "/reg:$View", '/v', $Name, '/t', $Type, '/d', $Data)
    $new = Get-MsoglValue -View $View -Name $Name
    Add-DefChange "MSOGL[$View-bit] $Name" $old $new
}

$script:MsoglKey = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\OpenGLDrivers\MSOGL'

# ---------- DirectX ----------
function Set-DefaultDxGpu {
    param($Adapter)
    Add-DefLog "== Đặt GPU hiệu năng cao (DirectX): $($Adapter.Description) =="

    $gs = "$dxPath\GraphicsSettings"
    if (-not (Test-Path -LiteralPath $gs)) {
        New-Item -Path $gs -Force | Out-Null
        Add-DefLog '  + Đã tạo khoá HKCU\...\DirectX\GraphicsSettings'
    }
    foreach ($name in 'DefaultHighPerfGPUApplicable', 'SpecificGPUOptionApplicable') {
        $old = Get-RegProp (Get-ItemProperty -LiteralPath $gs -Name $name -ErrorAction SilentlyContinue) $name
        Set-ItemProperty -LiteralPath $gs -Name $name -Value 1 -Type DWord
        $new = Get-RegProp (Get-ItemProperty -LiteralPath $gs -Name $name -ErrorAction SilentlyContinue) $name
        Add-DefChange "GraphicsSettings\$name" $old $new
    }

    $up = "$dxPath\UserGpuPreferences"
    if (-not (Test-Path -LiteralPath $up)) {
        New-Item -Path $up -Force | Out-Null
        Add-DefLog '  + Đã tạo khoá HKCU\...\DirectX\UserGpuPreferences'
    }
    $existing = Get-RegProp (Get-ItemProperty -LiteralPath $up -Name DirectXUserGlobalSettings -ErrorAction SilentlyContinue) 'DirectXUserGlobalSettings'
    $swap  = if ($existing -match 'SwapEffectUpgradeEnable=1') { 'SwapEffectUpgradeEnable=1;' } else { 'SwapEffectUpgradeEnable=0;' }
    $value = "HighPerfAdapter=$($Adapter.DeviceId);$swap"
    Set-ItemProperty -LiteralPath $up -Name DirectXUserGlobalSettings -Value $value -Type String
    $new = Get-RegProp (Get-ItemProperty -LiteralPath $up -Name DirectXUserGlobalSettings -ErrorAction SilentlyContinue) 'DirectXUserGlobalSettings'
    Add-DefChange 'UserGpuPreferences\DirectXUserGlobalSettings' $existing $new
    Add-DefLog '== Hoàn tất DirectX =='
}

# ---------- OpenGL ----------
function Set-DefaultGlGpu {
    param($Adapters, $Chosen)
    if (-not $Chosen.GLPath -or -not $Chosen.GLPath32) {
        throw "GPU này không có sẵn OpenGL ICD (thiếu OpenGLDriverName/Wow trong registry)."
    }
    Add-DefLog "== Đặt ICD OpenGL mặc định: $($Chosen.Description) =="
    Add-DefLog "  DLL 64-bit: $($Chosen.GLPath)"
    Add-DefLog "  DLL 32-bit: $($Chosen.GLPath32)"

    foreach ($view in 32, 64) {
        $existed = $null -ne (Get-MsoglValue -View $view -Name 'DLL') -or $null -ne (Get-MsoglValue -View $view -Name 'Version')
        Invoke-RegExe @('add', $script:MsoglKey, '/f', "/reg:$view")
        if (-not $existed) { Add-DefLog "  + Đảm bảo khoá MSOGL tồn tại ($view-bit)" }
    }

    Set-MsoglValue -View 64 -Name 'DLL' -Type 'REG_SZ' -Data $Chosen.GLPath
    Set-MsoglValue -View 32 -Name 'DLL' -Type 'REG_SZ' -Data $Chosen.GLPath32
    foreach ($view in 32, 64) {
        Set-MsoglValue -View $view -Name 'DriverVersion' -Type 'REG_DWORD' -Data '1'
        Set-MsoglValue -View $view -Name 'Version'       -Type 'REG_DWORD' -Data '2'
        Set-MsoglValue -View $view -Name 'Flags'         -Type 'REG_DWORD' -Data '3'
    }

    Add-DefLog '  -- Chuyển các adapter sang khoá _OpenGLDriverName --'
    foreach ($a in $Adapters) {
        if (-not $a.GLPath) { Add-DefLog "  - Bỏ qua $($a.Description) (không có OpenGL ICD)"; continue }
        Add-DefLog "  [$($a.ClassSub)] $($a.Description)"
        $cur = Get-ItemProperty -LiteralPath $a.ClassPath -ErrorAction SilentlyContinue

        $o = Get-RegProp $cur '_OpenGLDriverName'
        Set-ItemProperty -LiteralPath $a.ClassPath -Name '_OpenGLDriverName' -Value $a.GLPath -Type String -Force
        Add-DefChange '    _OpenGLDriverName' $o $a.GLPath

        if ($a.GLPath32) {
            $o = Get-RegProp $cur '_OpenGLDriverNameWow'
            Set-ItemProperty -LiteralPath $a.ClassPath -Name '_OpenGLDriverNameWow' -Value $a.GLPath32 -Type String -Force
            Add-DefChange '    _OpenGLDriverNameWow' $o $a.GLPath32
        }
        foreach ($n in 'OpenGLDriverName', 'OpenGLDriverNameWow') {
            $o = Get-RegProp $cur $n
            if ($null -ne $o) {
                Remove-ItemProperty -LiteralPath $a.ClassPath -Name $n -ErrorAction SilentlyContinue
                Add-DefChange "    $n" $o $null
            }
        }
    }
    Add-DefLog '== Hoàn tất OpenGL. Cần khởi động lại máy để có hiệu lực. =='
}

# ---------- UI ----------

$defTitle = New-Object System.Windows.Forms.Label
$defTitle.Location = New-Object Drawing.Point(24, 14)
$defTitle.Size     = New-Object Drawing.Size(660, 26)
$defTitle.Font     = New-Object Drawing.Font('Segoe UI Semibold', 13, [Drawing.FontStyle]::Bold)
$defTitle.ForeColor = $navy
$defTitle.Text     = 'Chọn GPU mặc định'
$tabDefault.Controls.Add($defTitle)

$defInfo = New-Object System.Windows.Forms.Label
$defInfo.Location = New-Object Drawing.Point(24, 44)
$defInfo.Size     = New-Object Drawing.Size(660, 36)
$defInfo.ForeColor = $muted
$defInfo.Text     = 'Thiết lập GPU hiệu năng cao mặc định cho DirectX và ICD mặc định cho OpenGL, dựa theo select_default_GPU.'
$tabDefault.Controls.Add($defInfo)

$lstGpu = New-Object System.Windows.Forms.ListBox
$lstGpu.Location = New-Object Drawing.Point(24, 86)
$lstGpu.Size     = New-Object Drawing.Size(660, 180)
$lstGpu.Font     = New-Object Drawing.Font('Consolas', 9)
$tabDefault.Controls.Add($lstGpu)

$btnScanGpu = New-Object System.Windows.Forms.Button
$btnScanGpu.Location = New-Object Drawing.Point(24, 274)
$btnScanGpu.Size     = New-Object Drawing.Size(200, 30)
$btnScanGpu.Text     = 'Quét lại danh sách GPU'
$tabDefault.Controls.Add($btnScanGpu)

$btnOpenGraphics = New-Object System.Windows.Forms.Button
$btnOpenGraphics.Location = New-Object Drawing.Point(24, 316)
$btnOpenGraphics.Size     = New-Object Drawing.Size(660, 30)
$btnOpenGraphics.Text     = 'Mở Cài đặt đồ hoạ Windows'
$btnOpenGraphics.Add_Click({
    Add-DefLog 'Mở ms-settings:display-advancedgraphics'
    try { Start-Process 'ms-settings:display-advancedgraphics' }
    catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'CMP 40HX', 'OK', 'Error') | Out-Null }
})
$tabDefault.Controls.Add($btnOpenGraphics)

$btnSetDx = New-Object System.Windows.Forms.Button
$btnSetDx.Location = New-Object Drawing.Point(24, 358)
$btnSetDx.Size     = New-Object Drawing.Size(320, 34)
$btnSetDx.Text     = 'Đặt làm GPU hiệu năng cao (DirectX)'
$btnSetDx.BackColor = $blue
$btnSetDx.ForeColor = [Drawing.Color]::White
$btnSetDx.FlatStyle = 'Flat'
$btnSetDx.FlatAppearance.BorderSize = 0
$tabDefault.Controls.Add($btnSetDx)

$btnSetGl = New-Object System.Windows.Forms.Button
$btnSetGl.Location = New-Object Drawing.Point(364, 358)
$btnSetGl.Size     = New-Object Drawing.Size(320, 34)
$btnSetGl.Text     = 'Đặt làm ICD OpenGL mặc định (cần khởi động lại)'
$btnSetGl.BackColor = $green
$btnSetGl.ForeColor = [Drawing.Color]::White
$btnSetGl.FlatStyle = 'Flat'
$btnSetGl.FlatAppearance.BorderSize = 0
$tabDefault.Controls.Add($btnSetGl)

$defStatus = New-Object System.Windows.Forms.Label
$defStatus.Location = New-Object Drawing.Point(24, 402)
$defStatus.Size     = New-Object Drawing.Size(660, 60)
$defStatus.ForeColor = $muted
$defStatus.Text     = '● Chưa quét.'
$tabDefault.Controls.Add($defStatus)

$grpDefLog = New-Object System.Windows.Forms.GroupBox
$grpDefLog.Text     = 'Log thay đổi (trực tiếp)'
$grpDefLog.Location = New-Object Drawing.Point(24, 468)
$grpDefLog.Size     = New-Object Drawing.Size(660, 160)
$tabDefault.Controls.Add($grpDefLog)

$defLog = New-Object System.Windows.Forms.TextBox
$defLog.Multiline   = $true
$defLog.ReadOnly    = $true
$defLog.ScrollBars  = 'Both'
$defLog.WordWrap    = $false
$defLog.Font        = New-Object Drawing.Font('Consolas', 8.5)
$defLog.BackColor   = [Drawing.Color]::White
$defLog.Location    = New-Object Drawing.Point(10, 20)
$defLog.Size        = New-Object Drawing.Size(640, 130)
$grpDefLog.Controls.Add($defLog)

$btnClearDefLog = New-Object System.Windows.Forms.Button
$btnClearDefLog.Location = New-Object Drawing.Point(240, 274)
$btnClearDefLog.Size     = New-Object Drawing.Size(140, 30)
$btnClearDefLog.Text     = 'Xoá log'
$btnClearDefLog.Add_Click({ $defLog.Clear() })
$tabDefault.Controls.Add($btnClearDefLog)

Add-DefLog 'Tab GPU mặc định đã sẵn sàng.'

$script:DefaultGpuAdapters = @()

function Update-GpuList {
    $lstGpu.Items.Clear()
    $script:DefaultGpuAdapters = @(Get-GpuAdapters)
    Add-DefLog '-- Quét danh sách GPU --'
    if ($script:DefaultGpuAdapters.Count -eq 0) {
        $defStatus.Text = '● Không tìm thấy GPU nào trong registry.'
        $defStatus.ForeColor = [Drawing.Color]::Firebrick
        Add-DefLog '  [!] Không tìm thấy GPU nào trong registry.'
        return
    }
    foreach ($a in $script:DefaultGpuAdapters) {
        $glMark = if ($a.GLPath) { 'OpenGL: có' } else { 'OpenGL: không' }
        $lstGpu.Items.Add("$($a.Description)   [$($a.DeviceId)]   $glMark") | Out-Null
        Add-DefLog "  [$($a.ClassSub)] $($a.Description) | $($a.DeviceId) | $glMark"
    }
    $lstGpu.SelectedIndex = 0
    $defStatus.Text = "● Tìm thấy $($script:DefaultGpuAdapters.Count) GPU."
    $defStatus.ForeColor = $muted
}

$btnScanGpu.Add_Click({ Update-GpuList })

$btnSetDx.Add_Click({
    if ($lstGpu.SelectedIndex -lt 0) {
        [System.Windows.Forms.MessageBox]::Show('Hãy chọn một GPU trong danh sách trước.', 'CMP 40HX', 'OK', 'Warning') | Out-Null
        return
    }
    $a = $script:DefaultGpuAdapters[$lstGpu.SelectedIndex]
    try {
        Set-DefaultDxGpu -Adapter $a
        $defStatus.Text = "● Đã đặt '$($a.Description)' làm GPU hiệu năng cao cho DirectX."
        $defStatus.ForeColor = $green
    }
    catch {
        Add-DefLog "  [!] LỖI: $($_.Exception.Message)"
        $defStatus.Text = "● Lỗi: $($_.Exception.Message)"
        $defStatus.ForeColor = [Drawing.Color]::Firebrick
    }
})

$btnSetGl.Add_Click({
    if ($lstGpu.SelectedIndex -lt 0) {
        [System.Windows.Forms.MessageBox]::Show('Hãy chọn một GPU trong danh sách trước.', 'CMP 40HX', 'OK', 'Warning') | Out-Null
        return
    }
    $a = $script:DefaultGpuAdapters[$lstGpu.SelectedIndex]
    if (-not $a.GLPath) {
        [System.Windows.Forms.MessageBox]::Show("GPU '$($a.Description)' không có sẵn OpenGL ICD, không thể đặt làm mặc định.", 'CMP 40HX', 'OK', 'Warning') | Out-Null
        return
    }
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Đặt '$($a.Description)' làm ICD OpenGL mặc định?`r`nCần khởi động lại máy để có hiệu lực.",
        'CMP 40HX', 'YesNo', 'Question')
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try {
        Set-DefaultGlGpu -Adapters $script:DefaultGpuAdapters -Chosen $a
        $defStatus.Text = "● Đã đặt '$($a.Description)' làm ICD OpenGL mặc định. Hãy khởi động lại máy."
        $defStatus.ForeColor = $green
    }
    catch {
        Add-DefLog "  [!] LỖI: $($_.Exception.Message)"
        $defStatus.Text = "● Lỗi: $($_.Exception.Message)"
        $defStatus.ForeColor = [Drawing.Color]::Firebrick
    }
})

Update-GpuList
# ================= END Tab: GPU mặc định =================

# ================= Tab: NEW FEATURE - Tải & chuẩn bị driver (tab đầu tiên) =================
$tabMain = New-Object System.Windows.Forms.TabPage
$tabMain.Text = 'Tải driver'
$tabMain.UseVisualStyleBackColor = $false
$tabMain.BackColor = $background

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$drvDownloadDir = Join-Path $script:AppDirectory 'downloads'
$drvToolsDir    = Join-Path $script:AppDirectory 'tools'
$drvFixFolder   = Join-Path $script:AppDirectory '(FIX LOL) Driver 40HX'
$drvGDriveId    = '1Fb1f0PYQoxH6Vz12mbQ9nNGu_m3utDLS'
$drvPatchRepo   = 'dartraiden/NVIDIA-patcher'
$drvMinVersion  = [version]'610.0'

# ---------- UI ----------
$mainTitle = New-Object System.Windows.Forms.Label
$mainTitle.Location  = New-Object Drawing.Point(24, 14)
$mainTitle.Size      = New-Object Drawing.Size(660, 26)
$mainTitle.Font      = New-Object Drawing.Font('Segoe UI Semibold', 13, [Drawing.FontStyle]::Bold)
$mainTitle.ForeColor = $navy
$mainTitle.Text      = 'Tải và chuẩn bị Driver và unlocker'
$tabMain.Controls.Add($mainTitle)

$mainInfo = New-Object System.Windows.Forms.Label
$mainInfo.Location  = New-Object Drawing.Point(24, 44)
$mainInfo.Size      = New-Object Drawing.Size(660, 36)
$mainInfo.ForeColor = $muted
$mainInfo.Text      = 'Kiểm tra driver và unlocker. Mục nào thiếu sẽ được tải và xử lý: Dartraiden = driver NVIDIA gốc + bản patch (ghi đè); 40HX = tải từ Google Drive rồi giải nén; Unlocker = tải 3 tệp exe từ GitHub.'
$tabMain.Controls.Add($mainInfo)

$grpDrv = New-Object System.Windows.Forms.GroupBox
$grpDrv.Text     = 'Trạng thái'
$grpDrv.Location = New-Object Drawing.Point(12, 86)
$grpDrv.Size     = New-Object Drawing.Size(696, 148)
$tabMain.Controls.Add($grpDrv)

$lblDart = New-Object System.Windows.Forms.Label
$lblDart.Location = New-Object Drawing.Point(14, 24)
$lblDart.Size     = New-Object Drawing.Size(670, 20)
$lblDart.Text     = 'Driver Dartraiden: chưa kiểm tra'
$grpDrv.Controls.Add($lblDart)

$lblFix = New-Object System.Windows.Forms.Label
$lblFix.Location = New-Object Drawing.Point(14, 48)
$lblFix.Size     = New-Object Drawing.Size(670, 20)
$lblFix.Text     = 'Driver 40HX: chưa kiểm tra'
$grpDrv.Controls.Add($lblFix)

$lblUnlocker = New-Object System.Windows.Forms.Label
$lblUnlocker.Location = New-Object Drawing.Point(14, 72)
$lblUnlocker.Size     = New-Object Drawing.Size(670, 20)
$lblUnlocker.Text     = 'Unlocker: chưa kiểm tra'
$grpDrv.Controls.Add($lblUnlocker)

$lblPkg = New-Object System.Windows.Forms.Label
$lblPkg.Location = New-Object Drawing.Point(14, 106)
$lblPkg.Size     = New-Object Drawing.Size(110, 22)
$lblPkg.Text     = 'Gói NVIDIA gốc:'
$grpDrv.Controls.Add($lblPkg)

$cmbPkg = New-Object System.Windows.Forms.ComboBox
$cmbPkg.DropDownStyle = 'DropDownList'
$cmbPkg.Location = New-Object Drawing.Point(126, 103)
$cmbPkg.Size     = New-Object Drawing.Size(150, 24)
[void]$cmbPkg.Items.Add('Desktop')
[void]$cmbPkg.Items.Add('Notebook')
$cmbPkg.SelectedIndex = 0
$grpDrv.Controls.Add($cmbPkg)

$chkNvenc = New-Object System.Windows.Forms.CheckBox
$chkNvenc.Location = New-Object Drawing.Point(300, 104)
$chkNvenc.Size     = New-Object Drawing.Size(380, 24)
$chkNvenc.Text     = 'Ưu tiên bản patch NVENC-NvFBC (nếu có)'
$chkNvenc.Checked  = $true
$grpDrv.Controls.Add($chkNvenc)

$btnDrvPrepare = New-Object System.Windows.Forms.Button
$btnDrvPrepare.Location  = New-Object Drawing.Point(12, 242)
$btnDrvPrepare.Size      = New-Object Drawing.Size(696, 34)
$btnDrvPrepare.Text      = 'Kiểm tra và tải mục còn thiếu'
$btnDrvPrepare.BackColor = $blue
$btnDrvPrepare.ForeColor = [Drawing.Color]::White
$btnDrvPrepare.FlatStyle = 'Flat'
$btnDrvPrepare.FlatAppearance.BorderSize = 0
$tabMain.Controls.Add($btnDrvPrepare)

$drvProgress = New-Object System.Windows.Forms.ProgressBar
$drvProgress.Location = New-Object Drawing.Point(12, 288)
$drvProgress.Size     = New-Object Drawing.Size(640, 22)
$drvProgress.Minimum = 0; $drvProgress.Maximum = 100
$tabMain.Controls.Add($drvProgress)

$drvPct = New-Object System.Windows.Forms.Label
$drvPct.Location  = New-Object Drawing.Point(658, 289)
$drvPct.Size      = New-Object Drawing.Size(50, 22)
$drvPct.TextAlign = 'MiddleRight'
$drvPct.Text      = '0%'
$tabMain.Controls.Add($drvPct)

$mainStatus = New-Object System.Windows.Forms.Label
$mainStatus.Location  = New-Object Drawing.Point(12, 316)
$mainStatus.Size      = New-Object Drawing.Size(696, 22)
$mainStatus.ForeColor = $muted
$mainStatus.Text      = '● Sẵn sàng'
$tabMain.Controls.Add($mainStatus)

$grpDrvLog = New-Object System.Windows.Forms.GroupBox
$grpDrvLog.Text     = 'Log (trực tiếp)'
$grpDrvLog.Location = New-Object Drawing.Point(12, 344)
$grpDrvLog.Size     = New-Object Drawing.Size(696, 286)
$tabMain.Controls.Add($grpDrvLog)

$drvLog = New-Object System.Windows.Forms.TextBox
$drvLog.Multiline  = $true
$drvLog.ReadOnly   = $true
$drvLog.ScrollBars = 'Both'
$drvLog.WordWrap   = $false
$drvLog.Font       = New-Object Drawing.Font('Consolas', 8.5)
$drvLog.BackColor  = [Drawing.Color]::White
$drvLog.Location   = New-Object Drawing.Point(10, 20)
$drvLog.Size       = New-Object Drawing.Size(676, 256)
$grpDrvLog.Controls.Add($drvLog)

# ---------- helpers: log / progress ----------
function Add-DrvLog {
    param([string]$Text)
    $drvLog.AppendText(('[{0:HH:mm:ss}] {1}{2}' -f (Get-Date), $Text, [Environment]::NewLine))
    Write-AppLog "Tải driver: $Text"
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-DrvProgress {
    param([int]$Value, [string]$Message = '')
    $v = [Math]::Max(0, [Math]::Min(100, $Value))
    $drvProgress.Value = $v
    $drvPct.Text = "$v%"
    if ($Message) { $mainStatus.Text = $Message; $mainStatus.ForeColor = $blue }
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-DrvBusy {
    param([bool]$Busy)
    foreach ($c in @($btnDrvPrepare, $cmbPkg, $chkNvenc, $btnUpdate)) { $c.Enabled = -not $Busy }
}

# ---------- helpers: HTTP ----------
function New-DrvRequest {
    param([string]$Url, $Cookies = $null)
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'Mozilla/5.0 CMP40HX-Toolkit'
    $req.AllowAutoRedirect = $true
    $req.Timeout = 30000
    $req.ReadWriteTimeout = 60000
    if ($Cookies) { $req.CookieContainer = $Cookies }
    return $req
}

function Save-DrvResponse {
    param($Response, [string]$Path, [string]$Label)
    $total = [long]$Response.ContentLength
    $part  = "$Path.part"
    $in  = $Response.GetResponseStream()
    $out = [IO.File]::Create($part)
    try {
        $buf = New-Object byte[] 262144
        $done = 0L
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $last = 0L
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n)
            $done += $n
            if (($sw.ElapsedMilliseconds - $last) -ge 250) {
                $last = $sw.ElapsedMilliseconds
                $mb = [Math]::Round($done / 1MB, 1)
                if ($total -gt 0) {
                    Set-DrvProgress ([int](100 * $done / $total)) ("● Đang tải {0}: {1} / {2} MB" -f $Label, $mb, [Math]::Round($total / 1MB, 1))
                } else {
                    Set-DrvProgress 0 ("● Đang tải {0}: {1} MB" -f $Label, $mb)
                }
            }
        }
    }
    finally { $out.Dispose(); $in.Dispose(); $Response.Close() }
    Move-Item -LiteralPath $part -Destination $Path -Force
}

function Save-DrvUrl {
    # Tải về $Path; bỏ qua nếu tệp có sẵn và cùng dung lượng.
    param([string]$Url, [string]$Path, [string]$Label)
    $resp = (New-DrvRequest $Url).GetResponse()
    if ((Test-Path -LiteralPath $Path) -and $resp.ContentLength -gt 0 -and
        (Get-Item -LiteralPath $Path).Length -eq $resp.ContentLength) {
        $resp.Close()
        Add-DrvLog "  = $Label đã có sẵn trong downloads, bỏ qua tải."
        return
    }
    Save-DrvResponse -Response $resp -Path $Path -Label $Label
}

function Save-GoogleDriveFile {
    param([string]$FileId, [string]$DestDir, [string]$Label)
    $cookies = New-Object Net.CookieContainer
    $url = "https://drive.usercontent.google.com/download?id=$FileId&export=download&confirm=t"
    for ($try = 0; $try -lt 3; $try++) {
        $resp = (New-DrvRequest $url $cookies).GetResponse()
        if (([string]$resp.ContentType) -notmatch 'text/html') {
            $name = "$Label.bin"
            $cd = [string]$resp.Headers['Content-Disposition']
            if ($cd -match 'filename="([^"]+)"') { $name = $Matches[1] }
            $name = ($name -replace '[\\/:*?"<>|]', '_')
            $dest = Join-Path $DestDir $name
            if ((Test-Path -LiteralPath $dest) -and $resp.ContentLength -gt 0 -and
                (Get-Item -LiteralPath $dest).Length -eq $resp.ContentLength) {
                $resp.Close()
                Add-DrvLog "  = $name đã có sẵn trong downloads, bỏ qua tải."
            } else {
                Save-DrvResponse -Response $resp -Path $dest -Label $name
            }
            return $dest
        }
        # Trang xác nhận "không quét được virus" của Google Drive
        $reader = New-Object IO.StreamReader($resp.GetResponseStream())
        $html = $reader.ReadToEnd()
        $reader.Dispose(); $resp.Close()
        if ($html -match '<form[^>]+action="([^"]+)"') {
            $action = [Net.WebUtility]::HtmlDecode($Matches[1])
            $pairs = foreach ($m in [regex]::Matches($html, '<input[^>]+type="hidden"[^>]+name="([^"]+)"[^>]+value="([^"]*)"')) {
                '{0}={1}' -f $m.Groups[1].Value, [Uri]::EscapeDataString([Net.WebUtility]::HtmlDecode($m.Groups[2].Value))
            }
            $url = $action + '?' + ($pairs -join '&')
        } else {
            throw 'Google Drive không cho tải trực tiếp (hết lượt tải hoặc file không công khai). Hãy tải thủ công, giải nén vào thư mục "(FIX LOL) Driver 40HX".'
        }
    }
    throw 'Google Drive liên tục trả về trang xác nhận. Hãy tải thủ công.'
}

# ---------- helpers: archives ----------
function Get-ArchiveKind {
    param([string]$Path)
    $fs = [IO.File]::OpenRead($Path)
    try { $b = New-Object byte[] 8; [void]$fs.Read($b, 0, 8) } finally { $fs.Dispose() }
    if ($b[0] -eq 0x50 -and $b[1] -eq 0x4B) { return 'zip' }
    if ($b[0] -eq 0x37 -and $b[1] -eq 0x7A -and $b[2] -eq 0xBC -and $b[3] -eq 0xAF) { return '7z' }
    if ($b[0] -eq 0x52 -and $b[1] -eq 0x61 -and $b[2] -eq 0x72 -and $b[3] -eq 0x21) { return 'rar' }
    if ($b[0] -eq 0x4D -and $b[1] -eq 0x5A) { return 'exe' }   # bộ cài tự giải nén của NVIDIA (7z SFX)
    return 'unknown'
}

function Get-SevenZip {
    param([switch]$AllowLite)
    $cands = @(
        (Join-Path $env:ProgramFiles '7-Zip\7z.exe'),
        (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe'),
        (Join-Path $drvToolsDir '7z.exe')
    )
    foreach ($c in $cands) { if (Test-Path -LiteralPath $c -PathType Leaf) { return $c } }
    $cmd = Get-Command '7z.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if (-not $AllowLite) { return '' }

    # 7zr.exe (bản gọn chính thức của 7-Zip) chỉ đọc được 7z / SFX
    $lite = Join-Path $drvToolsDir '7zr.exe'
    if (-not (Test-Path -LiteralPath $lite -PathType Leaf)) {
        New-Item -ItemType Directory -Path $drvToolsDir -Force | Out-Null
        Add-DrvLog '  Không thấy 7-Zip, tải 7zr.exe từ www.7-zip.org...'
        Save-DrvUrl -Url 'https://www.7-zip.org/a/7zr.exe' -Path $lite -Label '7zr.exe'
    }
    return $lite
}

function Invoke-DrvProcess {
    param([string]$Exe, [string]$Arguments)
    $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -WindowStyle Hidden -PassThru
    while (-not $p.HasExited) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
    $p.WaitForExit()
    return $p.ExitCode
}

function Expand-DrvArchive {
    param([string]$Archive, [string]$Dest)
    $kind = Get-ArchiveKind $Archive
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    $lite = (@('7z', 'exe') -contains $kind)
    $sz = Get-SevenZip -AllowLite:$lite
    if ($sz) {
        $code = Invoke-DrvProcess $sz ('x "{0}" -o"{1}" -y' -f $Archive, $Dest)
        if ($code -gt 1) { throw "7-Zip báo lỗi (mã $code) khi giải nén $([IO.Path]::GetFileName($Archive))." }
    }
    elseif ($kind -eq 'zip') {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($Archive, $Dest)
    }
    else { throw "Cần cài 7-Zip để giải nén định dạng '$kind'. Cài 7-Zip rồi chạy lại." }
}

function Test-DrvDiskSpace {
    param([long]$NeedBytes)
    try {
        $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($script:AppDirectory))
        if ($drive.AvailableFreeSpace -lt $NeedBytes) {
            throw ("Ổ {0} chỉ còn {1} GB trống, cần khoảng {2} GB." -f $drive.Name, [Math]::Round($drive.AvailableFreeSpace / 1GB, 1), [Math]::Round($NeedBytes / 1GB, 1))
        }
    }
    catch [System.ArgumentException] { }   # đường dẫn UNC: bỏ qua kiểm tra
}

# ---------- helpers: kiểm tra driver có sẵn ----------
function Test-DrvFolder {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return $null }
    try { return (Resolve-DriverFolder -FolderPath $Path) } catch { return $null }
}

function Get-DrvStatus {
    $dartCands = @()
    if ($script:Config.WorkDirectory) { $dartCands += [string]$script:Config.WorkDirectory }
    $dartCands += @(Get-ChildItem -LiteralPath $script:AppDirectory -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{3}\.\d+-.*win' } | Select-Object -ExpandProperty FullName)
    $fixCands = @($drvFixFolder)
    if ($script:Config.GameDirectory) { $fixCands += [string]$script:Config.GameDirectory }

    $dart = $null; $fix = $null
    foreach ($c in $dartCands) { $r = Test-DrvFolder $c; if ($r) { $dart = $r; break } }
    foreach ($c in $fixCands)  { $r = Test-DrvFolder $c; if ($r) { $fix  = $r; break } }
    return [pscustomobject]@{ Dart = $dart; Fix = $fix; Unlocker = (Get-UnlockerStatus) }
}

function Update-TabEnabledState {
    param(
        $Status,
        [string]$DesktopProfile = ''
    )
    if (-not $Status) { $Status = Get-DrvStatus }

    # Returns true if at least one component (Dartraiden driver, 40HX fix driver, or Unlocker exes) is downloaded
    $hasDownloadedItems = [bool]($Status.Dart -or $Status.Fix -or $Status.Unlocker.Ok)

    # Enable or disable (grey out) the remaining 3 tabs
    if ($tabDriver)  { $tabDriver.Enabled  = $hasDownloadedItems }
    if ($tabDefault) { $tabDefault.Enabled = $hasDownloadedItems }
    if ($tabNew)     { 
        # Tab 4 requires at least one downloaded item AND must not be in Game Mode
        $tabNew.Enabled = $hasDownloadedItems -and ($DesktopProfile -ne 'Game') 
    }
}

function Show-DrvStatus {
    param($St)
    if ($St.Dart) {
        $lblDart.Text = "✔ Dartraiden: $([IO.Path]::GetFileName($St.Dart.Folder))  (DriverVer $($St.Dart.Version))"
        $lblDart.ForeColor = $green
    } else { 
        $lblDart.Text = '✖ Dartraiden: chưa có (hoặc chưa được patch)'
        $lblDart.ForeColor = [Drawing.Color]::Firebrick 
    }
    
    if ($St.Fix) {
        $lblFix.Text = "✔ 40HX: $([IO.Path]::GetFileName($St.Fix.Folder))  (DriverVer $($St.Fix.Version))"
        $lblFix.ForeColor = $green
    } else { 
        $lblFix.Text = '✖ 40HX: chưa có'
        $lblFix.ForeColor = [Drawing.Color]::Firebrick 
    }
    
    $u = $St.Unlocker
    if ($u.Ok) {
        $tagText = if ($u.Tag) { " ($($u.Tag))" } else { '' }
        $lblUnlocker.Text = "✔ Unlocker: đủ 3 tệp exe$tagText"
        $lblUnlocker.ForeColor = $green
    } else {
        $lblUnlocker.Text = "✖ Unlocker: thiếu $($u.Missing -join ', ')"
        $lblUnlocker.ForeColor = [Drawing.Color]::Firebrick  # Fixed: changed from $green to Firebrick red
    }

    Update-TabEnabledState -Status $St
}

# ---------- Dartraiden: tìm bản patch mới nhất ----------
function Get-DartraidenRelease {
    param([bool]$PreferNvenc, [version]$Min)
    $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$drvPatchRepo/releases?per_page=100" -UserAgent 'CMP40HX-Toolkit'
    $found = @()
    foreach ($r in @($releases)) {
        if ($r.draft) { continue }
        if ($r.tag_name -notmatch '^(\d+\.\d+)$') { continue }      # bản Windows có tag 2 phần; bản Linux có 3 phần
        $v = [version]$Matches[1]
        if ($r.name -and $r.name -notmatch '(?i)windows') { continue }
        if ($v -lt $Min) { continue }
        $found += [pscustomobject]@{ Version = $v; Tag = [string]$r.tag_name; Release = $r }
    }
    $best = $found | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $best) { throw "Không tìm thấy bản patch Windows >= $Min trên GitHub." }

    $assets = @($best.Release.assets | Where-Object { $_.name -match '(?i)\.(zip|7z|rar)$' })
    if ($assets.Count -eq 0) { throw "Release $($best.Tag) không có tệp nén patch." }
    $nv    = @($assets | Where-Object { $_.name -match '(?i)nvenc' })
    $plain = @($assets | Where-Object { $_.name -notmatch '(?i)nvenc' })
    $pick = if ($PreferNvenc -and $nv.Count -gt 0) { $nv[0] }
            elseif ($plain.Count -gt 0) { $plain[0] }
            else { $assets[0] }
    return [pscustomobject]@{
        Tag       = $best.Tag
        AssetName = [string]$pick.name
        Url       = [string]$pick.browser_download_url
        IsNvenc   = ($pick.name -match '(?i)nvenc')
        AllNames  = ($assets | ForEach-Object { $_.name }) -join ', '
    }
}

function Resolve-NvidiaUrl {
    param([string]$Ver, [string]$PreferredKind)
    $kinds = if ($PreferredKind -eq 'desktop') { @('desktop', 'notebook') } else { @('notebook', 'desktop') }
    foreach ($k in $kinds) {
        $url = "https://us.download.nvidia.com/Windows/$Ver/$Ver-$k-win10-win11-64bit-international-dch-whql.exe"
        try {
            $req = New-DrvRequest $url
            $req.Method = 'HEAD'
            $r = $req.GetResponse(); $r.Close()
            if ($k -ne $PreferredKind) { Add-DrvLog "  [!] Không có gói $PreferredKind, dùng gói $k." }
            return $url
        }
        catch { Add-DrvLog "  - Gói $k không tải được: $($_.Exception.Message)" }
    }
    throw "Không tìm thấy gói driver NVIDIA $Ver trên us.download.nvidia.com."
}

function Find-PatchRoot {
    # Tìm thư mục trong bản patch có nhiều đường dẫn tương đối trùng với thư mục driver nhất (0 = không trùng).
    param([string]$PatchDir, [string]$DriverDir)
    $dirs = @($PatchDir) + @(Get-ChildItem -LiteralPath $PatchDir -Directory -Recurse -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FullName)
    $bestDir = ''; $bestScore = 0
    foreach ($d in $dirs) {
        $score = 0
        foreach ($f in @(Get-ChildItem -LiteralPath $d -File -Recurse -ErrorAction SilentlyContinue)) {
            $rel = $f.FullName.Substring($d.Length).TrimStart('\')
            if (Test-Path -LiteralPath (Join-Path $DriverDir $rel) -PathType Leaf) { $score++ }
        }
        if ($score -gt $bestScore) { $bestScore = $score; $bestDir = $d }
    }
    return [pscustomobject]@{ Root = $bestDir; Overlap = $bestScore }
}

function Copy-OverwriteTree {
    param([string]$From, [string]$To)
    $added = 0; $over = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $From -File -Recurse)) {
        $rel  = $f.FullName.Substring($From.Length).TrimStart('\')
        $dest = Join-Path $To $rel
        $dir  = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if (Test-Path -LiteralPath $dest) { $over++; Add-DrvLog "  ~ ghi đè: $rel" } else { $added++; Add-DrvLog "  + thêm mới: $rel" }
        Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
    }
    return [pscustomobject]@{ Added = $added; Overwritten = $over }
}

function Copy-PatchByName {
    # Ghi đè theo tên tệp: mỗi tệp trong patch đè lên tệp cùng tên trong driver.
    # Nếu có nhiều tệp cùng tên, chọn tệp có phần đuôi đường dẫn khớp nhiều nhất (hòa thì đè tất cả).
    param([string]$PatchDir, [string]$DriverDir)
    $index = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $DriverDir -File -Recurse -ErrorAction SilentlyContinue)) {
        $k = $f.Name.ToLowerInvariant()
        if (-not $index.ContainsKey($k)) { $index[$k] = New-Object System.Collections.ArrayList }
        [void]$index[$k].Add($f.FullName)
    }
    $over = 0
    foreach ($p in @(Get-ChildItem -LiteralPath $PatchDir -File -Recurse)) {
        $k = $p.Name.ToLowerInvariant()
        if (-not $index.ContainsKey($k)) { Add-DrvLog "  - bỏ qua (driver không có tệp này): $($p.Name)"; continue }
        $prel = $p.FullName.Substring($PatchDir.Length).TrimStart('\').Split('\')
        $best = -1; $targets = @()
        foreach ($c in $index[$k]) {
            $crel = $c.Substring($DriverDir.Length).TrimStart('\').Split('\')
            $n = 0
            while ($n -lt $prel.Count -and $n -lt $crel.Count -and
                   $prel[$prel.Count - 1 - $n] -ieq $crel[$crel.Count - 1 - $n]) { $n++ }
            if ($n -gt $best) { $best = $n; $targets = @($c) }
            elseif ($n -eq $best) { $targets += $c }
        }
        foreach ($t in $targets) {
            Copy-Item -LiteralPath $p.FullName -Destination $t -Force
            $over++
            Add-DrvLog "  ~ ghi đè: $($t.Substring($DriverDir.Length).TrimStart('\'))"
        }
    }
    return [pscustomobject]@{ Added = 0; Overwritten = $over }
}

function Merge-PatchIntoDriver {
    param([string]$PatchDir, [string]$DriverDir)
    $files = @(Get-ChildItem -LiteralPath $PatchDir -File -Recurse -ErrorAction SilentlyContinue)

    # Bản patch chỉ chứa các tệp nén lồng bên trong: giải nén tiếp
    $inner = @($files | Where-Object { $_.Extension -match '^\.(zip|7z|rar)$' })
    if ($files.Count -gt 0 -and $inner.Count -eq $files.Count) {
        $i = 0
        foreach ($a in $inner) {
            $i++
            Add-DrvLog "  Giải nén tiếp tệp lồng bên trong: $($a.Name)"
            Expand-DrvArchive -Archive $a.FullName -Dest (Join-Path $PatchDir "inner$i")
            Remove-Item -LiteralPath $a.FullName -Force
        }
        $files = @(Get-ChildItem -LiteralPath $PatchDir -File -Recurse -ErrorAction SilentlyContinue)
    }

    Add-DrvLog "  Bản patch chứa $($files.Count) tệp:"
    foreach ($f in ($files | Select-Object -First 40)) {
        Add-DrvLog ('    ' + $f.FullName.Substring($PatchDir.Length).TrimStart('\'))
    }
    if ($files.Count -gt 40) { Add-DrvLog "    ... và $($files.Count - 40) tệp nữa" }
    if ($files.Count -eq 0) { throw 'Giải nén bản patch ra thư mục rỗng. Kiểm tra tệp trong downloads\ và 7-Zip.' }

    # Cách 1: khớp theo đường dẫn tương đối
    $pr = Find-PatchRoot -PatchDir $PatchDir -DriverDir $DriverDir
    if ($pr.Overlap -gt 0) {
        Add-DrvLog "  Khớp theo đường dẫn: gốc patch = $($pr.Root) ($($pr.Overlap) tệp trùng)"
        return (Copy-OverwriteTree -From $pr.Root -To $DriverDir)
    }

    # Cách 2: khớp theo tên tệp
    Add-DrvLog '  Không khớp theo đường dẫn, chuyển sang khớp theo tên tệp...'
    $res = Copy-PatchByName -PatchDir $PatchDir -DriverDir $DriverDir
    if ($res.Overwritten -eq 0) {
        throw 'Không tệp nào trong bản patch trùng tên với tệp trong driver gốc. Có thể đã chọn nhầm tệp patch hoặc nhầm gói Notebook/Desktop; xem danh sách tệp ở log.'
    }
    return $res
}

function Install-DartraidenDriver {
    param($Release = $null)
    Add-DrvLog '== Dartraiden: chuẩn bị driver =='
    Test-DrvDiskSpace 8GB
    New-Item -ItemType Directory -Path $drvDownloadDir -Force | Out-Null

    Set-DrvProgress 2 '● Đang hỏi GitHub bản patch mới nhất...'
    $rel = if ($Release) { $Release } else { Get-DartraidenRelease -PreferNvenc $chkNvenc.Checked -Min $drvMinVersion }
    Add-DrvLog "  Bản patch mới nhất: $($rel.Tag)"
    Add-DrvLog "  Tệp có trong release: $($rel.AllNames)"
    Add-DrvLog "  Chọn: $($rel.AssetName)  (NVENC: $($rel.IsNvenc))"
    if ($chkNvenc.Checked -and -not $rel.IsNvenc) { Add-DrvLog 'Không tìm thấy bản patch NVENC, chuyển sang tải bản thường' }

    $kind = if ($cmbPkg.SelectedIndex -eq 1) { 'desktop' } else { 'notebook' }
    $nvUrl = Resolve-NvidiaUrl -Ver $rel.Tag -PreferredKind $kind
    $nvFile = [IO.Path]::GetFileName($nvUrl)
    Add-DrvLog "  Gói NVIDIA: $nvUrl"
    $nvExe  = Join-Path $drvDownloadDir $nvFile
    $target = Join-Path $script:AppDirectory ([IO.Path]::GetFileNameWithoutExtension($nvFile))
    $setup = $null
    if (Test-Path -LiteralPath $target) {
        $setup = Get-ChildItem -LiteralPath $target -Filter 'setup.exe' -File -Recurse -Depth 1 -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($setup) {
        Add-DrvLog "  = Thư mục driver gốc đã có, dùng lại (không tải lại): $target"
    } else {
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        Save-DrvUrl -Url $nvUrl -Path $nvExe -Label $nvFile
        Set-DrvProgress 50 "● Đang giải nén $nvFile..."
        Add-DrvLog "  Giải nén vào: $target"
        Expand-DrvArchive -Archive $nvExe -Dest $target
        $setup = Get-ChildItem -LiteralPath $target -Filter 'setup.exe' -File -Recurse -Depth 1 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($setup) { Remove-DrvDownload $nvExe }
    }
    if (-not $setup) { throw "Giải nén xong nhưng không thấy setup.exe trong $target." }
    $driverDir = $setup.DirectoryName

    $patchFile = Join-Path $drvDownloadDir $rel.AssetName
    Save-DrvUrl -Url $rel.Url -Path $patchFile -Label $rel.AssetName

    $tmp = Join-Path $env:TEMP ('cmp40hx-patch-' + [guid]::NewGuid().ToString('N'))
    try {
        Set-DrvProgress 70 '● Đang giải nén bản patch...'
        Expand-DrvArchive -Archive $patchFile -Dest $tmp
        Set-DrvProgress 80 '● Đang ghi đè tệp patch vào thư mục driver...'
        $res = Merge-PatchIntoDriver -PatchDir $tmp -DriverDir $driverDir
        Add-DrvLog "  Xong: ghi đè $($res.Overwritten), thêm mới $($res.Added)."
        Remove-DrvDownload $patchFile
    }
    finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } }

    $resolved = Test-DrvFolder $target
    if (-not $resolved) {
        Add-DrvLog '  [!] Đã patch nhưng Resolve-DriverFolder không nhận được đúng 1 INF chứa DEV_1F0B. Kiểm tra thư mục thủ công.'
        return $null
    }
    Add-DrvLog "  OK: $($resolved.InfPath)  (DriverVer $($resolved.Version))"
    return $resolved
}

# ---------- 40HX: Google Drive ----------
function Install-FixDriver {
    Add-DrvLog '== Driver 40HX: tải từ Google Drive =='
    Test-DrvDiskSpace 3GB
    New-Item -ItemType Directory -Path $drvDownloadDir -Force | Out-Null
    $archive = Save-GoogleDriveFile -FileId $drvGDriveId -DestDir $drvDownloadDir -Label 'driver-40HX'
    Add-DrvLog "  Đã có: $archive"

    $tmp = Join-Path $env:TEMP ('cmp40hx-fix-' + [guid]::NewGuid().ToString('N'))
    try {
        Set-DrvProgress 60 '● Đang giải nén driver 40HX...'
        Expand-DrvArchive -Archive $archive -Dest $tmp
        # Nếu bên trong chỉ có đúng một thư mục gốc thì bỏ lớp đó
        $root = $tmp
        while ($true) {
            $items = @(Get-ChildItem -LiteralPath $root -Force)
            if ($items.Count -eq 1 -and $items[0].PSIsContainer) { $root = $items[0].FullName } else { break }
        }
        Set-DrvProgress 85 '● Đang chép vào thư mục driver 40HX...'
        $res = Copy-OverwriteTree -From $root -To $drvFixFolder
        Add-DrvLog "  Xong: ghi đè $($res.Overwritten), thêm mới $($res.Added) -> $drvFixFolder"
        Remove-DrvDownload $archive
    }
    finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } }

    $resolved = Test-DrvFolder $drvFixFolder
    if (-not $resolved) {
        Add-DrvLog '  [!] Không nhận được đúng 1 INF Display chứa DEV_1F0B trong thư mục này. Kiểm tra thủ công.'
        return $null
    }
    Add-DrvLog "  OK: $($resolved.InfPath)  (DriverVer $($resolved.Version))"
    return $resolved
}

# ---------- gán vào Thiết lập driver (chỉ khi mục đó đang trống/không hợp lệ) ----------
function Set-DrvProfileConfig {
    param([ValidateSet('Work', 'Game')][string]$Profile, $Resolved)
    $cur = if ($Profile -eq 'Work') { [string]$script:Config.WorkDirectory } else { [string]$script:Config.GameDirectory }
    if ($cur -and (Test-DrvFolder $cur)) { return }      # đang có cấu hình tốt, không đụng tới
    if ($Profile -eq 'Work') { $script:Config.WorkDirectory = $Resolved.Folder; $script:Config.WorkInf = $Resolved.InfPath }
    else                     { $script:Config.GameDirectory = $Resolved.Folder; $script:Config.GameInf = $Resolved.InfPath }
    Save-Config -Config $script:Config
    Add-DrvLog "  Đã gán vào Thiết lập driver ($Profile)."
}

function Invoke-DrvPrepare {
    $st = Get-DrvStatus
    Show-DrvStatus $st
    if ($st.Dart -and $st.Fix -and $st.Unlocker.Ok) {
        Add-DrvLog 'Cả ba mục đã có sẵn, không cần tải.'; Set-DrvProgress 100; return
    }

    $errors = 0
    if (-not $st.Dart) {
        try { $r = Install-DartraidenDriver; if ($r) { Set-DrvProfileConfig -Profile Work -Resolved $r } else { $errors++ } }
        catch { $errors++; Add-DrvLog "  [!] LỖI Dartraiden: $($_.Exception.Message)" }
    }
    if (-not $st.Fix) {
        try { $r = Install-FixDriver; if ($r) { Set-DrvProfileConfig -Profile Game -Resolved $r } else { $errors++ } }
        catch { $errors++; Add-DrvLog "  [!] LỖI 40HX: $($_.Exception.Message)" }
    }
    if (-not $st.Unlocker.Ok) {
        try { Update-UnlockerExe }
        catch { $errors++; Add-DrvLog "  [!] LỖI Unlocker: $($_.Exception.Message)" }
    }

    Show-DrvStatus (Get-DrvStatus)
    if (Get-Command Refresh-UiState -ErrorAction SilentlyContinue) { try { Refresh-UiState -KeepStatus } catch { } }
    if ($errors -eq 0) {
        Set-DrvProgress 100
        $mainStatus.Text = '● Hoàn tất'; $mainStatus.ForeColor = $green
    } else {
        $mainStatus.Text = "● Xong nhưng có $errors lỗi - xem log"; $mainStatus.ForeColor = [Drawing.Color]::Firebrick
    }
}

# ---------- buttons ----------

$btnDrvPrepare.Add_Click({
    Set-DrvBusy $true
    try { Invoke-DrvPrepare }
    catch {
        Add-DrvLog "  [!] LỖI: $($_.Exception.Message)"
        $mainStatus.Text = "● Lỗi: $($_.Exception.Message)"; $mainStatus.ForeColor = [Drawing.Color]::Firebrick
    }
    finally { Set-DrvBusy $false }
})

# ---------- Tải về bản mới nhất (nút ở header) ----------
$drvStatePath   = Join-Path $script:AppDirectory 'cmp40hx-updates.json'
$updUnlockerDir = Join-Path $script:AppDirectory 'cmpunlocker'
$updUnlockerExes = @('40HXInstaller.exe', '40HXCheck.exe', '40HXUninstaller.exe')

function Get-UpdateState {
    if (Test-Path -LiteralPath $drvStatePath) {
        try { return (Get-Content -LiteralPath $drvStatePath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
    }
    return [pscustomobject]@{ UnlockerTag = '' }
}

function Save-UpdateState {
    param($State)
    $State | ConvertTo-Json | Set-Content -LiteralPath $drvStatePath -Encoding UTF8
}

function Get-UnlockerStatus {
    $missing = @($updUnlockerExes | Where-Object { -not (Test-Path -LiteralPath (Join-Path $updUnlockerDir $_) -PathType Leaf) })
    $tag = [string](Get-Prop (Get-UpdateState) 'UnlockerTag' '')
    return [pscustomobject]@{ Ok = ($missing.Count -eq 0); Missing = $missing; Tag = $tag }
}

function Remove-DrvDownload {
    param([string]$Path)
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            Remove-Item -LiteralPath $Path -Force
            Add-DrvLog "  Đã xoá tệp tải về: $([IO.Path]::GetFileName($Path))"
        }
    }
    catch { Add-DrvLog "  [!] Không xoá được $Path : $($_.Exception.Message)" }
}

function ConvertTo-TagVersion {
    param([string]$Tag)
    if ($Tag -match '(\d+(?:\.\d+)+)') { return [version]$Matches[1] }
    return $null
}

function Get-LocalPatchedVersion {
    # Phiên bản cao nhất trong các thư mục "NNN.NN-...win..." đã được patch (có INF DEV_1F0B)
    $best = $null
    $dirs = @(Get-ChildItem -LiteralPath $script:AppDirectory -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{3}\.\d+-.*win' })
    foreach ($d in $dirs) {
        if ($d.Name -notmatch '^(\d{3}\.\d+)-') { continue }
        $v = [version]$Matches[1]
        if ($best -and $v -le $best) { continue }
        if (Test-DrvFolder $d.FullName) { $best = $v }
    }
    return $best
}

function Update-DartraidenIfNewer {
    Add-DrvLog '== Dartraiden: kiểm tra bản patch mới nhất =='
    Set-DrvProgress 2 '● Đang kiểm tra bản patch Dartraiden mới nhất...'
    $rel    = Get-DartraidenRelease -PreferNvenc $chkNvenc.Checked -Min $drvMinVersion
    $remote = [version]$rel.Tag
    $local  = Get-LocalPatchedVersion
    if ($local) { Add-DrvLog "  Bản patch trên máy: $local | mới nhất trên GitHub: $remote" }
    else        { Add-DrvLog "  Chưa có driver đã patch trên máy | mới nhất trên GitHub: $remote" }

    if ($local -and $remote -le $local) {
        Add-DrvLog '  ✔ Đã là bản mới nhất, không cần tải driver NVIDIA.'
        return
    }
    Add-DrvLog "  Có bản patch mới ($remote): tải driver NVIDIA tương ứng và patch."
    $r = Install-DartraidenDriver -Release $rel
    if ($r) {
        Add-DrvLog "  Bản mới nằm ở: $($r.Folder)"
        Add-DrvLog '  [i] Chưa tự đổi cấu hình. Muốn dùng bản này: Chuyển driver > Thiết lập driver > chọn thư mục mới.'
    } else { throw 'Đã tải nhưng thư mục driver mới không hợp lệ (xem log).' }
}

function Get-UnlockerRelease {
    $fallbackUrl = 'https://github.com/Cyridd/cmpunlocker/releases/download/v2.0.2/CMP40HXWindowsUnlock.zip'
    try {
        $r = Invoke-RestMethod -Uri 'https://api.github.com/repos/Cyridd/cmpunlocker/releases/latest' -UserAgent 'CMP40HX-Toolkit'
        $a = @($r.assets | Where-Object { $_.name -ieq 'CMP40HXWindowsUnlock.zip' }) | Select-Object -First 1
        if ($a) { return [pscustomobject]@{ Tag = [string]$r.tag_name; Url = [string]$a.browser_download_url } }
        Add-DrvLog "  [!] Release $($r.tag_name) không có tệp CMP40HXWindowsUnlock.zip, dùng bản v2.0.2."
    }
    catch { Add-DrvLog "  [!] Không hỏi được GitHub ($($_.Exception.Message)), dùng bản v2.0.2." }
    return [pscustomobject]@{ Tag = 'v2.0.2'; Url = $fallbackUrl }
}

function Update-UnlockerExe {
    Add-DrvLog '== Unlocker: kiểm tra bản exe mới nhất =='
    Set-DrvProgress 2 '● Đang kiểm tra bản unlocker mới nhất...'
    $rel      = Get-UnlockerRelease
    $state    = Get-UpdateState
    $localTag = [string](Get-Prop $state 'UnlockerTag' '')
    $remoteV  = ConvertTo-TagVersion $rel.Tag
    $localV   = ConvertTo-TagVersion $localTag
    $missing  = @($updUnlockerExes | Where-Object { -not (Test-Path -LiteralPath (Join-Path $updUnlockerDir $_) -PathType Leaf) })
    Add-DrvLog ("  Bản đã ghi nhận: {0} | mới nhất: {1} | thiếu exe: {2}" -f $(if ($localTag) { $localTag } else { '(chưa rõ)' }), $rel.Tag, $missing.Count)

    if ($missing.Count -eq 0 -and $localV -and $remoteV -and $remoteV -le $localV) {
        Add-DrvLog '  ✔ Unlocker đã là bản mới nhất.'
        return
    }

    New-Item -ItemType Directory -Path $drvDownloadDir -Force | Out-Null
    New-Item -ItemType Directory -Path $updUnlockerDir -Force | Out-Null
    $zip = Join-Path $drvDownloadDir ('CMP40HXWindowsUnlock-{0}.zip' -f $rel.Tag)
    Save-DrvUrl -Url $rel.Url -Path $zip -Label 'CMP40HXWindowsUnlock.zip'
    Add-DrvLog ("  SHA256: {0}" -f (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash)

    $tmp = Join-Path $env:TEMP ('cmp40hx-unl-' + [guid]::NewGuid().ToString('N'))
    try {
        Set-DrvProgress 60 '● Đang giải nén unlocker...'
        Expand-DrvArchive -Archive $zip -Dest $tmp
        $backup = Join-Path $updUnlockerDir ('backup\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $updated = 0
        foreach ($n in $updUnlockerExes) {
            $src = Get-ChildItem -LiteralPath $tmp -Filter $n -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $src) { Add-DrvLog "  [!] Không thấy $n trong gói."; continue }
            $dst = Join-Path $updUnlockerDir $n
            try {
                if (Test-Path -LiteralPath $dst) {
                    New-Item -ItemType Directory -Path $backup -Force | Out-Null
                    Copy-Item -LiteralPath $dst -Destination $backup -Force
                }
                Copy-Item -LiteralPath $src.FullName -Destination $dst -Force
                $updated++
                Add-DrvLog "  ~ đã cập nhật: $n"
            }
            catch { Add-DrvLog "  [!] Không ghi được $n (đang chạy?): $($_.Exception.Message)" }
        }
    }
    finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } }

    if ($updated -ne $updUnlockerExes.Count) { throw "Chỉ cập nhật được $updated/$($updUnlockerExes.Count) tệp exe." }
    Remove-DrvDownload $zip
    if (Test-Path -LiteralPath $backup) { Add-DrvLog "  Bản cũ được sao lưu ở: $backup" }
    $state | Add-Member -NotePropertyName UnlockerTag -NotePropertyValue $rel.Tag -Force
    Save-UpdateState -State $state
    Add-DrvLog "  ✔ Unlocker đã cập nhật lên $($rel.Tag)."
}

function Invoke-LatestUpdate {
    Add-DrvLog '=== Tải về bản mới nhất ==='
    $errors = 0
    try { Update-DartraidenIfNewer } catch { $errors++; Add-DrvLog "  [!] LỖI Dartraiden: $($_.Exception.Message)" }
    try { Update-UnlockerExe }       catch { $errors++; Add-DrvLog "  [!] LỖI Unlocker: $($_.Exception.Message)" }
    Show-DrvStatus (Get-DrvStatus)
    if ($errors -eq 0) {
        Set-DrvProgress 100
        $mainStatus.Text = '● Đã kiểm tra và cập nhật xong'; $mainStatus.ForeColor = $green
    } else {
        $mainStatus.Text = "● Xong nhưng có $errors lỗi - xem log"; $mainStatus.ForeColor = [Drawing.Color]::Firebrick
    }
}

$btnUpdate.Add_Click({
    $tabs.SelectedTab = $tabMain          # chuyển sang tab có log để theo dõi
    Set-DrvBusy $true
    try { Invoke-LatestUpdate }
    catch {
        Add-DrvLog "  [!] LỖI: $($_.Exception.Message)"
        $mainStatus.Text = "● Lỗi: $($_.Exception.Message)"; $mainStatus.ForeColor = [Drawing.Color]::Firebrick
    }
    finally { Set-DrvBusy $false }
})

Add-DrvLog 'Tab Tải driver đã sẵn sàng.'
Show-DrvStatus (Get-DrvStatus)
# ================= END Tab: NEW FEATURE =================

$tabs.TabPages.AddRange(@($tabMain, $tabDriver, $tabDefault, $tabNew))
$tabs.SelectedTab = $tabMain

# Prevent switching to any tab that is currently greyed out / disabled
$tabs.Add_Selecting({
    param($sender, $e)
    if (-not $e.TabPage.Enabled) {
        $e.Cancel = $true
    }
})

$form.Controls.Add($tabs)
# ================= END TABS =================

    $script:CurrentDevice = $null
    $script:NextProfile = ''
    function Set-ProgressValue {
        param(
            [int]$Value,
            [string]$Message = ''
        )

        $safeValue = [Math]::Max(0, [Math]::Min(100, $Value))
        $progress.Value = $safeValue
        $progressPercent.Text = "$safeValue%"
        if ($Message) {
            $status.Text = $Message
            $status.ForeColor = $blue
        }
        [System.Windows.Forms.Application]::DoEvents()
    }

    function Animate-Progress {
        param(
            [int]$From,
            [int]$To,
            [string]$Message
        )

        for ($value = $From; $value -le $To; $value += 5) {
            Set-ProgressValue -Value $value -Message $Message
        }
        if ($progress.Value -ne $To) {
            Set-ProgressValue -Value $To -Message $Message
        }
    }

    function Refresh-UiState {
        param([switch]$KeepStatus)

        try {
            $script:CurrentDevice = Get-CmpDeviceInfo
            $currentVersion = Convert-DriverVersionForComparison $script:CurrentDevice.Version
            $workVersion = Convert-DriverVersionForComparison $script:Config.WorkVersion
            $gameVersion = Convert-DriverVersionForComparison $script:Config.GameVersion
            $nl = [Environment]::NewLine

            $profileKnown = $true
            if ($gameVersion -and $currentVersion -eq $gameVersion) {
                $currentProfile = 'GPU CHƠI LOL / VALORANT'
                $desktopProfile = 'Game'
                $modeHeading.Text = 'CHẾ ĐỘ CHƠI GAME'
                $modeDetail.Text = 'LOL / Valorant • Driver theo cấu hình'
                $modePanel.BackColor = [Drawing.Color]::FromArgb(22, 101, 52)
                $script:NextProfile = 'Work'
                $toggle.Text = 'CHUYỂN SANG GPU CÔNG SUẤT TỐI ĐA  →'
                $toggle.BackColor = $blue
            }
            elseif ($workVersion -and $currentVersion -eq $workVersion) {
                $currentProfile = 'GPU CÔNG SUẤT TỐI ĐA'
                $desktopProfile = 'Work'
                $modeHeading.Text = 'CHẾ ĐỘ LÀM VIỆC'
                $modeDetail.Text = 'Đồ họa / AI • Driver theo cấu hình'
                $modePanel.BackColor = $navy
                $script:NextProfile = 'Game'
                $toggle.Text = 'CHUYỂN SANG GPU CHƠI LOL / VALORANT  →'
                $toggle.BackColor = $green
            }
            else {
                $currentProfile = 'CHƯA XÁC ĐỊNH HỒ SƠ'
                $desktopProfile = ''
                $modeHeading.Text = 'CHƯA XÁC ĐỊNH'
                $modeDetail.Text = 'Hãy thiết lập hai thư mục driver'
                $modePanel.BackColor = $muted
                $script:NextProfile = ''
                $profileKnown = $false
                $toggle.Text = 'THIẾT LẬP DRIVER TRƯỚC KHI CHUYỂN'
                $toggle.BackColor = $muted
            }
            $profileLabel.Text = $currentProfile
            Update-TabEnabledState -DesktopProfile $desktopProfile
            if ($profileKnown) {
                try { Update-DesktopShortcut -Profile $desktopProfile -CreateIfMissing }
                catch { Write-AppLog "Không cập nhật được shortcut Desktop/Start Menu: $($_.Exception.Message)" }
            }
            $deviceLabel.Text = ('GPU: {0}{1}Phiên bản: {2}    •    INF: {3}{1}Chữ ký: {4}' -f $script:CurrentDevice.Description, $nl, $script:CurrentDevice.Version, $script:CurrentDevice.PublishedName, $script:CurrentDevice.Signer)
            $toggle.Enabled = $profileKnown -and $confirm.Checked
            if (-not $KeepStatus) {
                Set-ProgressValue -Value 0
                $status.Text = if ($profileKnown) { '● Sẵn sàng' } else { '● Cần thiết lập driver / phiên bản chưa khớp' }
                $status.ForeColor = $muted
            }
        }
        catch {
            $profileLabel.Text = 'KHÔNG NHẬN DIỆN ĐƯỢC THIẾT BỊ'
            $deviceLabel.Text = $_.Exception.Message
            $toggle.Enabled = $false
            $status.Text = '● Không thực hiện thay đổi'
            $status.ForeColor = [Drawing.Color]::Firebrick
        }
    }

    $confirm.Add_CheckedChanged({
        $toggle.Enabled = $confirm.Checked -and -not [string]::IsNullOrWhiteSpace($script:NextProfile)
    })

    $refreshButton.Add_Click({
        Refresh-UiState
    })

    $settingsButton.Add_Click({
        if ((Show-SettingsDialog -Config $script:Config) -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:Config = Get-Config
            $status.Text = '● Đã lưu cấu hình driver'
            $status.ForeColor = $green
            Refresh-UiState -KeepStatus
        }
    })

    $toggle.Add_Click({
        $operationSucceeded = $false
        try {
            Set-ProgressValue -Value 0 -Message '● Đang chuẩn bị chuyển driver...'
            Animate-Progress -From 0 -To 15 -Message '● Đang kiểm tra hồ sơ driver...'

            if ($script:NextProfile -eq 'Game') {
                if (Test-UnlockerInstalled) {
                    [System.Windows.Forms.MessageBox]::Show(
                        'Lỗi! Chưa gỡ cài đặt 40HX Unlocker!',
                        'CMP 40HX', 'OK', 'Error') | Out-Null
                    $status.Text = '● Không thể chuyển: 40HX Unlocker vẫn còn cài đặt'
                    $status.ForeColor = [Drawing.Color]::Firebrick
                    return
                }
                try {
                    $choice = Get-GameInstallSelection -InfPath $script:Config.GameInf -ModelName $script:Config.GameModel -ValidateWithSetupApi
                }
                catch {
                    $status.Text = '● Cần thiết lập driver game'
                    if ((Show-SettingsDialog -Config $script:Config) -ne [System.Windows.Forms.DialogResult]::OK) { return }
                    $script:Config = Get-Config
                    $choice = Get-GameInstallSelection -InfPath $script:Config.GameInf -ModelName $script:Config.GameModel -ValidateWithSetupApi
                }
                $profileName = 'LOL / Valorant'
                $resolvedGame = Assert-DriverProfileFolder -Config $script:Config -Profile Game
                $infPath = $resolvedGame.InfPath
                $installMode = $choice.Mode
                $modelName = $choice.ModelName
                if ($installMode -eq 'ForcedModel') {
                    $answer = [System.Windows.Forms.MessageBox]::Show(
                        "Chuẩn bị ép model '$modelName' lên CMP 40HX. Bạn đã thử bộ driver này và có phương án khôi phục nếu GPU mất hình?",
                        'Xác nhận chuyển driver ép', 'YesNo', 'Warning')
                    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
                }
            }
            elseif ($script:NextProfile -eq 'Work') {
                if (-not (Test-InfSupportsCmp40Hx -InfPath $script:Config.WorkInf)) {
                    throw 'INF GPU làm việc không còn hợp lệ hoặc không chứa DEV_1F0B. Mở Thiết lập driver.'
                }
                $profileName = 'GPU công suất tối đa'
                $resolvedWork = Assert-DriverProfileFolder -Config $script:Config -Profile Work
                $infPath = $resolvedWork.InfPath
                $installMode = 'Compatible'
                $modelName = ''
            }
            else {
                throw 'Không xác định được chế độ hiện tại. Hãy thiết lập hai INF và kiểm tra driver trước.'
            }

            $toggle.Enabled = $false
            $settingsButton.Enabled = $false
            $refreshButton.Enabled = $false
            Animate-Progress -From 20 -To 35 -Message '● Đang xác thực INF đã chọn...'
            Animate-Progress -From 40 -To 60 -Message "● Đang chuyển sang driver $profileName..."

            $result = Install-CmpDriver -ProfileName $profileName -InfPath $infPath -InstallMode $installMode -ModelName $modelName
            Animate-Progress -From 65 -To 90 -Message '● Đang xác nhận trạng thái driver mới...'
            Refresh-UiState -KeepStatus
            $operationSucceeded = $true
            if ($result.RebootRequired) {
                [System.Windows.Forms.MessageBox]::Show(
                    'Driver đã được đổi nhưng Windows yêu cầu khởi động lại để hoàn tất.',
                    'CMP 40HX',
                    'OK',
                    'Information') | Out-Null
            }
        }
        catch {
            Write-AppLog "LỖI: $($_.Exception.Message)"
            $status.Text = '● Không đổi được driver'
            $status.ForeColor = [Drawing.Color]::Firebrick
            [System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                'Không đổi được driver CMP 40HX',
                'OK',
                'Error') | Out-Null
        }
        finally {
            $settingsButton.Enabled = $true
            $refreshButton.Enabled = $true
            $confirm.Checked = $false
            Refresh-UiState -KeepStatus
        }

        if ($operationSucceeded) {
            Animate-Progress -From 95 -To 100 -Message '● Hoàn tất chuyển driver'
            $status.Text = "● Đã chuyển sang $profileName - $($result.Device.Version)"
            $status.ForeColor = $green
        }
    })

    Write-AppLog 'Đang nhận diện trạng thái driver hiện tại.'
    Refresh-UiState
    Write-AppLog 'Chuẩn bị hiển thị cửa sổ chính.'
    $dialogResult = $form.ShowDialog()
    Write-AppLog "Cửa sổ chính đã đóng: $dialogResult"
}

if ($ScanFolder) {
    try {
        $resolved = Resolve-DriverFolder -FolderPath $ScanFolder
        Write-Output "OK: $($resolved.InfPath) | DriverVer=$($resolved.Version)"
        exit 0
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}

if ($CheckOnly) {
    try {
        $device = Get-CmpDeviceInfo
        $currentInf = Get-DriverStoreInfPath -PublishedName $device.PublishedName
        if (-not $currentInf) {
            throw "Không tìm thấy INF hiện tại cho $($device.PublishedName)."
        }
        Write-Output "OK: $($device.Description) | $($device.PublishedName) | $($device.Version) | $($device.InstanceId) | $currentInf"
        exit 0
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}

if ($ValidateGameInf) {
    try {
        $device = Get-CmpDeviceInfo
        $fullPath = [IO.Path]::GetFullPath($ValidateGameInf)
        $savedConfig = Get-Config
        $script:GameModel = [string]$savedConfig.GameModel
        if ((Test-InfSupportsCmp40Hx -InfPath $fullPath)) {
            Write-Output "OK: INF có DEV_1F0B | $fullPath"
            exit 0
        }
        Initialize-ForcedModelDriverApi
        $containsModel = [Cmp40Hx.ForcedModelDriverApi]::ContainsModel($device.InstanceId, $fullPath, $script:GameModel)
        if (-not $containsModel) {
            throw "Không tìm thấy model $($script:GameModel) trong INF."
        }
        Write-Output "OK: $($script:GameModel) | $fullPath | $($device.InstanceId)"
        exit 0
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}

if (-not (Test-IsAdministrator)) {
    Start-ElevatedCopy
    exit
}

try {
    Write-AppLog "Khởi động CMP40HX-DriverToggle v$($script:Version)."
    Start-Gui
}
catch {
    Write-AppLog "LỖI KHỞI ĐỘNG: $($_.Exception.Message)"
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'CMP40HX-DriverToggle', 'OK', 'Error') | Out-Null
    exit 1
}