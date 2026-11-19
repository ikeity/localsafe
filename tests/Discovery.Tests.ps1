# SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\LocalSafe.Discovery.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\src\LocalSafe.Core.psm1') -Force
function Assert($Condition,[string]$Message){if(!$Condition){throw $Message}}
Assert ((Resolve-LSProgramDirectory -InstallLocation 'C:\').Source -eq 'Unknown') 'Do not infer an entire drive as an application.'
Assert ((Resolve-LSProgramDirectory -InstallLocation $env:ProgramFiles).Source -eq 'Unknown') 'Reject shared Program Files root.'
Assert ((Resolve-LSProgramDirectory -UninstallString 'msiexec.exe /x {00000000-0000-0000-0000-000000000000}').Source -eq 'Unknown') 'MSI product IDs are not install paths.'
Assert ((Resolve-LSProgramDirectory -InstallLocation 'C:\ExampleVendor\MissingApp').Source -eq 'InstallLocation') 'Keep explicit missing directories for residue inspection.'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('LocalSafe-Test-'+[guid]::NewGuid().ToString('N'))
$binary=Join-Path $temp 'Example Application.exe'
try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    [IO.File]::WriteAllText($binary,'fictional fixture; never executed')
    $inferred=Resolve-LSProgramDirectory -DisplayIcon ('"'+$binary+'",0')
    Assert ($inferred.Path -eq $temp -and $inferred.Source -eq 'DisplayIcon') 'Resolve quoted icon path with index.'
    $inferred=Resolve-LSProgramDirectory -UninstallString ($binary+' --remove')
    Assert ($inferred.Path -eq $temp -and $inferred.Source -eq 'UninstallString') 'Resolve unquoted executable path with spaces without execution.'
} finally {
    # Only remove the exact temporary fixture created above; no recursive deletion.
    if(Test-Path -LiteralPath $binary){Remove-Item -LiteralPath $binary}
    if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp}
}
$entries=@(foreach($pair in @(@('one','C:\Example\First','1.0'),@('duplicate','C:\Example\First','1.0'),@('other-path','C:\Example\Second','1.0'),@('other-version','C:\Example\First','2.0'))){[pscustomobject]@{Id=$pair[0];Name='ExampleApp';Publisher='ExampleVendor';Version=$pair[2];InstallPath=$pair[1];PathSource='InstallLocation';PathExists=$false;Scope='Machine';Kind='Desktop'}})
$merged=@(Merge-LSProgramEntries $entries)
Assert ($merged.Count -eq 3) 'Do not merge programs with different paths or versions.'
Assert (@($merged | Where-Object {$_.RegistrationIds.Count -eq 2}).Count -eq 1) 'Preserve duplicate registration evidence.'
$inventory=[pscustomobject]@{Records=@([pscustomobject]@{Kind='Service';Id='ExampleSvc';Name='ExampleApp';Reference='C:\Example\agent.exe';State='Stopped';Detail=''})}
$matches=@(Find-LSAssociations -Inventory $inventory -Names ExampleApp)
Assert ($matches.Count -eq 1 -and $matches[0].Evidence -eq 'Name') 'Unknown directories must not invent path evidence.'
'PASS: discovery safety boundaries, executable path inference, registration identity and unknown paths.'
