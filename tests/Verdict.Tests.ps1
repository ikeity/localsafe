# SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\LocalSafe.Uninstall.psm1') -Force
function Assert($Condition,[string]$Message){if(!$Condition){throw $Message}}
$sources=@('Services','Drivers','Processes','Startup','Uninstall','ScheduledTasks','Firewall','Devices','InstallationFiles','DataDirectories','RegistryNames')
$coverage=@($sources | ForEach-Object {[pscustomobject]@{Source=$_;Status='Complete'}})
$coverage | Where-Object {$_.Source -eq 'InstallationFiles'} | ForEach-Object {$_.Status='Unavailable'}
$session=[pscustomobject]@{State='Prepared';ExitCode=$null;Operations=@();Review=$null;After=$null}
Assert ((Get-LSResidualVerdict $session).Code -eq 'NotChecked') 'Before-uninstall records cannot certify cleanup.'
$session.State='UninstallExited';$session.ExitCode=1
$session.After=[pscustomobject]@{Coverage=$coverage}
$session.Review=[pscustomobject]@{StillRegistered=$false;RegistrationState='Missing';InstallDirectoryState='Missing';QuarantinePresent=@();CapturedAt='2000-01-01T00:00:00Z';CatalogCoverage=@([pscustomobject]@{Source='SyntheticCatalog';Status='Complete'});Items=@(
    [pscustomobject]@{Id='Firewall|ExampleRule';Evidence='Path';CanClean=$false},
    [pscustomobject]@{Id='Driver|ExampleBus';Evidence='Component';CanClean=$false}
)}
$verdict=Get-LSResidualVerdict $session
Assert ($verdict.Code -eq 'Remaining' -and $verdict.Remaining -eq 2 -and $verdict.Eligible -eq 0) 'Zero eligible items must never imply zero residues.'
Assert ($verdict.Direct -eq 1 -and $verdict.Candidates -eq 1) 'Keep direct and candidate evidence separate.'
Assert ($session.ExitCode -eq 1 -and $verdict.Summary.Contains('1')) 'Preserve nonstandard exit status.'
$session.Review.Items=@()
Assert ((Get-LSResidualVerdict $session).Code -eq 'ExitUnverified') 'Empty findings must not rewrite an unknown vendor exit code.'
$session.ExitCode=0
Assert ((Get-LSResidualVerdict $session).Code -eq 'ClearWithinScope') 'Missing installation folder is expected after uninstall when other sources are complete.'
$session.Review.InstallDirectoryState='Unknown'
Assert ((Get-LSResidualVerdict $session).Code -eq 'Incomplete') 'Unknown folder access cannot be interpreted as deletion.'
$session.Review.InstallDirectoryState='Missing'
$coverage | Where-Object {$_.Source -eq 'RegistryNames'} | ForEach-Object {$_.Status='Partial'}
Assert ((Get-LSResidualVerdict $session).Code -eq 'Incomplete') 'Incomplete registry coverage must not certify cleanup.'
$coverage | Where-Object {$_.Source -eq 'RegistryNames'} | ForEach-Object {$_.Status='Complete'}
$session.Review.QuarantinePresent=@('C:\ExampleVendor\.ExampleApp.localsafe-recovery-fictional')
Assert ((Get-LSResidualVerdict $session).Code -eq 'Quarantined') 'Quarantined files are retained, not permanently deleted.'
$session.Review.QuarantinePresent=@()
$session.Operations=@([pscustomobject]@{Id='Startup|Example';Status='Failed'})
Assert ((Get-LSResidualVerdict $session).Code -eq 'OperationFailed') 'Do not mask an unverified failed operation.'
$session.Operations+=@([pscustomobject]@{Id='Startup|Example';Status='Removed'})
Assert ((Get-LSResidualVerdict $session).Code -eq 'ClearWithinScope') 'A later verified attempt can supersede an earlier failed attempt without deleting history.'
$session.Review.StillRegistered=$true
Assert ((Get-LSResidualVerdict $session).Code -eq 'UninstallUnverified') 'Remaining uninstall registration must be visible.'
'PASS: verdicts distinguish residues, eligibility, unknown exits, coverage gaps, missing paths, quarantine and failed operations.'
