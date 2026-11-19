# SPDX-License-Identifier: GPL-3.0-only
param([switch]$LastUninstall)
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot 'LocalSafe.Launcher.cs'
$instanceSource=Join-Path $PSScriptRoot 'LocalSafe.Instance.cs'
$icon=Join-Path $PSScriptRoot 'assets\LocalSafe.ico'
$sha=[Security.Cryptography.SHA256]::Create()
try {
    $inputBytes=[IO.MemoryStream]::new()
    foreach($file in @($source,$instanceSource,$icon)){$bytes=[IO.File]::ReadAllBytes($file);$inputBytes.Write($bytes,0,$bytes.Length)}
    $hash=[BitConverter]::ToString($sha.ComputeHash($inputBytes.ToArray())).Replace('-','').Substring(0,12)
    $inputBytes.Dispose()
}
finally {$sha.Dispose()}
$runtime=Join-Path $env:LOCALAPPDATA ('LocalSafe\Runtime\'+$hash)
$exe=Join-Path $runtime 'LocalSafe.exe'
if(!(Test-Path -LiteralPath $exe)) {
    New-Item -ItemType Directory -Path $runtime -Force | Out-Null
    $buildLock=[Threading.Mutex]::new($false,('Local\LocalSafe.Build.'+$hash))
    $locked=$false
    try{
        try{$locked=$buildLock.WaitOne(30000)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(!$locked){throw 'LocalSafe build is still busy; try again shortly.'}
        if(!(Test-Path -LiteralPath $exe)){
            $compiler=[CodeDom.Compiler.CompilerParameters]::new()
            $compiler.GenerateExecutable=$true;$compiler.GenerateInMemory=$false;$compiler.OutputAssembly=$exe
            $compiler.CompilerOptions='/target:winexe /win32icon:"'+$icon+'"'
            foreach($assembly in @('System.dll','System.Core.dll','System.Windows.Forms.dll',[System.Management.Automation.PowerShell].Assembly.Location)){[void]$compiler.ReferencedAssemblies.Add($assembly)}
            Add-Type -Path @($source,$instanceSource) -CompilerParameters $compiler
        }
    }finally{if($locked){$buildLock.ReleaseMutex()};$buildLock.Dispose()}
}
# This is the interactive application the user requested, so show its window normally.
$entry=$(if($LastUninstall){'LocalSafe.LastUninstall.ps1'}else{'LocalSafe.Gui.ps1'})
Start-Process -FilePath $exe -ArgumentList ('"'+(Join-Path $PSScriptRoot $entry)+'"')
