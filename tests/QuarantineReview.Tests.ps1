# SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\LocalSafe.Uninstall.psm1') -Force
$area=Join-Path ([IO.Path]::GetTempPath()) ('LocalSafe-QuarantineTest-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $area | Out-Null
try{
    & (Get-Module LocalSafe.Uninstall) {
        param($area)
        $script:quarantineFixture=Join-Path $area '.ExampleApp.localsafe-recovery-fixture'
        New-Item -ItemType Directory -Path $script:quarantineFixture | Out-Null
        function script:Get-LSInventory {[pscustomobject]@{Records=@();Coverage=@()}}
        function script:Get-LSScan {
            [pscustomobject]@{Findings=@(
                [pscustomobject]@{Kind='DataDirectory';Id=$script:quarantineFixture;Name='ExampleApp';Reference=$script:quarantineFixture;Evidence='Name';State='Present';Detail='';Reason='fixture'},
                [pscustomobject]@{Kind='DataDirectory';Id='other';Name='ExampleApp';Reference=($script:quarantineFixture+'-untracked');Evidence='Name';State='Present';Detail='';Reason='fixture'}
            );Coverage=@()}
        }
        function script:Get-LSInstalledPrograms {[pscustomobject]@{Programs=@();Coverage=@()}}
        function script:Save-LSUninstallSession {param($Session)}
        $s=[pscustomobject]@{Program=[pscustomobject]@{Id='HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\LocalSafe-Fictional-QuarantineFixture';Name='ExampleApp';InstallPath=(Join-Path $area 'missing');PathSource='InstallLocation'};Before=[pscustomobject]@{Findings=@()};After=$null;State='CleanupAttempted';ExitCode=0;Error='';Review=$null;Operations=@([pscustomobject]@{Id='fixture';Status='Quarantined';Quarantine=$script:quarantineFixture})}
        $result=Update-LSResidualReview $s
        if($result.Review.Items.Count -ne 1 -or $result.Review.Items[0].Id -ne 'DataDirectory|other'){throw 'Hide only exact tracked quarantine destinations, preserving other name matches.'}
        if(@($result.Review.QuarantinePresent).Count -ne 1 -or $result.Verdict.Quarantined -ne 1){throw 'Quarantined backups must remain explicitly counted.'}
        $s.Operations[0].Status='Failed'
        $result=Update-LSResidualReview $s
        if($result.Review.Items.Count -ne 2){throw 'A failed operation must not hide a directory.'}
    } $area
}finally{
    $resolved=[IO.Path]::GetFullPath($area)
    if($resolved.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -like 'LocalSafe-QuarantineTest-*'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
'PASS: tracked quarantines remain visible as backups, without double-counting them as residual candidates.'
