# One local Windows operation against separately source-built test product; never repairs/reboots/retries.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Msi,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$DriverName,
    [Parameter(Mandatory)][string]$ReportDirectory,
    [ValidateSet('Install', 'Uninstall')][string]$Operation = 'Install',
    [ValidateSet('x64', 'x86')][string]$Architecture = 'x64',
    [ValidateSet(0, 3010, 1603)][int]$ExpectedExit = 1603,
    [switch]$FailAfterNative
)
$ErrorActionPreference = 'Stop'
$Msi = (Resolve-Path -LiteralPath $Msi).Path
New-Item -ItemType Directory -Path $ReportDirectory -ErrorAction Stop | Out-Null
$ReportDirectory = (Resolve-Path -LiteralPath $ReportDirectory).Path

function Capture-DriverState {
    $packages = @(Get-WindowsDriver -Online -All)
    $identity = @{}
    foreach ($package in $packages) {
        if (Test-Path -LiteralPath $package.OriginalFileName) {
            $identity[$package.Driver.ToLowerInvariant()] = (Get-FileHash -Algorithm SHA256 -LiteralPath $package.OriginalFileName).Hash
        }
    }
    $presentDevices = @(Get-PnpDevice -PresentOnly)
    $targetInfs = @{}
    foreach ($package in $packages) {
        if ([IO.Path]::GetFileName($package.OriginalFileName) -ieq "$DriverName.inf") { $targetInfs[$package.Driver.ToLowerInvariant()] = $true }
    }
    $bindings = @(Get-CimInstance Win32_PnPSignedDriver | Sort-Object DeviceID | ForEach-Object {
        $inf = [string]$_.InfName
        $packageId = $identity[$inf.ToLowerInvariant()]
        if (!$packageId -and $inf) {
            $path = Join-Path "$env:windir\INF" $inf
            if (Test-Path -LiteralPath $path) { $packageId = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash }
        }
        $rank = $null
        if ($targetInfs.ContainsKey($inf.ToLowerInvariant()) -and $presentDevices.InstanceId -contains $_.DeviceID) {
            $rank = (Get-PnpDeviceProperty -InstanceId $_.DeviceID -KeyName 'DEVPKEY_Device_DriverRank' -ErrorAction Stop).Data
        }
        [ordered]@{ Instance = $_.DeviceID; Package = $packageId; Version = $_.DriverVersion; Rank = $rank }
    })
    $devices = @($presentDevices | Sort-Object InstanceId | ForEach-Object {
        [ordered]@{ Instance = $_.InstanceId; Status = $_.Status; Class = $_.Class }
    })
    $view = if ($Architecture -eq 'x64') { [Microsoft.Win32.RegistryView]::Registry64 } else { [Microsoft.Win32.RegistryView]::Registry32 }
    $root = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
    $component = if ($Architecture -eq 'x64') { '{6717B43A-8D0D-4BF3-B139-67CE0B0C4D82}' } else { '{8D8F7030-7FE0-40C4-87D0-534CE62957BA}' }
    $key = $root.OpenSubKey("SOFTWARE\RedHat\Virtio-Win\Components\$component", $false)
    $metadata = [ordered]@{ KeyPresent = $null -ne $key }
    foreach ($name in @('oem', 'strongname', 'component', 'createdByComponent', 'infHash', 'catalogHash')) {
        $present = $key -and $key.GetValueNames() -contains $name
        $value = if ($present) { $key.GetValue($name) } else { $null }
        # OEM aliases may change after legitimate restaging; compare package identity, not oemNN.
        if ($present -and $name -eq 'oem') {
            $resolved = $identity[([string]$value).ToLowerInvariant()]
            if ($resolved) { $value = $resolved }
        }
        if ($present -and $name -eq 'strongname' -and (Test-Path -LiteralPath $value)) {
            $value = (Get-FileHash -Algorithm SHA256 -LiteralPath $value).Hash
        }
        $metadata[$name] = [ordered]@{ Present = [bool]$present; Value = $value }
    }
    if ($key) { $key.Dispose() }; $root.Dispose()
    $targetPackages = @($packages | Where-Object { [IO.Path]::GetFileName($_.OriginalFileName) -ieq "$DriverName.inf" } |
        ForEach-Object { $identity[$_.Driver.ToLowerInvariant()] } | Sort-Object -Unique)
    [ordered]@{ Devices = $devices; Bindings = $bindings; Metadata = $metadata; TargetPackages = $targetPackages }
}

$before = Capture-DriverState
$before | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 -LiteralPath "$ReportDirectory\before.json"
$verb = if ($Operation -eq 'Install') { '/i' } else { '/x' }
$arguments = @($verb, "`"$Msi`"", '/qn', 'REBOOT=ReallySuppress', '/l*vx', "`"$ReportDirectory\native.msi.log`"")
if ($FailAfterNative) { $arguments += 'PR85_FAIL_AFTER_NATIVE=1' }
$process = Start-Process -FilePath "$env:windir\System32\msiexec.exe" -ArgumentList $arguments -PassThru -Wait
$after = Capture-DriverState
$after | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 -LiteralPath "$ReportDirectory\after.json"
$beforeRanked = @($before.Bindings | Where-Object { $null -ne $_.Rank })
$afterRanked = @($after.Bindings | Where-Object { $null -ne $_.Rank })
$result = [ordered]@{ RankedBindingsUnchanged = ($beforeRanked.Count -gt 0 -and
    (($beforeRanked | ConvertTo-Json -Depth 6 -Compress) -ceq ($afterRanked | ConvertTo-Json -Depth 6 -Compress))); ActualExit = $process.ExitCode; ExpectedExit = $ExpectedExit; BaselineEquivalent =
    (($before | ConvertTo-Json -Depth 12 -Compress) -ceq ($after | ConvertTo-Json -Depth 12 -Compress)) }
$result | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath "$ReportDirectory\result.json"
if ($process.ExitCode -ne $ExpectedExit) { throw "Native exit $($process.ExitCode), expected $ExpectedExit. Stop; no retry/reboot performed." }
if ($ExpectedExit -eq 1603 -and !$result.BaselineEquivalent) { throw 'Native rollback changed captured baseline. Stop; no retry/reboot performed.' }
$result
