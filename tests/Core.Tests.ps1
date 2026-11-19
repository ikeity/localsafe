# No external test framework required. All fixtures are fictional.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\LocalSafe.Core.psm1') -Force
function Assert($Condition,[string]$Message) {if(!$Condition){throw $Message}}
$root='C:\Program Files\ExampleVendor\ExampleApp'
Assert (Test-LSPathReference ('"'+$root+'\agent.exe" --service') $root) 'Quoted executable should match.'
Assert (Test-LSPathReference $root $root) 'Exact installation path should match.'
Assert (!(Test-LSPathReference ($root+'Other\agent.exe') $root)) 'Neighboring product must not match.'
Assert (!(Test-LSPathReference ('X:\prefix\'+$root) $root)) 'Embedded drive text must not match.'
Assert (!(Test-LSPathReference '' $root)) 'Hidden process paths must not match.'
function Record($Kind,$Id,$Name,$Reference,$State='Running') {
    [pscustomobject]@{Kind=$Kind;Id=$Id;Name=$Name;Reference=$Reference;State=$State;Detail=''}
}
$records=@(
    (Record Service svc 'Example service' ($root+'\agent.exe')),
    (Record Service other 'Other product' ($root+'Other\agent.exe')),
    (Record Driver examplebus 'ExampleBus' 'C:\Windows\System32\drivers\ExampleBus.sys'),
    (Record Process 10 'ExampleApp.exe' ''),
    (Record Process 11 'Unrelated.exe' '')
)
$snapshot=[pscustomobject]@{SchemaVersion=1;CapturedAt='2000-01-01T00:00:00Z';Records=$records;Coverage=@([pscustomobject]@{Source='Synthetic';Status='Complete'})}
$matches=@(Find-LSAssociations $snapshot $root @('ExampleApp') @('ExampleBus'))
Assert ($matches.Count -eq 4) 'Expected path, component and two name candidates (including the neighboring path).'
Assert (@($matches | Where-Object {$_.Evidence -eq 'Path'}).Count -eq 1) 'Path evidence count.'
Assert (@($matches | Where-Object {$_.Id -eq 'other' -and $_.Evidence -eq 'Name'}).Count -eq 1) 'A neighboring path can only be a weak name candidate.'
Assert (@($matches | Where-Object {$_.Evidence -eq 'Component'}).Count -eq 1) 'Component matches must remain distinct.'
$next=[pscustomobject]@{SchemaVersion=1;Records=@((Record Service svc 'Example service' ($root+'\agent.exe') Stopped),(Record Service new 'New service' 'C:\Example\new.exe'));Coverage=$snapshot.Coverage}
$diff=@(Compare-LSInventory $snapshot $next)
Assert (@($diff | Where-Object {$_.Change -eq 'Added'}).Count -eq 1) 'Addition missing.'
Assert (@($diff | Where-Object {$_.Change -eq 'Changed'}).Count -eq 1) 'State change missing.'
Assert (@($diff | Where-Object {$_.Change -eq 'Removed'}).Count -eq 4) 'Removals missing.'
Assert (@(Compare-LSInventory $snapshot $snapshot).Count -eq 0) 'Identical snapshots must produce no changes.'
$next.Coverage=@([pscustomobject]@{Source='Synthetic';Status='Failed'})
$rejected=$false
try {Compare-LSInventory $snapshot $next | Out-Null} catch {$rejected=$true}
Assert $rejected 'Incomplete snapshots must not imply removals.'
Write-Output 'PASS: path boundaries, evidence classification, snapshot changes, incomplete coverage guard.'
