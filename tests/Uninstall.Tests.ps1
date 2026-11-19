# SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\LocalSafe.Uninstall.psm1') -Force
function Assert($Condition,[string]$Message){if(!$Condition){throw $Message}}
$root='C:\ExampleVendor\ExampleApp'
$parsed=Split-LSUninstallCommand ('"'+$root+'\uninstall.exe" --remove')
Assert ($parsed.FilePath -eq ($root+'\uninstall.exe') -and $parsed.Arguments -eq '--remove') 'Preserve executable and argument boundaries.'
$msi=Split-LSUninstallCommand 'MsiExec.exe /I{00000000-0000-0000-0000-000000000001}'
Assert ($msi.Arguments -eq '/x {00000000-0000-0000-0000-000000000001} /norestart') 'MSI maintenance entry must become interactive uninstall without automatic restart.'
foreach($command in @('cmd.exe /c remove.cmd','powershell.exe -Command anything','https://example.invalid/remove','uninstall.exe /s','rundll32.exe shared.dll,remove')){
    $rejected=$false;try{Split-LSUninstallCommand $command | Out-Null}catch{$rejected=$true}
    Assert $rejected ('Do not execute ambiguous or interpreted command: '+$command)
}
Assert (!(Test-LSCleanupDirectory 'C:\')) 'Reject drive roots.'
Assert (!(Test-LSCleanupDirectory $env:ProgramFiles)) 'Reject common application root.'
Assert (!(Test-LSCleanupDirectory ($env:SystemRoot+'\System32'))) 'Reject Windows directories.'
Assert (!(Test-LSCleanupDirectory ([IO.Path]::GetDirectoryName($env:USERPROFILE)))) 'Reject ancestors of the user profile.'
if($env:CommonProgramFiles){Assert (!(Test-LSCleanupDirectory ($env:CommonProgramFiles+'\ExampleRuntime'))) 'Reject shared runtime directories.'}
$coverage=@(foreach($source in @('Services','Processes','Uninstall','ScheduledTasks','Firewall')){[pscustomobject]@{Source=$source;Status='Complete'}})
$program=[pscustomobject]@{Id='fictional-id';Name='ExampleApp';Version='1.0';InstallPath=$root;PathSource='InstallLocation'}
$session=[pscustomobject]@{Program=$program;State='UninstallExited';ExitCode=0;Review=$null}
function Finding($Kind,$Id,$Reference,$Evidence='Path',$State='Stopped') {[pscustomobject]@{Kind=$Kind;Id=$Id;Name=$Id;Reference=$Reference;Evidence=$Evidence;State=$State;Detail='';Reason='Synthetic evidence'}}
$after=[pscustomobject]@{Coverage=$coverage;Findings=@(
    (Finding Service ExampleService ('"'+$root+'\agent.exe" --service')),
    (Finding Service SharedService ('"'+$root+'Other\agent.exe" --service')),
    (Finding Service RunningService ('"'+$root+'\agent.exe"') Path Running),
    (Finding Driver ExampleBus 'C:\Windows\System32\drivers\ExampleBus.sys' Component),
    (Finding DataDirectory ExampleApp 'C:\ExampleData\ExampleApp' Name)
)}
$plan=@(New-LSResidualPlan $session $after -StillRegistered $false)
Assert (@($plan | Where-Object {$_.CanClean}).Count -eq 1) 'Only the stopped, directly owned service is eligible.'
Assert (@($plan | Where-Object {$_.Selected}).Count -eq 0) 'Never preselect cleanup targets.'
Assert (@($plan | Where-Object {$_.Kind -eq 'Driver' -and $_.HoldReason -eq 'DriverReview'}).Count -eq 1) 'Explain driver dependency review separately from permissions.'
Assert (@($plan | Where-Object {$_.CanClean -and $_.HoldReason}).Count -eq 0) 'Eligible items do not have a retention reason.'
Assert (@(New-LSResidualPlan $session $after -StillRegistered $true | Where-Object {$_.CanClean}).Count -eq 0) 'Cancellation or remaining registration must block cleanup.'
Assert (@(New-LSResidualPlan $session $after -StillRegistered $false -CatalogComplete $false | Where-Object {$_.CanClean}).Count -eq 0) 'Incomplete dependency catalog must block cleanup.'
$missingCoverage=[pscustomobject]@{Coverage=@();Findings=$after.Findings}
Assert (@(New-LSResidualPlan $session $missingCoverage -StillRegistered $false | Where-Object {$_.CanClean}).Count -eq 0) 'Missing scan coverage must never imply a complete scan.'
$shared=[pscustomobject]@{Id='other';InstallPath=($root+'\shared-child')}
Assert (@(New-LSResidualPlan $session $after -OtherPrograms @($shared) -StillRegistered $false | Where-Object {$_.CanClean}).Count -eq 0) 'Overlapping installations must block cleanup.'
$session.ExitCode=1602
Assert (@(New-LSResidualPlan $session $after -StillRegistered $false | Where-Object {$_.CanClean}).Count -eq 0) 'Cancelled MSI must not authorize cleanup.'
$rejected=$false;try{Invoke-LSResidualCleanup $session -SelectedIds @('fictional') | Out-Null}catch{$rejected=$true}
Assert $rejected 'Execution requires explicit confirmation.'

# A removed installation directory must not erase evidence of an installed driver.
$retention=& (Get-Module LocalSafe.Uninstall) {
    $script:fixtureReference='C:\Windows\System32\drivers\ExampleVirtualBus.sys'
    function script:Get-LSInventory {
        [pscustomobject]@{CapturedAt='2000-01-02T00:00:00Z';Records=@([pscustomobject]@{Kind='Driver';Id='ExampleVirtualBus';Name='Example virtual bus';Reference=$script:fixtureReference;State='Running';Detail='System'});Coverage=@()}
    }
    function script:Get-LSScan {
        [pscustomobject]@{SchemaVersion=1;CapturedAt='2000-01-02T00:00:00Z';InstallPath='C:\FictionalMissingApp';Findings=@();Coverage=@()}
    }
    function script:Get-LSInstalledPrograms {[pscustomobject]@{Programs=@();Coverage=@()}}
    function script:Save-LSUninstallSession {param($Session)}
    $p=[pscustomobject]@{Id='HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\LocalSafe-Missing-Fictional-UnitFixture';Name='FictionalMissingApp';InstallPath='C:\FictionalMissingApp';PathSource='InstallLocation'}
    $old=[pscustomobject]@{Kind='Driver';Id='ExampleVirtualBus';Name='Example virtual bus';Reference=$script:fixtureReference;State='Running';Detail='System';Evidence='Component';Reason='Bundled INF matched before uninstall'}
    $s=[pscustomobject]@{Program=$p;Before=[pscustomobject]@{Findings=@($old)};After=$null;State='UninstallExited';ExitCode=0;Error='';Review=$null;Operations=@()}
    $same=Update-LSResidualReview $s
    $sameCount=@($same.After.Findings).Count
    $script:fixtureReference='C:\OtherVendor\replacement.sys'
    $changed=Update-LSResidualReview $s
    [pscustomobject]@{SameCount=$sameCount;ChangedCount=@($changed.After.Findings).Count}
}
Assert ($retention.SameCount -eq 1) 'Retain installed component evidence after bundles disappear.'
Assert ($retention.ChangedCount -eq 0) 'Do not reuse old ownership when a system record points elsewhere.'
$tokens=$null;$errors=$null
Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\src') -File | Where-Object {$_.Extension -in '.ps1','.psm1'} | ForEach-Object {
    [void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors)
    Assert ($errors.Count -eq 0) ('Windows PowerShell syntax error: '+$_.Name+' '+($errors | Out-String))
}
'PASS: uninstall command boundaries, confirmation, cancellation, shared paths, running components, coverage and syntax.'
