# SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\LocalSafe.Uninstall.psm1') -Force
& (Get-Module LocalSafe.Uninstall) {
    function Assert($value,$message){if(!$value){throw $message}}
    $s=[pscustomobject]@{State='UninstallExited';ExitCode=1;Target=[pscustomobject]@{FilePath='C:\Example\uninstall.exe'}}
    $a=[pscustomobject]@{Findings=@();Coverage=@('Services','Processes','Uninstall' | ForEach-Object {[pscustomobject]@{Source=$_;Status='Complete'}})}
    $r=Get-LSRemovalAssessment $s $a Missing Missing
    Assert ($r.CanReviewCleanup -and $r.Code -eq 'RemovedByEvidence' -and $s.ExitCode -eq 1) 'Independent facts permit review without changing vendor exit code.'
    Assert (!(Get-LSRemovalAssessment $s $a Present Missing).CanReviewCleanup) 'Remaining registration blocks unknown exit.'
    Assert (!(Get-LSRemovalAssessment $s $a Missing Unknown).CanReviewCleanup) 'Unknown directory state is not removal.'
    $a.Findings=@([pscustomobject]@{Kind='Process'})
    Assert (!(Get-LSRemovalAssessment $s $a Missing Missing).CanReviewCleanup) 'Related running process blocks evidence assessment.'
    $a.Findings=@();$a.Coverage[0].Status='Partial'
    Assert (!(Get-LSRemovalAssessment $s $a Missing Missing).CanReviewCleanup) 'Missing source cannot establish removal.'
    $a.Coverage[0].Status='Complete';$s.Target.FilePath='C:\Windows\System32\msiexec.exe';$s.ExitCode=1602
    Assert (!(Get-LSRemovalAssessment $s $a Missing Missing).CanReviewCleanup) 'MSI cancellation is not reinterpreted.'
    $s.Target.FilePath='C:\Example\uninstall.exe';$s.State='UninstallRunning'
    Assert (!(Get-LSRemovalAssessment $s $a Missing Missing).CanReviewCleanup) 'Never proceed while uninstall is running.'
    $name='ExampleProduct';$vendor='ExampleVendor';$path=Join-Path $env:APPDATA ($vendor+'\'+$name)
    $s=[pscustomobject]@{Program=[pscustomobject]@{Id='fixture';Name=$name;InstallPath=('C:\'+$vendor+'\'+$name);Publisher=$vendor};Before=[pscustomobject]@{Findings=@([pscustomobject]@{Kind='DataDirectory';Reference=$path})}}
    $item=[pscustomobject]@{Reference=$path}
    Assert (Test-LSProductDataDirectory $s $item) 'Exact recorded vendor/product directory is eligible for isolation.'
    $other=[pscustomobject]@{Id='other';Name=$name;InstallPath='D:\Other\ExampleProduct'}
    Assert (!(Test-LSProductDataDirectory $s $item @($other))) 'Another installed product sharing name blocks data isolation.'
    $s.Before.Findings=@()
    Assert (!(Test-LSProductDataDirectory $s $item)) 'No before record means no data isolation.'
}
'PASS: evidence assessment, unchanged raw exit, cancellation, running processes, coverage and data directory boundaries.'
