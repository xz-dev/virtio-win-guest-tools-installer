param(
 [Parameter(Mandatory=$true)][string]$SourceRoot,
 [Parameter(Mandatory=$true)][string]$TaskRoot,
 [Parameter(Mandatory=$true)][string]$WixRoot,
 [string]$Msbuild='C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe'
)
$ErrorActionPreference='Stop'
$expectedCpp='a3c1f9fd7c8135f32dfe8d304a8a59e918d2280209c24aae28998ba470c9fc51'
$expectedHeader='0cb4fe3e8e13b5e8496aac56b806b2e7d2be28df5d7a808a995bee1d1b212696'
$relative='src\DrvInst\DrvInstCA'
if((Get-FileHash "$SourceRoot\$relative\DriverTransaction.cpp" -Algorithm SHA256).Hash -ne $expectedCpp -or
   (Get-FileHash "$SourceRoot\$relative\DriverTransaction.h" -Algorithm SHA256).Hash -ne $expectedHeader){throw 'Candidate source hashes differ; inspect before rebuilding this exact-source regression harness'}
$sourceFull=[IO.Path]::GetFullPath($SourceRoot).TrimEnd('\');$taskFull=[IO.Path]::GetFullPath($TaskRoot).TrimEnd('\')
if($taskFull.StartsWith($sourceFull+'\',[StringComparison]::OrdinalIgnoreCase)-or $taskFull -eq $sourceFull){throw 'TaskRoot must be outside production source'}
$copy="$TaskRoot\test-source";if(Test-Path $copy){throw 'A fresh TaskRoot/test-source is required'}
New-Item -ItemType Directory -Force "$copy\src","$TaskRoot\logs","$TaskRoot\out"|Out-Null
Copy-Item -LiteralPath "$SourceRoot\src\DrvInst" -Destination "$copy\src\DrvInst" -Recurse
$ca="$copy\$relative"
Copy-Item -LiteralPath "$PSScriptRoot\Pr85NativeRegressions.cpp" -Destination "$ca\Pr85NativeRegressions.cpp"
$project="$ca\DrvInstCA.vcxproj";[xml]$xml=Get-Content $project -Raw
$ns=New-Object Xml.XmlNamespaceManager($xml.NameTable);$ns.AddNamespace('m','http://schemas.microsoft.com/developer/msbuild/2003')
$original=$xml.SelectSingleNode('//m:ClCompile[@Include="DriverTransaction.cpp"]',$ns)
if(-not $original){throw 'Exact production source project item not found'}
$original.SetAttribute('Include','Pr85NativeRegressions.cpp');$xml.Save($project)
Add-Content "$ca\CustomAction.def" "`r`n    Pr85RunNativeRegressions"
$oldWix=$env:WIX;$oldCl=$env:CL
try {
 $env:WIX=$WixRoot.TrimEnd('\')+'\';$env:CL='/I"'+$WixRoot.TrimEnd('\')+'\sdk\inc"'
 $outputs=@()
 foreach($arch in 'x64','x86') {
  $platform=if($arch -eq 'x86'){'Win32'}else{'x64'}
  $install="$copy\src\DrvInst\Install\Release\$arch";New-Item -ItemType Directory -Force $install|Out-Null
  & $Msbuild $project /t:Rebuild /m:1 /nr:false /v:normal /p:Configuration=Release "/p:Platform=$platform" "/p:PlatformTarget=$arch" /p:PlatformToolset=v143 /p:VCToolsVersion=14.44.35207 /p:WindowsTargetPlatformVersion=10.0.26100.0 /p:WixPlatformToolset=vs2015 "/p:WixNativeCATargetsPath=$WixRoot\sdk\wix.nativeca.targets" "/p:SolutionDir=$copy\src\DrvInst\" *> "$TaskRoot\logs\native-regressions-$arch.log"
  if($LASTEXITCODE){Get-Content "$TaskRoot\logs\native-regressions-$arch.log" -Tail 25;throw "Test-only $arch DLL build failed"}
  $dest="$TaskRoot\out\Pr85NativeRegressions-$arch.dll";Copy-Item "$install\DrvInstCA.dll" $dest
  $outputs += [ordered]@{arch=$arch;path=$dest;sha256=(Get-FileHash $dest -Algorithm SHA256).Hash}
 }
 [ordered]@{taskOnly=$true;productionSourceUnmodified=$true;cppSha256=$expectedCpp;headerSha256=$expectedHeader;sourceSubstitution='DriverTransaction.cpp project item replaced by wrapper including the unchanged real CPP';loggingOnlySuppressed=$true;outputs=$outputs}|ConvertTo-Json -Depth 5|Set-Content "$TaskRoot\build-receipt.json" -Encoding UTF8
 $outputs|ConvertTo-Json -Compress
} finally {$env:WIX=$oldWix;$env:CL=$oldCl}
