# Prints what a user or administrator can see about virtio drivers on this machine, as JSON.
# Only public Windows views are read; nothing that belongs to the installer's own bookkeeping.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$products = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' |
    Where-Object { $_.DisplayName -like '*irtio*' } |
    Sort-Object DisplayName | ForEach-Object { "$($_.DisplayName) $($_.DisplayVersion)" })

$redHat = @(Get-WindowsDriver -Online | Where-Object { $_.ProviderName -like 'Red Hat*' })
$packages = @($redHat | ForEach-Object { "$(Split-Path $_.OriginalFileName -Leaf) $($_.Version)" } | Sort-Object)
# Published names (oemNN.inf) are reassigned by Windows; identify a device's package by INF name and version.
$packageOf = @{}
foreach ($p in $redHat) { $packageOf[$p.Driver] = "$(Split-Path $p.OriginalFileName -Leaf) $($p.Version)" }

$devices = [ordered]@{}
Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'PCI\VEN_1AF4*' } | Sort-Object InstanceId | ForEach-Object {
    $p = Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_DriverVersion, DEVPKEY_Device_Service, DEVPKEY_Device_DriverInfPath, DEVPKEY_Device_DriverInfSection
    $inf = [string]($p | Where-Object KeyName -eq DEVPKEY_Device_DriverInfPath).Data
    $devices[$_.InstanceId] = [ordered]@{
        status = [string]$_.Status
        driverVersion = [string]($p | Where-Object KeyName -eq DEVPKEY_Device_DriverVersion).Data
        driverPackage = $(if ($packageOf.ContainsKey($inf)) { $packageOf[$inf] } else { $inf })
        driverSection = [string]($p | Where-Object KeyName -eq DEVPKEY_Device_DriverInfSection).Data
        service = [string]($p | Where-Object KeyName -eq DEVPKEY_Device_Service).Data
    }
}

$services = [ordered]@{}
foreach ($name in @($devices.Values | ForEach-Object { $_.service } | Where-Object { $_ } | Sort-Object -Unique)) {
    $key = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
    $image = $key.ImagePath -replace '^\\SystemRoot', $env:SystemRoot -replace '^System32', "$env:SystemRoot\System32"
    $services[$name] = [ordered]@{
        state = [string](Get-Service $name -ErrorAction SilentlyContinue).Status
        imageExists = [bool](Test-Path $image)
    }
}

# Include delivered files and user-mode services: healthy device bindings alone miss a lost
# virtiofs.exe/blnsvr.exe or a service deleted by the predecessor during a major upgrade.
$installRoot = Join-Path $env:ProgramFiles 'Virtio-Win'
$files = [ordered]@{}
Get-ChildItem $installRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object Extension -in '.inf', '.cat', '.sys', '.exe', '.dll' |
    Sort-Object FullName | ForEach-Object {
        $files[$_.FullName.Substring($installRoot.Length + 1)] = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
    }
$userServices = [ordered]@{}
Get-CimInstance Win32_Service | Where-Object { $_.PathName -like '*\Virtio-Win\*' } |
    Sort-Object Name | ForEach-Object {
        if ($_.PathName -notmatch '^(?:"([^"]+)"|(.+?\.exe))(?:\s|$)') { throw "Cannot read service image path: $($_.Name)" }
        $image = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
        $userServices[$_.Name] = [ordered]@{
            state = [string]$_.State
            startMode = [string]$_.StartMode
            imageExists = [bool](Test-Path -LiteralPath $image)
        }
    }

[ordered]@{ products = $products; packages = $packages; devices = $devices; services = $services;
    files = $files; userServices = $userServices } | ConvertTo-Json -Depth 4 -Compress
