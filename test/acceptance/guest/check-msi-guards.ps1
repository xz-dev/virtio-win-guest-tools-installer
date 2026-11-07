[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$MsiPath,
    [Parameter(Mandatory = $true)][string]$BaselineMsiPath,
    [Parameter(Mandatory = $true)][string]$OutputPath
)

# Read-only package/table checks and IN-MEMORY condition-engine cases only.
# This does not execute installer actions or create genuine ownership/registration fixtures.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $OutputPath) { throw 'Use a new receipt path; retain prior results.' }
$outputDirectory = Split-Path -Parent $OutputPath
[void][IO.Directory]::CreateDirectory($outputDirectory)
$script:assertions = 0
$cases = New-Object 'System.Collections.Generic.List[object]'
$session = [uint32]0
$receipt = [ordered]@{
    passed = $false
    scope = 'IN-MEMORY Windows Installer condition evaluation and read-only MSI table comparison. No installer actions or genuine dual-owner/client registration fixture.'
    scriptSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    msiSha256 = $null
    baselineSha256 = $null
    assertionsPassed = 0
    engineCasesPassed = 0
    clientGuardRows = 0
    serviceGuardRows = 0
    candidateTables = $null
    baselineTables = $null
    cases = @()
    error = $null
}

function Assert-Check([bool]$Test, [string]$Message) {
    if (-not $Test) { throw $Message }
    $script:assertions++
}

try {
if (-not ('Pr85MsiGuardNative' -as [type])) {
    # Keep CodeDOM's compilation scratch files under the task result directory.
    $oldTemp = $env:TEMP
    $oldTmp = $env:TMP
    try {
    $env:TEMP = $outputDirectory
    $env:TMP = $outputDirectory
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class Pr85MsiGuardNative
{
    [DllImport("msi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern uint MsiOpenDatabaseW(string path, IntPtr mode, out uint database);
    [DllImport("msi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern uint MsiDatabaseOpenViewW(uint database, string query, out uint view);
    [DllImport("msi.dll", ExactSpelling = true)]
    private static extern uint MsiViewExecute(uint view, uint record);
    [DllImport("msi.dll", ExactSpelling = true)]
    private static extern uint MsiViewFetch(uint view, out uint record);
    [DllImport("msi.dll", ExactSpelling = true)]
    private static extern int MsiRecordIsNull(uint record, uint field);
    [DllImport("msi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern uint MsiRecordGetStringW(uint record, uint field, StringBuilder value, ref uint length);
    [DllImport("msi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern uint MsiOpenPackageExW(string path, uint options, out uint session);
    [DllImport("msi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern uint MsiSetPropertyW(uint session, string name, string value);
    [DllImport("msi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int MsiEvaluateConditionW(uint session, string condition);
    [DllImport("msi.dll", ExactSpelling = true)]
    private static extern uint MsiCloseHandle(uint handle);

    private static void Check(uint result, string operation)
    {
        if (result != 0) throw new InvalidOperationException(operation + " returned " + result);
    }

    private static string ReadString(uint record, uint field)
    {
        if (MsiRecordIsNull(record, field) != 0) return null;
        uint length = 0;
        uint result = MsiRecordGetStringW(record, field, null, ref length);
        if (result != 0 && result != 234) Check(result, "MsiRecordGetStringW(size)");
        var value = new StringBuilder(checked((int)length + 1));
        uint capacity = checked(length + 1);
        Check(MsiRecordGetStringW(record, field, value, ref capacity), "MsiRecordGetStringW(value)");
        return value.ToString();
    }

    public static string[][] Query(string path, string sql, int columns)
    {
        uint database = 0, view = 0;
        var rows = new List<string[]>();
        try
        {
            // MSIDBOPEN_READONLY is a null persistence argument.
            Check(MsiOpenDatabaseW(path, IntPtr.Zero, out database), "MsiOpenDatabaseW(read-only)");
            Check(MsiDatabaseOpenViewW(database, sql, out view), "MsiDatabaseOpenViewW");
            Check(MsiViewExecute(view, 0), "MsiViewExecute");
            for (;;)
            {
                uint record;
                uint result = MsiViewFetch(view, out record);
                if (result == 259) break; // ERROR_NO_MORE_ITEMS
                Check(result, "MsiViewFetch");
                try
                {
                    var row = new string[columns];
                    for (int column = 0; column < columns; ++column)
                        row[column] = ReadString(record, checked((uint)column + 1));
                    rows.Add(row);
                }
                finally { MsiCloseHandle(record); }
            }
            return rows.ToArray();
        }
        finally
        {
            if (view != 0) MsiCloseHandle(view);
            if (database != 0) MsiCloseHandle(database);
        }
    }

    public static uint OpenEngine(string path)
    {
        uint session;
        // MSIOPENPACKAGEFLAGS_IGNOREMACHINESTATE: no installed-state fixture is inferred.
        Check(MsiOpenPackageExW(path, 1, out session), "MsiOpenPackageExW(IGNOREMACHINESTATE)");
        return session;
    }

    public static void Set(uint session, string name, string value)
    {
        Check(MsiSetPropertyW(session, name, value), "MsiSetPropertyW(" + name + ")");
    }

    public static int Evaluate(uint session, string condition)
    {
        return MsiEvaluateConditionW(session, condition);
    }

    public static void Close(uint session) { if (session != 0) MsiCloseHandle(session); }
}
'@
    } finally {
        $env:TEMP = $oldTemp
        $env:TMP = $oldTmp
    }
}

function Read-MsiTable([string]$Path, [string]$Table, [string[]]$Columns) {
    $selection = @($Columns | ForEach-Object { '`' + $_ + '`' }) -join ', '
    $sql = 'SELECT ' + $selection + ' FROM `' + $Table + '` ORDER BY `' + $Columns[0] + '`'
    foreach ($row in [Pr85MsiGuardNative]::Query($Path, $sql, $Columns.Count)) {
        $values = [ordered]@{}
        for ($column = 0; $column -lt $Columns.Count; $column++) { $values[$Columns[$column]] = $row[$column] }
        [pscustomobject]$values
    }
}

function Set-Mode([uint32]$Handle, [string]$Installed, [string]$Remove, [string]$Mode) {
    [Pr85MsiGuardNative]::Set($Handle, 'Installed', $Installed)
    [Pr85MsiGuardNative]::Set($Handle, 'REMOVE', $Remove)
    [Pr85MsiGuardNative]::Set($Handle, 'REINSTALL', $(if ($Mode -eq 'repair') { 'ALL' } else { '' }))
    [Pr85MsiGuardNative]::Set($Handle, 'ADDLOCAL', $(if ($Mode -eq 'modify') { 'FE_viofs_driver' } else { '' }))
}

function Check-EngineCase([uint32]$Handle, [string]$Condition, [bool]$Expected, [object]$Case) {
    $result = [Pr85MsiGuardNative]::Evaluate($Handle, $Condition)
    Assert-Check (($result -eq 0 -or $result -eq 1) -and (($result -eq 1) -eq $Expected)) (
        'Condition mismatch/error: ' + ($Case | ConvertTo-Json -Compress) + '; MSI result=' + $result)
    $Case | Add-Member -NotePropertyName actual -NotePropertyValue ($result -eq 1)
    $Case | Add-Member -NotePropertyName expected -NotePropertyValue $Expected
    $cases.Add($Case)
}

    $MsiPath = (Resolve-Path -LiteralPath $MsiPath).ProviderPath
    $BaselineMsiPath = (Resolve-Path -LiteralPath $BaselineMsiPath).ProviderPath
    Assert-Check ($MsiPath -ne $BaselineMsiPath) 'Candidate and baseline must be different files.'
    $receipt.msiSha256 = (Get-FileHash -LiteralPath $MsiPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $receipt.baselineSha256 = (Get-FileHash -LiteralPath $BaselineMsiPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $columnsByTable = [ordered]@{
        LaunchCondition = @('Condition', 'Description')
        Component = @('Component', 'ComponentId', 'Directory_', 'Attributes', 'Condition', 'KeyPath')
        Directory = @('Directory', 'Directory_Parent', 'DefaultDir')
        File = @('File', 'Component_', 'FileName')
        ServiceInstall = @('ServiceInstall', 'Name', 'DisplayName', 'ServiceType', 'StartType', 'ErrorControl', 'LoadOrderGroup', 'Dependencies', 'StartName', 'Password', 'Arguments', 'Component_', 'Description')
        ServiceControl = @('ServiceControl', 'Name', 'Event', 'Arguments', 'Wait', 'Component_')
        InstallExecuteSequence = @('Action', 'Condition', 'Sequence')
        InstallUISequence = @('Action', 'Condition', 'Sequence')
    }
    $candidate = [ordered]@{}
    $baseline = [ordered]@{}
    foreach ($table in $columnsByTable.Keys) {
        $candidate[$table] = @(Read-MsiTable $MsiPath $table $columnsByTable[$table])
        $baseline[$table] = @(Read-MsiTable $BaselineMsiPath $table $columnsByTable[$table])
    }
    $receipt.candidateTables = $candidate
    $receipt.baselineTables = $baseline
    foreach ($table in @('Component', 'Directory', 'File', 'ServiceInstall', 'ServiceControl', 'InstallExecuteSequence', 'InstallUISequence')) {
        $left = ConvertTo-Json -InputObject @($candidate[$table]) -Depth 8 -Compress
        $right = ConvertTo-Json -InputObject @($baseline[$table]) -Depth 8 -Compress
        Assert-Check ($left -ceq $right) ($table + ' changed beyond the approved LaunchCondition-only fix; inspect the exported rows.')
    }

    $clientRows = @($candidate.LaunchCondition | Where-Object { $_.Condition -match 'INSTALLED_W10X64_' })
    $baselineClientRows = @($baseline.LaunchCondition | Where-Object { $_.Condition -match 'INSTALLED_W10X64_' })
    Assert-Check ($clientRows.Count -eq $baselineClientRows.Count) 'Compiled client guard row count changed.'
    $beforeNames = @($baselineClientRows | ForEach-Object { [regex]::Match($_.Condition, '\bINSTALLED_W10X64_([A-Za-z0-9_]+)\b').Value } | Sort-Object)
    $afterNames = @($clientRows | ForEach-Object { [regex]::Match($_.Condition, '\bINSTALLED_W10X64_([A-Za-z0-9_]+)\b').Value } | Sort-Object)
    Assert-Check ((ConvertTo-Json -InputObject $beforeNames -Compress) -ceq (ConvertTo-Json -InputObject $afterNames -Compress)) 'Compiled client guard identities changed.'
    $hasWin11Components = @($candidate.Component | Where-Object { $_.Component -match 'Win11x64' }).Count -gt 0
    Assert-Check (($clientRows.Count -gt 0) -eq $hasWin11Components) 'Unexpected client guard coverage for this package architecture.'
    $serviceRows = @($candidate.LaunchCondition | Where-Object {
        $_.Condition -match '\bVIOFS_LEGACY_SERVICE\b' -and $_.Condition -match '\bVIOFS_CURRENT_SERVICE\b'
    })
    Assert-Check ($serviceRows.Count -eq 1) 'Exactly one dual-service guard is required.'
    $receipt.clientGuardRows = $clientRows.Count
    $receipt.serviceGuardRows = $serviceRows.Count

    $session = [Pr85MsiGuardNative]::OpenEngine($MsiPath)
    $removeValues = @('', 'ALL', 'FE_viofs_driver', 'all')
    $modes = @('normal', 'repair', 'modify')
    foreach ($row in $clientRows) {
        $match = [regex]::Match($row.Condition, '\bINSTALLED_W10X64_([A-Za-z0-9_]+)\b')
        Assert-Check $match.Success 'Cannot identify the compiled client guard property.'
        $oldName = $match.Value
        $newName = 'INSTALLED_W11X64_' + $match.Groups[1].Value
        Assert-Check ($row.Condition -match ('\b' + [regex]::Escape($newName) + '\b')) 'Missing matching Win11 property.'
        foreach ($old in @($false, $true)) { foreach ($new in @($false, $true)) {
            [Pr85MsiGuardNative]::Set($session, $oldName, $(if ($old) { 'engine-only-old.inf' } else { '' }))
            [Pr85MsiGuardNative]::Set($session, $newName, $(if ($new) { 'engine-only-new.inf' } else { '' }))
            foreach ($installed in @('', '1')) { foreach ($remove in $removeValues) { foreach ($mode in $modes) {
                Set-Mode $session $installed $remove $mode
                $expected = (-not ($old -and $new)) -or (($installed -eq '1') -and ($remove -ieq 'ALL'))
                $case = [pscustomobject][ordered]@{ guard = $oldName; old = $old; new = $new; installed = $installed; remove = $remove; mode = $mode }
                Check-EngineCase $session $row.Condition $expected $case
            } } }
        } }
        [Pr85MsiGuardNative]::Set($session, $oldName, '')
        [Pr85MsiGuardNative]::Set($session, $newName, '')
    }
    foreach ($legacy in @($false, $true)) { foreach ($current in @($false, $true)) {
        [Pr85MsiGuardNative]::Set($session, 'VIOFS_LEGACY_SERVICE', $(if ($legacy) { 'engine-only-legacy.exe' } else { '' }))
        [Pr85MsiGuardNative]::Set($session, 'VIOFS_CURRENT_SERVICE', $(if ($current) { 'engine-only-current.exe' } else { '' }))
        foreach ($installed in @('', '1')) { foreach ($remove in $removeValues) { foreach ($mode in $modes) {
            Set-Mode $session $installed $remove $mode
            $case = [pscustomobject][ordered]@{ guard = 'dual-service'; legacy = $legacy; current = $current; installed = $installed; remove = $remove; mode = $mode }
            Check-EngineCase $session $serviceRows[0].Condition (-not ($legacy -and $current)) $case
        } } }
    } }

    foreach ($table in @('InstallExecuteSequence', 'InstallUISequence')) {
        $search = @($candidate[$table] | Where-Object { $_.Action -eq 'AppSearch' })
        $launch = @($candidate[$table] | Where-Object { $_.Action -eq 'LaunchConditions' })
        Assert-Check ($search.Count -eq 1 -and $launch.Count -eq 1) ($table + ' must schedule AppSearch and LaunchConditions exactly once.')
        Assert-Check ([int]$search[0].Sequence -lt [int]$launch[0].Sequence) ($table + ': AppSearch must precede LaunchConditions.')
        foreach ($action in @($search[0], $launch[0])) {
            foreach ($installed in @('', '1')) { foreach ($remove in $removeValues) { foreach ($mode in $modes) {
                Set-Mode $session $installed $remove $mode
                if (-not [string]::IsNullOrWhiteSpace($action.Condition)) {
                    Assert-Check ([Pr85MsiGuardNative]::Evaluate($session, $action.Condition) -eq 1) (
                        $table + '/' + $action.Action + ' is skipped in an install/maintenance/removal context.')
                } else { Assert-Check $true 'Unconditional sequence action.' }
            } } }
        }
        $laterActions = if ($table -eq 'InstallExecuteSequence') { @('InstallInitialize', 'StopServices', 'DeleteServices') } else { @('ExecuteAction') }
        foreach ($name in $laterActions) {
            $later = @($candidate[$table] | Where-Object { $_.Action -eq $name })
            Assert-Check ($later.Count -eq 1) ($table + ': missing/duplicate ' + $name)
            Assert-Check ([int]$launch[0].Sequence -lt [int]$later[0].Sequence) ($table + ': LaunchConditions must precede ' + $name)
        }
    }
    $receipt.passed = $true
} catch {
    $receipt.error = $_.Exception.Message
} finally {
    if ($session -ne 0) { [Pr85MsiGuardNative]::Close($session) }
    $receipt.assertionsPassed = $script:assertions
    $receipt.engineCasesPassed = $cases.Count
    $receipt.cases = @($cases.ToArray())
    $receipt | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
}

if (-not $receipt.passed) { throw ('MSI guard check failed; retained receipt: ' + $OutputPath + '; ' + $receipt.error) }
Write-Output ('PASS: {0} MSI-engine cases; {1} total checks; {2} client rows; {3} service row. In-memory/table evidence only. Receipt: {4}' -f $receipt.engineCasesPassed, $receipt.assertionsPassed, $receipt.clientGuardRows, $receipt.serviceGuardRows, $OutputPath)
