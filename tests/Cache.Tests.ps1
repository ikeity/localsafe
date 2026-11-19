# SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\LocalSafe.Cache.psm1') -Force
function Assert($Condition,[string]$Message){if(!$Condition){throw $Message}}
function Program($Id,$Path,$Version='1.0') {[pscustomobject]@{Id=$Id;Name=$Id;InstallPath=$Path;Version=$Version;Publisher='ExampleVendor';Scope='CurrentUser';PathSource='InstallLocation'}}
$a=Program ExampleApp 'C:\ExampleVendor\ExampleApp'
$b=Program OtherApp 'C:\ExampleVendor\OtherApp'
$report=[pscustomobject]@{SchemaVersion=1;CapturedAt='2000-01-01T00:00:00+00:00';InventoryAt='2000-01-01T00:00:00+00:00';InstallPath=$a.InstallPath;Findings=@();Coverage=@()}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('LocalSafe-CacheTest-'+[guid]::NewGuid().ToString('N'))
try {
    Assert ($null -eq (Read-LSScanCache $a -Directory $temp)) 'Cache miss must not pretend a completed empty scan.'
    Write-LSScanCache $a $report -Directory $temp
    $saved=Read-LSScanCache $a -Directory $temp
    Assert ($saved.CapturedAt -eq $report.CapturedAt) 'Cache must preserve the actual observation time.'
    Assert ($null -eq (Read-LSScanCache (Program ExampleApp $a.InstallPath '2.0') -Directory $temp)) 'Updated versions must not reuse old results.'
    Assert ($null -eq (Read-LSScanCache (Program ExampleApp 'C:\OtherLocation\ExampleApp') -Directory $temp)) 'Changed locations must miss.'
    $report.CapturedAt='2000-01-02T00:00:00+00:00'
    Write-LSScanCache $a $report -Directory $temp
    Assert ((Read-LSScanCache $a -Directory $temp).CapturedAt -eq $report.CapturedAt) 'Explicit refresh must replace the previous result.'
    $cachePath=Join-Path $temp ((Get-LSScanCacheKey $a)+'.local.json')
    [IO.File]::WriteAllText($cachePath,'broken json')
    Assert ($null -eq (Read-LSScanCache $a -Directory $temp)) 'Damaged cache must trigger a miss.'
} finally {
    if(Test-Path -LiteralPath $temp){
        # Flat disposable test directory: remove only its generated files, then the empty directory.
        Get-ChildItem -LiteralPath $temp -File | ForEach-Object {Remove-Item -LiteralPath $_.FullName}
        Remove-Item -LiteralPath $temp
    }
}

# Exercise the actual selection flow without a desktop or a system scan.
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\src\LocalSafe.Gui.ps1'),[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) 'GUI must parse in Windows PowerShell.'
foreach($name in @('Get-ProgramCachedScan','Ensure-SelectedResult','Show-Program')) {
    $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    . ([scriptblock]::Create($function.Extent.Text))
}
$ui=@{}
foreach($name in @('AppName','AppMeta','AppPath','Save','Results','PathCount','ComponentCount','NameCount','ResultCount','ResultEmpty','Coverage','Status')){
    $ui[$name]=[pscustomobject]@{Text='';ToolTip='';IsEnabled=$true;ItemsSource=@();Visibility='Visible'}
}
$script:scanCache=@{};$script:cacheMisses=@{};$script:shownId='';$script:result=$null;$script:job=$null;$script:inventory=@{}
$script:started=0;$script:displayed=''
function Start-Worker {param($Mode,$Program) $script:started++;$script:job='background scan'}
function Set-Working {param($busy)}
function Show-Scan {param($Result,$Program,[switch]$FromCache) $script:displayed=$Program.Id;$script:shownId=$Program.Id;$script:result=$Result}
function Read-LSScanCache {param($Program) return $null}
$script:scanCache[(Get-LSScanCacheKey $a)]=$report
Show-Program $a
Assert ($script:started -eq 0 -and $script:displayed -eq $a.Id) 'Cached selection must display without scanning.'
Show-Program $b
Assert ($script:started -eq 1) 'Unscanned selection must request one scan.'
Show-Program $a
Assert ($script:started -eq 1 -and $script:displayed -eq $a.Id) 'Return to cached A while B scans must display A immediately.'
$script:job=$null
Ensure-SelectedResult
Assert ($script:started -eq 1 -and $script:displayed -eq $a.Id) 'Background completion must not rescan the selected cached app.'
'PASS: persistent cache, version/path invalidation, timestamps, atomic replacement, corruption and A/B/A selection.'
