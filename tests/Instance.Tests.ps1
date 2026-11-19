# SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '..\src\LocalSafe.Instance.cs'
Add-Type -Path $source
$name='Local\LocalSafe.Test.'+[guid]::NewGuid().ToString('N')
$area=Join-Path ([IO.Path]::GetTempPath()) ('LocalSafe-InstanceTest-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $area | Out-Null
$worker=Join-Path $area 'worker.ps1';$ready=Join-Path $area 'ready.txt'
@'
param($Source,$Name,$Ready,[switch]$Hold)
$ErrorActionPreference='Stop'
Add-Type -Path $Source
$lease=[LocalSafeInstance]::TryAcquire($Name)
if(!$lease){exit 7}
try{
    if($Hold){[IO.File]::WriteAllText($Ready,'ready');Start-Sleep -Seconds 30}
}finally{$lease.Dispose()}
exit 0
'@ | Set-Content -LiteralPath $worker -Encoding UTF8
$child=$null;$lease=$null
try{
    $lease=[LocalSafeInstance]::TryAcquire($name)
    if(!$lease){throw 'First instance must acquire the mutex.'}
    $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$worker+'" "'+$source+'" "'+$name+'" "'+$ready+'"'
    $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $child=Start-Process $powershell -ArgumentList $arguments -WindowStyle Hidden -PassThru
    if(!$child.WaitForExit(10000) -or $child.ExitCode -ne 7){throw 'A second process must not acquire an active instance lock.'}
    $lease.Dispose();$lease=$null
    $child=Start-Process $powershell -ArgumentList ($arguments+' -Hold') -WindowStyle Hidden -PassThru
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    while(!(Test-Path -LiteralPath $ready) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
    if(!(Test-Path -LiteralPath $ready)){throw 'Fixture instance did not start.'}
    $child.Kill();$child.WaitForExit()
    $lease=[LocalSafeInstance]::TryAcquire($name)
    if(!$lease){throw 'An abandoned lock must not prevent restart after a crash.'}
}finally{
    if($lease){$lease.Dispose()}
    if($child -and !$child.HasExited){$child.Kill();$child.WaitForExit()}
    $resolved=[IO.Path]::GetFullPath($area)
    if($resolved.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -like 'LocalSafe-InstanceTest-*'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
'PASS: one owner across processes, second process rejected, normal release and crash recovery.'
