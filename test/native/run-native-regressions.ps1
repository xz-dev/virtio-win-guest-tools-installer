param(
 [Parameter(Mandatory=$true)][string]$DllPath,
 [Parameter(Mandatory=$true)][string]$OutputRoot,
 [Parameter(Mandatory=$true)][ValidateSet('x64','x86')][string]$Architecture
)
$ErrorActionPreference='Stop'
if([Environment]::Is64BitProcess -ne ($Architecture -eq 'x64')){throw 'Run with PowerShell matching the test DLL architecture'}
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Pr85NativeCall {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr LoadLibrary(string path);
 [DllImport("kernel32.dll",CharSet=CharSet.Ansi,SetLastError=true)] public static extern IntPtr GetProcAddress(IntPtr module,string name);
 [DllImport("kernel32.dll")] public static extern bool FreeLibrary(IntPtr module);
 [UnmanagedFunctionPointer(CallingConvention.StdCall,CharSet=CharSet.Unicode)] public delegate UInt32 Run([MarshalAs(UnmanagedType.LPWStr)] string directory);
 public static UInt32 Invoke(IntPtr p,string directory){return ((Run)Marshal.GetDelegateForFunctionPointer(p,typeof(Run)))(directory);}
}
'@
$dir=Join-Path $OutputRoot ('native-'+$Architecture+'-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $dir|Out-Null
$module=[Pr85NativeCall]::LoadLibrary([IO.Path]::GetFullPath($DllPath));if($module -eq [IntPtr]::Zero){throw "LoadLibrary failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"}
try {
 $entry=[Pr85NativeCall]::GetProcAddress($module,'Pr85RunNativeRegressions');if($entry -eq [IntPtr]::Zero){throw 'Task-only export not found'}
 $rc=[Pr85NativeCall]::Invoke($entry,$dir)
 $remaining=@(Get-Service -Name 'Pr85ReviewNative*' -ErrorAction SilentlyContinue|Select-Object Name,Status)
 $report=[ordered]@{taskOnly=$true;architecture=$Architecture;exit=$rc;directory=$dir;dllSha256=(Get-FileHash $DllPath -Algorithm SHA256).Hash;remainingTestServices=$remaining}
 $report|ConvertTo-Json -Depth 4|Set-Content "$dir\run-receipt.json" -Encoding UTF8
 Get-Content "$dir\native-results.tsv"; $report|ConvertTo-Json -Depth 4 -Compress
 if($remaining.Count){throw 'Test-owned services remain; inspect before another run'}
 if($rc){throw "Native regressions failed with $rc; preserve result and do not count as passed"}
} finally {[void][Pr85NativeCall]::FreeLibrary($module)}
