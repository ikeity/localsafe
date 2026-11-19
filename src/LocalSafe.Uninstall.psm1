# SPDX-License-Identifier: GPL-3.0-only
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'LocalSafe.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'LocalSafe.Discovery.psm1')

function Get-LSUValue($Object,[string]$Name) {
    if($null -eq $Object){return $null}
    $p=$Object.PSObject.Properties[$Name];if($p){return $p.Value};return $null
}
function Get-LSRemovalAssessment {
    param($Session,$After,[string]$RegistrationState,[string]$DirectoryState,[string]$MainProgramState='Unknown')
    $ready=$true
    foreach($source in @('Services','Processes','Uninstall')){if(@($After.Coverage | Where-Object {$_.Source -eq $source -and $_.Status -eq 'Complete'}).Count -ne 1){$ready=$false}}
    $processes=@($After.Findings | Where-Object {$_.Kind -eq 'Process'}).Count
    $target=Get-LSUValue $Session 'Target'
    $exe=[string](Get-LSUValue $target 'FilePath')
    $isMsi=([IO.Path]::GetFileName($exe) -ieq 'msiexec.exe')
    $standard=($Session.ExitCode -in @(0,3010))
    $observed=($ready -and $RegistrationState -eq 'Missing' -and !$processes -and ($DirectoryState -eq 'Missing' -or $MainProgramState -eq 'Missing'))
    $finished=($Session.State -in @('UninstallExited','CleanupAttempted'))
    $byEvidence=($finished -and !$isMsi -and $observed)
    [pscustomobject]@{
        CanReviewCleanup=($finished -and ($standard -or $byEvidence))
        Code=$(if($standard -and $finished){'StandardExit'}elseif($byEvidence){'RemovedByEvidence'}else{'Unverified'})
        ExitCode=$Session.ExitCode;RegistrationState=$RegistrationState;DirectoryState=$DirectoryState;MainProgramState=$MainProgramState;RelatedProcesses=$processes;SourcesComplete=$ready
        Reason=$(if($byEvidence -and !$standard){'保留厂商退出码；已核验卸载登记消失、目录或主程序移除、未发现关联进程，允许逐项审核遗留'}elseif($standard -and $finished){'卸载程序已退出；每个遗留项仍需独立核验'}else{'卸载状态或关键证据尚不完整，暂不执行清理'})
    }
}
function Test-LSProductDataDirectory {
    param($Session,$Item,[object[]]$OtherPrograms=@())
    $path=[string]$Item.Reference
    if(!(Test-LSCleanupDirectory $path)){return $false}
    $root=[IO.Path]::GetFullPath($path).TrimEnd('\')
    $names=@([string]$Session.Program.Name,[IO.Path]::GetFileName([string]$Session.Program.InstallPath)) | Where-Object {$_.Length -ge 4 -and $_ -notin @('Application','Current','Client','Programs')}
    if($names -notcontains [IO.Path]::GetFileName($root)){return $false}
    $before=Get-LSUValue $Session 'Before'
    if(!$before -or !@(Get-LSUValue $before 'Findings' | Where-Object {$_.Kind -eq 'DataDirectory' -and $_.Reference -ieq $root}).Count){return $false}
    foreach($other in $OtherPrograms){
        if($other.Id -eq $Session.Program.Id){continue}
        if(($other.InstallPath -and ((Test-LSPathReference $root $other.InstallPath) -or (Test-LSPathReference $other.InstallPath $root))) -or $names -contains $other.Name){return $false}
    }
    $parent=[IO.Path]::GetDirectoryName($root)
    $vendor=[IO.Path]::GetFileName($parent)
    $normalize={param($value) ([string]$value -replace '[^\p{L}\p{Nd}]','').ToLowerInvariant()}
    $vendorKey=& $normalize $vendor
    $expected=@([IO.Path]::GetFileName([IO.Path]::GetDirectoryName([string]$Session.Program.InstallPath)),[string](Get-LSUValue $Session.Program 'Publisher')) | ForEach-Object {& $normalize $_} | Where-Object {$_.Length -ge 4}
    if($expected -notcontains $vendorKey){return $false}
    $dataRoot=[IO.Path]::GetDirectoryName($parent)
    return @(@($env:APPDATA,$env:LOCALAPPDATA,$env:ProgramData) | Where-Object {$_ -and $_.TrimEnd('\') -ieq $dataRoot}).Count -eq 1
}
function Test-LSAdministrator {
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-LSUHash([string]$Path) {
    $sha=[Security.Cryptography.SHA256]::Create();$stream=[IO.File]::OpenRead($Path)
    try {[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')}
    finally {$stream.Dispose();$sha.Dispose()}
}
function Split-LSUninstallCommand {
    param([Parameter(Mandatory)][string]$Command)
    $text=[Environment]::ExpandEnvironmentVariables($Command.Trim())
    $m=[regex]::Match($text,'^(?:"([^"\r\n]+\.exe)"|([^"\r\n]+?\.exe))(?=\s|$)\s*(.*)$','IgnoreCase')
    if(!$m.Success){throw '卸载入口不是可识别的 EXE 命令；不会通过命令解释器执行'}
    $exe=$m.Groups[1].Value;if(!$exe){$exe=$m.Groups[2].Value};$arguments=$m.Groups[3].Value
    if([IO.Path]::GetFileName($exe) -ieq 'msiexec.exe') {
        if([IO.Path]::IsPathRooted($exe) -and [IO.Path]::GetFullPath($exe) -ine (Join-Path $env:SystemRoot 'System32\msiexec.exe')){throw 'MSI 入口不在系统目录'}
        $product=[regex]::Match($arguments,'^/(?:i|x)\s*(\{[0-9a-f-]{36}\})\s*$','IgnoreCase')
        if(!$product.Success){throw '此 MSI 命令包含额外选项，需人工核对，未启动'}
        $exe=Join-Path $env:SystemRoot 'System32\msiexec.exe'
        $arguments='/x '+$product.Groups[1].Value+' /norestart'
    } else {
        if($exe -notmatch '^[A-Za-z]:\\'){throw '卸载程序必须是本机绝对路径'}
        if([IO.Path]::GetFileName($exe) -in @('cmd.exe','powershell.exe','pwsh.exe','wscript.exe','cscript.exe','rundll32.exe','regsvr32.exe','mshta.exe')){throw '脚本或通用解释器卸载入口需人工核对，未启动'}
    }
    [pscustomobject]@{FilePath=[IO.Path]::GetFullPath($exe);Arguments=$arguments}
}
function Get-LSOfficialUninstallTarget {
    param([Parameter(Mandatory)]$Program)
    if($Program.Kind -ne 'Desktop'){throw '当前仅支持有 Windows 卸载登记的桌面软件；商店应用请通过 Windows 设置卸载'}
    $ids=@(Get-LSUValue $Program 'RegistrationIds' | Where-Object {$_});if(!$ids.Count){$ids=@($Program.Id)}
    foreach($id in $ids) {
        if($id -notmatch '^HKEY_(?:LOCAL_MACHINE|CURRENT_USER)\\SOFTWARE\\(?:WOW6432Node\\)?Microsoft\\Windows\\CurrentVersion\\Uninstall\\[^\\]+$'){continue}
        $path='Registry::'+$id
        if(!(Test-Path -LiteralPath $path)){continue}
        $v=Get-ItemProperty -LiteralPath $path -ErrorAction Stop
        if([string](Get-LSUValue $v 'DisplayName') -cne [string]$Program.Name -or [string](Get-LSUValue $v 'DisplayVersion') -cne [string]$Program.Version){throw '安装登记已变化，请刷新软件列表后重试'}
        $command=[string](Get-LSUValue $v 'UninstallString')
        $target=Split-LSUninstallCommand $command
        if(!(Test-Path -LiteralPath $target.FilePath -PathType Leaf)){throw '已登记的卸载程序不存在'}
        [pscustomobject]@{RegistrationId=$id;FilePath=$target.FilePath;Arguments=$target.Arguments;Hash=(Get-LSUHash $target.FilePath);RegisteredCommand=$command}
        return
    }
    throw '没有找到仍有效的官方卸载入口'
}
function Save-LSUninstallSession {
    param([Parameter(Mandatory)]$Session)
    $path=Join-Path $Session.Folder 'session.local.json';$temp=Join-Path $Session.Folder 'session.tmp'
    $Session.UpdatedAt=[DateTimeOffset]::Now.ToString('o')
    $Session | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath $temp -Encoding UTF8 -ErrorAction Stop
    if(Test-Path -LiteralPath $path){[IO.File]::Replace($temp,$path,[NullString]::Value)}else{[IO.File]::Move($temp,$path)}
}
function New-LSUninstallSession {
    param([Parameter(Mandatory)]$Program,[string]$Directory=(Join-Path $env:LOCALAPPDATA 'LocalSafe\Private\Uninstall'))
    $target=Get-LSOfficialUninstallTarget $Program
    $before=Get-LSScan -InstallPath $Program.InstallPath -Names @($Program.Name) -AllowMissingPath
    $folder=Join-Path $Directory ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
    $session=[pscustomobject]@{SchemaVersion=1;Folder=$folder;Program=$Program;Target=$target;Before=$before;After=$null;State='Prepared';ExitCode=$null;Error='';UpdatedAt='';Review=$null;Operations=@()}
    Save-LSUninstallSession $session
    return $session
}
function Get-LSLastUninstallSession {
    param([string]$Directory=(Join-Path $env:LOCALAPPDATA 'LocalSafe\Private\Uninstall'))
    if(!(Test-Path -LiteralPath $Directory)){return $null}
    $files=@(Get-ChildItem -LiteralPath $Directory -Filter 'session.local.json' -Recurse -File | Sort-Object LastWriteTime -Descending)
    foreach($file in $files){try{$s=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json;if($s.SchemaVersion -eq 1 -and $s.Program -and $s.Folder -eq $file.DirectoryName){return $s}}catch{continue}}
    return $null
}
function Invoke-LSOfficialUninstall {
    param([Parameter(Mandatory)]$Session,[switch]$Confirmed)
    if(!$Confirmed -or $Session.State -ne 'Prepared'){throw '必须先确认本次卸载命令；不能重放已启动的卸载'}
    $current=Get-LSOfficialUninstallTarget $Session.Program
    foreach($field in @('RegistrationId','FilePath','Arguments','Hash')){if($current.$field -cne $Session.Target.$field){throw '卸载入口已变化，需要重新准备并确认'}}
    $Session.State='UninstallRunning';Save-LSUninstallSession $Session
    try {
        $options=@{FilePath=$current.FilePath;Wait=$true;PassThru=$true;ErrorAction='Stop'}
        if($current.Arguments){$options.ArgumentList=$current.Arguments}
        $process=Start-Process @options
        $Session.ExitCode=$process.ExitCode;$Session.State='UninstallExited'
    } catch {$Session.Error=$_.Exception.Message;$Session.State='LaunchFailed'}
    Save-LSUninstallSession $Session
    # An exit code never substitutes for a fresh examination of system registrations.
    Update-LSResidualReview $Session
}
function Test-LSCleanupDirectory {
    param([string]$Path)
    try {
        if($Path -notmatch '^[A-Za-z]:\\' -or $Path -match '[*?]'){return $false}
        $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
        $blocked=@([IO.Path]::GetPathRoot($full),$env:SystemRoot,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramData,$env:USERPROFILE,$env:LOCALAPPDATA,$env:APPDATA,($env:USERPROFILE+'\Documents'),($env:USERPROFILE+'\Desktop'),($env:USERPROFILE+'\Downloads'),($env:LOCALAPPDATA+'\Programs')) | Where-Object {$_} | ForEach-Object {$_.TrimEnd('\')}
        $blocked+=@(($env:ProgramFiles+'\WindowsApps'),($env:ProgramFiles+'\Common Files'))
        foreach($protected in $blocked){if($protected -ieq $full -or $protected.StartsWith($full+'\',[StringComparison]::OrdinalIgnoreCase)){return $false}}
        if($env:SystemRoot -and $full.StartsWith($env:SystemRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){return $false}
        if($env:ProgramFiles -and $full.StartsWith(($env:ProgramFiles+'\WindowsApps\'),[StringComparison]::OrdinalIgnoreCase)){return $false}
        foreach($runtimeRoot in @($env:CommonProgramFiles,${env:CommonProgramFiles(x86)}) | Where-Object {$_}){if($full -ieq $runtimeRoot -or $full.StartsWith($runtimeRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){return $false}}
        $part=$full
        while($part){
            if(Test-Path -LiteralPath $part){$item=Get-Item -LiteralPath $part -Force -ErrorAction Stop;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){return $false}}
            $parent=[IO.Path]::GetDirectoryName($part);if($parent -eq $part){break};$part=$parent
        }
        return $true
    }catch{return $false}
}
function Test-LSExecutableInside {
    param([string]$Command,[string]$Root)
    try {$parts=Split-LSUninstallCommand $Command;return (Test-LSPathReference $parts.FilePath $Root)}catch{return $false}
}
function Test-LSRegistryOwnership {
    param($Item,$Program)
    $key=[string](Get-LSUValue $Item 'OriginalId');if(!$key){$key=[string]$Item.Id}
    if($key -notmatch '^HKEY_(?:LOCAL_MACHINE|CURRENT_USER)\\SOFTWARE\\(?:WOW6432Node\\)?([^\\]+)\\([^\\]+)$'){return $false}
    $vendor=$Matches[1];$leaf=$Matches[2]
    if($vendor -in @('Microsoft','Policies','Classes') -or $leaf -in @('Windows','Windows NT','Classes','Policies')){return $false}
    $names=@([string]$Program.Name,[IO.Path]::GetFileName([string]$Program.InstallPath)) | Where-Object {$_.Length -ge 4 -and $_ -notin @('Application','Client','Current','Programs')}
    if($names -notcontains $leaf){return $false}
    try {
        $registry=Get-Item -LiteralPath ('Registry::'+$key) -ErrorAction Stop
        foreach($name in $registry.GetValueNames()){
            $value=$registry.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if($value -is [string] -and (Test-LSPathReference $value $Program.InstallPath)){return $true}
        }
    }catch{return $false}
    return $false
}
function Test-LSTaskOwnership {
    param($Item,[string]$Root)
    try {
        $tasks=@(Get-ScheduledTask -ErrorAction Stop | Where-Object {($_.TaskPath+$_.TaskName) -ceq $Item.OriginalId})
        if($tasks.Count -ne 1 -or !@($tasks[0].Actions).Count){return $false}
        foreach($action in $tasks[0].Actions){
            $execute=[string](Get-LSUValue $action 'Execute')
            if(!$execute -or !(Test-LSExecutableInside ('"'+$execute+'"') $Root)){return $false}
        }
        $expected=[string](Get-LSUValue $Item 'Reference')
        $actual=@($tasks[0].Actions | ForEach-Object {
            $parts=@($_.PSObject.Properties['Execute'],$_.PSObject.Properties['Arguments'],$_.PSObject.Properties['WorkingDirectory'])
            (@($parts | Where-Object {$null -ne $_} | ForEach-Object {$_.Value})) -join ' '
        }) -join ' | '
        if($expected -and $actual -cne $expected){return $false}
        return $true
    }catch{return $false}
}
function New-LSResidualPlan {
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)]$After,[object[]]$OtherPrograms=@(),[bool]$StillRegistered=$true,[bool]$CatalogComplete=$true,$RemovalAssessment=$null)
    $root=[string]$Session.Program.InstallPath
    $shared=$false
    foreach($other in $OtherPrograms){
        if($other.Id -eq $Session.Program.Id -or !$other.InstallPath -or !$root){continue}
        if((Test-LSPathReference $other.InstallPath $root) -or (Test-LSPathReference $root $other.InstallPath)){$shared=$true}
    }
    $liveProcess=@($After.Findings | Where-Object {$_.Kind -eq 'Process'}).Count -gt 0
    $required=@('Services','Processes','Uninstall','ScheduledTasks','Firewall')
    $incomplete=$false
    foreach($source in $required){$check=@($After.Coverage | Where-Object {$_.Source -eq $source -and $_.Status -eq 'Complete'});if($check.Count -ne 1){$incomplete=$true}}
    $exitReady=($Session.ExitCode -in @(0,3010))
    if($RemovalAssessment){$exitReady=[bool]$RemovalAssessment.CanReviewCleanup}
    $canProceed=(!$StillRegistered -and !$incomplete -and $CatalogComplete -and $Session.State -notin @('Prepared','UninstallRunning','LaunchFailed') -and $exitReady)
    $findings=@($After.Findings)
    if($root -and (Test-Path -LiteralPath $root -PathType Container)) {
        $findings+=@([pscustomobject]@{Kind='InstallDirectory';Name=[IO.Path]::GetFileName($root);Reference=$root;Evidence='Path';Reason='官方安装记录指定的目录在卸载后仍存在';State='Present';Detail='包括目录中的配置、日志和用户文件；采用同级重命名隔离，不永久删除';Id=$root})
    }
    foreach($r in $findings){
        $action='ReviewOnly';$allowed=$false;$why='关联不足以证明独占归属，仅展示待核对'
        if(!$canProceed){$why='卸载仍登记、退出未确认成功或关键扫描源不完整；本轮只展示，不执行清理'}
        elseif($shared){$why='安装路径与其他软件登记重叠，不自动处理共享位置'}
        elseif($Session.Program.PathSource -ne 'InstallLocation'){$why='目录来自推断而非明确安装登记，不据此清理系统组件'}
        elseif(!$root -or !(Test-LSCleanupDirectory $root)){$why='安装位置未知或属于受保护/重解析位置'}
        elseif($r.Kind -eq 'InstallDirectory' -and $Session.Program.PathSource -eq 'InstallLocation' -and !$liveProcess){$allowed=$true;$action='QuarantineDirectory';$why='安装登记目录仍存在，无已知相关进程；可同级隔离，保留文件与原权限'}
        elseif($r.Kind -eq 'Service' -and $r.Evidence -eq 'Path' -and $r.State -eq 'Stopped' -and (Test-LSExecutableInside $r.Reference $root)){$allowed=$true;$action='RemoveService';$why='已停止服务的执行文件直接指向该安装目录；导出登记后删除服务'}
        elseif($r.Kind -eq 'Firewall' -and $r.Evidence -eq 'Path' -and (Test-LSPathReference $r.Reference $root)){$allowed=$true;$action='RemoveFirewall';$why='规则的程序路径直接关联该安装目录；备份单条规则及筛选条件后移除'}
        elseif($r.Kind -eq 'Startup' -and $r.Evidence -eq 'Path' -and (Test-LSExecutableInside $r.Reference $root)){
            $allowed=([string]$r.Detail -match '^HK(?:LM|CU)\\SOFTWARE\\(?:WOW6432Node\\)?Microsoft\\Windows\\CurrentVersion\\Run$')
            if($allowed){$action='RemoveStartup';$why='Run 值直接启动该目录下的程序；备份该单值后移除'}
        }
        elseif($r.Kind -eq 'Task' -and $r.Evidence -eq 'Path'){
            $probe=[pscustomobject]@{OriginalId=$r.Id;Reference=$r.Reference}
            if(Test-LSTaskOwnership $probe $root){$allowed=$true;$action='RemoveTask';$why='任务的每个执行动作都直接指向此安装目录；导出任务 XML 后移除'}
        }
        elseif($r.Kind -eq 'RegistryKey' -and (Test-LSRegistryOwnership $r $Session.Program)){$allowed=$true;$action='RemoveRegistryKey';$why='产品键名称精确匹配，且顶层值明确引用此安装目录；导出该键后移除'}
        elseif($r.Kind -eq 'DataDirectory' -and !$liveProcess -and (Test-LSProductDataDirectory $Session $r $OtherPrograms)){$allowed=$true;$action='QuarantineDataDirectory';$why='产品名精确、厂商目录一致、位于标准数据位置，且卸载前已有记录；同级隔离保留配置、历史和用户数据'}
        elseif($r.Kind -in @('Driver','Device')){$why='可能为共享驱动或设备，需要独立验证驱动包依赖；本版本不自动卸载驱动'}
        elseif($r.Kind -eq 'Process' -or ($r.Kind -eq 'Service' -and $r.State -ne 'Stopped')){$why='组件仍在运行；本版本不强制结束进程或停止服务'}
        elseif($r.Kind -eq 'BundledFile'){$why='随附文件由安装目录隔离项统一处理，避免重复操作'}
        $admin=($action -in @('RemoveService','RemoveFirewall','RemoveTask') -or ($action -eq 'RemoveRegistryKey' -and $r.Id -like 'HKEY_LOCAL_MACHINE\*') -or ($action -eq 'RemoveStartup' -and $r.Detail -like 'HKLM\*'))
        if($action -in @('QuarantineDirectory','QuarantineDataDirectory')){foreach($protectedRoot in @($env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramData) | Where-Object {$_}){if(Test-LSPathReference $r.Reference $protectedRoot){$admin=$true}}}
        $hold='OwnershipUnverified'
        if(!$canProceed){$hold='UninstallUnverified'}
        elseif($shared){$hold='SharedLocation'}
        elseif($Session.Program.PathSource -ne 'InstallLocation'){$hold='InferredLocation'}
        elseif(!$root -or !(Test-LSCleanupDirectory $root)){$hold='ProtectedLocation'}
        elseif($r.Kind -in @('Driver','Device')){$hold='DriverReview'}
        elseif($r.Kind -eq 'Process' -or ($r.Kind -eq 'Service' -and $r.State -ne 'Stopped')){$hold='RunningComponent'}
        elseif($r.Kind -eq 'BundledFile'){$hold='BundledFile'}
        if($allowed){$hold=''}
        [pscustomobject]@{Id=($r.Kind+'|'+$r.Id);Kind=$r.Kind;Name=$r.Name;Reference=$r.Reference;Evidence=$(if($action -eq 'RemoveRegistryKey'){'RegistryPath'}elseif($action -eq 'QuarantineDataDirectory'){'ProductLocation'}else{$r.Evidence});State=$r.State;Detail=$r.Detail;OriginalId=$r.Id;Action=$action;CanClean=$allowed;HoldReason=$hold;RequiresElevation=$admin;Selected=$false;Reason=($r.Reason+'；'+$why+$(if($admin){'；需要管理员权限'}))}
    }
}
function Update-LSResidualReview {
    param([Parameter(Mandatory)]$Session)
    $inventory=Get-LSInventory
    $after=Get-LSScan -InstallPath $Session.Program.InstallPath -Names @($Session.Program.Name) -Inventory $inventory -AllowMissingPath
    # Keep earlier component evidence even when the vendor removed its SYS/INF bundles.
    $seen=@{};foreach($r in $after.Findings){$seen[$r.Kind+'|'+$r.Id]=$true}
    foreach($old in $Session.Before.Findings){
        if($old.Kind -notin @('Service','Driver','Device','Task','Firewall','Startup','Process')){continue}
        foreach($current in @($inventory.Records | Where-Object {$_.Kind -eq $old.Kind -and $_.Id -eq $old.Id -and $_.Reference -ceq $old.Reference})){
            $key=$current.Kind+'|'+$current.Id
            if(!$seen.ContainsKey($key)){$after.Findings+=@([pscustomobject]@{Kind=$current.Kind;Id=$current.Id;Name=$current.Name;Reference=$current.Reference;State=$current.State;Detail=$current.Detail;Evidence=$old.Evidence;Reason=('卸载前有此关联，卸载后同一系统登记和指向仍存在；'+$old.Reason)});$seen[$key]=$true}
        }
    }
    $catalog=Get-LSInstalledPrograms
    $ids=@(Get-LSUValue $Session.Program 'RegistrationIds' | Where-Object {$_});if(!$ids.Count){$ids=@($Session.Program.Id)}
    $registered=$false;$registrationUnknown=$false
    foreach($id in $ids){
        try{[void](Get-Item -LiteralPath ('Registry::'+$id) -ErrorAction Stop);$registered=$true}
        catch{if($_.CategoryInfo.Category -ne 'ObjectNotFound'){$registrationUnknown=$true}}
    }
    $still=($registered -or $registrationUnknown)
    $directoryState='Unknown'
    if($Session.Program.InstallPath){
        try{[void](Get-Item -LiteralPath $Session.Program.InstallPath -ErrorAction Stop);$directoryState='Present'}
        catch{if($_.CategoryInfo.Category -eq 'ObjectNotFound'){$directoryState='Missing'}}
    }
    if($Session.State -eq 'UninstallRunning'){$Session.State='Interrupted';$Session.Error='上次监控未完成；不推断卸载成功，仅重新检查'}
    $Session.After=$after
    $catalogComplete=@($catalog.Coverage | Where-Object {$_.Source -ne 'StartMenuNames' -and $_.Status -ne 'Complete'}).Count -eq 0
    $quarantine=@($Session.Operations | Where-Object {$_.Status -eq 'Quarantined' -and $_.Quarantine -and (Test-Path -LiteralPath $_.Quarantine -PathType Container)} | Select-Object -ExpandProperty Quarantine -Unique)
    # Only exact destinations of completed, still-present quarantines are backups.
    # Never hide a directory merely because its name resembles our recovery suffix.
    $after.Findings=@($after.Findings | Where-Object {$_.Kind -ne 'DataDirectory' -or $quarantine -notcontains [string]$_.Reference})
    $registrationState=$(if($registrationUnknown){'Unknown'}elseif($registered){'Present'}else{'Missing'})
    $assessment=Get-LSRemovalAssessment $Session $after $registrationState $directoryState
    $Session.Review=[pscustomobject]@{CapturedAt=[DateTimeOffset]::Now.ToString('o');StillRegistered=$still;RegistrationState=$registrationState;InstallDirectoryState=$directoryState;RemovalAssessment=$assessment;QuarantinePresent=$quarantine;CatalogCoverage=$catalog.Coverage;Items=@(New-LSResidualPlan -Session $Session -After $after -OtherPrograms $catalog.Programs -StillRegistered $still -CatalogComplete $catalogComplete -RemovalAssessment $assessment)}
    $Session | Add-Member -NotePropertyName Verdict -NotePropertyValue (Get-LSResidualVerdict $Session) -Force
    Save-LSUninstallSession $Session
    return $Session
}
function Get-LSResidualVerdict {
    param([Parameter(Mandatory)]$Session)
    $review=Get-LSUValue $Session 'Review'
    $assessment=Get-LSUValue $review 'RemovalAssessment'
    $evidenceReady=($assessment -and $assessment.Code -eq 'RemovedByEvidence')
    if(!$review -or $Session.State -eq 'Prepared'){
        return [pscustomobject]@{Code='NotChecked';Title='尚未完成卸载后检查';Summary='当前清单不能用于判断残留是否已清理';Color='#697176';Remaining=0;Direct=0;Candidates=0;Eligible=0;Failures=0;Incomplete=0;Quarantined=0;CheckedAt=''}
    }
    $items=@($review.Items | Where-Object {$_})
    $direct=@($items | Where-Object {$_.Evidence -in @('Path','RegistryPath','ProductLocation')}).Count
    $eligible=@($items | Where-Object {$_.CanClean}).Count
    $directoryState=[string](Get-LSUValue $review 'InstallDirectoryState')
    $issues=@($Session.After.Coverage | Where-Object {$_.Status -ne 'Complete' -and !($_.Source -eq 'InstallationFiles' -and $_.Status -eq 'Unavailable' -and $directoryState -eq 'Missing')})
    $required=@('Services','Drivers','Processes','Startup','Uninstall','ScheduledTasks','Firewall','Devices','InstallationFiles','DataDirectories','RegistryNames')
    $missing=@($required | Where-Object {$source=$_;!@($Session.After.Coverage | Where-Object {$_.Source -eq $source}).Count})
    $catalog=@(Get-LSUValue $review 'CatalogCoverage' | Where-Object {$_})
    $catalogIssues=@($catalog | Where-Object {$_.Status -ne 'Complete' -and $_.Source -ne 'StartMenuNames'})
    $incomplete=$issues.Count+$missing.Count+$catalogIssues.Count
    if(!$catalog.Count){$incomplete++}
    $latest=@($Session.Operations | Group-Object Id | ForEach-Object {$_.Group[-1]})
    $failures=@($latest | Where-Object {$_.Status -in @('Failed','Prepared')}).Count
    $quarantined=@(Get-LSUValue $review 'QuarantinePresent' | Where-Object {$_}).Count
    $code='Remaining';$title='发现遗留，尚未清理干净';$color='#8A571C'
    if($review.StillRegistered){$code='UninstallUnverified';$title='尚未确认卸载完成'}
    elseif($items.Count -gt 0){$title=$(if(!$direct){'仍有待核对项，尚不能确认清理完成'}elseif($directoryState -eq 'Missing'){'主体目录已移除，仍有遗留及待核对项'}else{'发现遗留，尚未清理干净'})}
    elseif($failures){$code='OperationFailed';$title='部分操作未完成，需要核对'}
    elseif($incomplete){$code='Incomplete';$title='未发现已知遗留，检查尚不完整'}
    elseif($Session.ExitCode -notin @(0,3010) -and !$evidenceReady){$code='ExitUnverified';$title='未发现已知遗留，卸载退出状态待核实'}
    elseif($quarantined){$code='Quarantined';$title='原位置已清理，隔离文件仍保留';$color='#17635B'}
    else{$code='ClearWithinScope';$title='本次检查范围内未发现遗留';$color='#17635B'}
    $summary=('{0} 项明确关联 · {1} 项待核对 · {2} 项可选择处理' -f $direct,($items.Count-$direct),$eligible)
    $summary+=' · '+$incomplete+' 处覆盖不完整'
    if($failures){$summary+=' · '+$failures+' 项操作失败或未验证'}
    if($quarantined){$summary+=' · '+$quarantined+' 个隔离目录未永久删除'}
    if($Session.ExitCode -notin @(0,3010)){$summary+="`r`n卸载程序返回 "+[string]$Session.ExitCode+$(if($evidenceReady){'；登记及主体目录已移除、未发现关联进程，现按证据逐项审核'}else{'，其含义尚未核实，暂未开放清理'})}
    if(!@($Session.Operations).Count){$summary+="`r`nLocalSafe 尚未执行清理操作"}
    [pscustomobject]@{Code=$code;Title=$title;Summary=$summary;Color=$color;Remaining=$items.Count;Direct=$direct;Candidates=($items.Count-$direct);Eligible=$eligible;Failures=$failures;Incomplete=$incomplete;Quarantined=$quarantined;CheckedAt=$review.CapturedAt}
}
function Get-LSStartupBinding {
    param($Item)
    if($Item.Detail -notmatch '^(HKLM|HKCU)\\(SOFTWARE\\(?:WOW6432Node\\)?Microsoft\\Windows\\CurrentVersion\\Run)$'){throw '启动值不在允许的 Run 位置'}
    $hive=$Matches[1];$subkey=$Matches[2]
    $base=$(if($hive -eq 'HKLM'){[Microsoft.Win32.Registry]::LocalMachine}else{[Microsoft.Win32.Registry]::CurrentUser})
    $key=$base.OpenSubKey($subkey,$false)
    if(!$key){throw '启动位置已不存在'}
    try {if($key.GetValueNames() -notcontains $Item.Name){throw '启动值已不存在'};$value=[string]$key.GetValue($Item.Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);$type=[string]$key.GetValueKind($Item.Name)}finally{$key.Dispose()}
    [pscustomobject]@{Hive=$hive;Subkey=$subkey;Name=$Item.Name;Value=$value;Kind=$type}
}
function Invoke-LSResidualCleanup {
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)][string[]]$SelectedIds,[switch]$Confirmed)
    if(!$Confirmed -or !$SelectedIds.Count){throw '必须确认具体的清理项'}
    $approved=@($Session.Review.Items | Where-Object {$SelectedIds -contains $_.Id})
    if($approved.Count -ne @($SelectedIds | Sort-Object -Unique).Count -or @($approved | Where-Object {!$_.CanClean}).Count){throw '所选项不属于已展示且允许执行的计划'}
    if(@($approved | Where-Object {Get-LSUValue $_ 'RequiresElevation'}).Count -and !(Test-LSAdministrator)){throw '所选项需要管理员权限，请使用“以管理员身份继续”后重新检查并确认'}
    $fresh=Update-LSResidualReview $Session
    foreach($item in $approved){
        $current=@($fresh.Review.Items | Where-Object {$_.Id -eq $item.Id -and $_.CanClean -and $_.Action -eq $item.Action -and $_.Reference -ceq $item.Reference -and $_.State -ceq $item.State -and $_.Detail -ceq $item.Detail})
        if($current.Count -ne 1){throw ('目标或归属已变化，请重新确认：'+$item.Name)}
    }
    $backup=Join-Path $Session.Folder ('backup-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $backup -ErrorAction Stop | Out-Null
    # Prepare each backup before mutation. No batch is reported as all-or-nothing.
    foreach($item in $approved | Sort-Object @{Expression={if($_.Action -in @('QuarantineDirectory','QuarantineDataDirectory')){1}else{0}}}) {
        $op=[pscustomobject]@{Id=$item.Id;Action=$item.Action;Target=$item.Reference;Status='Prepared';Error='';Backup='';Quarantine='';At=[DateTimeOffset]::Now.ToString('o')}
        $Session.Operations+=@($op);Save-LSUninstallSession $Session
        try {
            $base=Join-Path $backup ([guid]::NewGuid().ToString('N'))
            switch($item.Action){
                {$_ -in @('QuarantineDirectory','QuarantineDataDirectory')}{
                    $source=[IO.Path]::GetFullPath($item.Reference).TrimEnd('\')
                    if(!(Test-LSCleanupDirectory $source)){throw '目录边界检查失败'}
                    if($item.Action -eq 'QuarantineDirectory' -and $source -ine [IO.Path]::GetFullPath($Session.Program.InstallPath).TrimEnd('\')){throw '安装目录边界检查失败'}
                    if($item.Action -eq 'QuarantineDataDirectory' -and !(Test-LSProductDataDirectory $Session $item)){throw '数据目录归属检查失败'}
                    $destination=Join-Path ([IO.Path]::GetDirectoryName($source)) ('.'+[IO.Path]::GetFileName($source)+'.localsafe-recovery-'+[guid]::NewGuid().ToString('N'))
                    if([IO.Path]::GetDirectoryName($destination) -ine [IO.Path]::GetDirectoryName($source) -or (Test-Path -LiteralPath $destination)){throw '隔离目标检查失败'}
                    $op.Quarantine=$destination;Save-LSUninstallSession $Session
                    [IO.Directory]::Move($source,$destination)
                    $op.Status='Quarantined'
                }
                'RemoveStartup'{
                    $binding=Get-LSStartupBinding $item
                    if($binding.Value -cne $item.Reference){throw '启动命令已变化'}
                    $op.Backup=$base+'.clixml';$binding | Export-Clixml -LiteralPath $op.Backup -ErrorAction Stop
                    Save-LSUninstallSession $Session
                    $hive=$(if($binding.Hive -eq 'HKLM'){[Microsoft.Win32.Registry]::LocalMachine}else{[Microsoft.Win32.Registry]::CurrentUser})
                    $key=$hive.OpenSubKey($binding.Subkey,$true);if(!$key){throw '无法写入启动位置'}
                    try {if([string]$key.GetValue($binding.Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -cne $binding.Value){throw '启动值已变化'};$key.DeleteValue($binding.Name,$true)}finally{$key.Dispose()}
                    $op.Status='Removed'
                }
                'RemoveService'{
                    $svc=Get-CimInstance Win32_Service -Filter ("Name='"+$item.OriginalId.Replace("'","''")+"'") -ErrorAction Stop
                    if(!$svc -or $svc.State -ne 'Stopped' -or $svc.PathName -cne $item.Reference){throw '服务状态或路径已变化'}
                    $op.Backup=$base+'.reg'
                    & "$env:SystemRoot\System32\reg.exe" export ('HKLM\SYSTEM\CurrentControlSet\Services\'+$svc.Name) $op.Backup /y | Out-Null
                    if($LASTEXITCODE -ne 0){throw '服务登记备份失败'}
                    Save-LSUninstallSession $Session
                    & "$env:SystemRoot\System32\sc.exe" delete $svc.Name | Out-Null
                    if($LASTEXITCODE -ne 0){throw '服务删除失败（可能需要管理员权限）'}
                    $op.Status='DeleteRequested'
                }
                'RemoveFirewall'{
                    $rules=@(Get-NetFirewallRule -ErrorAction Stop | Where-Object {$_.Name -ceq $item.OriginalId})
                    if($rules.Count -ne 1){throw '防火墙规则身份不唯一或已变化'}
                    $rule=$rules[0];$app=$rule | Get-NetFirewallApplicationFilter -ErrorAction Stop
                    if($app.Program -cne $item.Reference -or [string]$rule.Enabled -cne [string]$item.State -or ([string]$rule.Direction+' / '+[string]$rule.Action) -cne $item.Detail){throw '防火墙规则已变化'}
                    $op.Backup=$base+'.clixml'
                    [pscustomobject]@{Rule=$rule;Application=$app;Address=($rule|Get-NetFirewallAddressFilter);Port=($rule|Get-NetFirewallPortFilter);Service=($rule|Get-NetFirewallServiceFilter);Interface=($rule|Get-NetFirewallInterfaceFilter);InterfaceType=($rule|Get-NetFirewallInterfaceTypeFilter);Security=($rule|Get-NetFirewallSecurityFilter)} | Export-Clixml -LiteralPath $op.Backup -ErrorAction Stop
                    Save-LSUninstallSession $Session
                    $rule | Remove-NetFirewallRule -ErrorAction Stop
                    $op.Status='Removed'
                }
                'RemoveTask'{
                    if(!(Test-LSTaskOwnership $item $Session.Program.InstallPath)){throw '任务动作或归属已变化'}
                    $task=@(Get-ScheduledTask -ErrorAction Stop | Where-Object {($_.TaskPath+$_.TaskName) -ceq $item.OriginalId})[0]
                    $op.Backup=$base+'.xml';Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop | Set-Content -LiteralPath $op.Backup -Encoding UTF8 -ErrorAction Stop
                    Save-LSUninstallSession $Session
                    $task | Unregister-ScheduledTask -Confirm:$false -ErrorAction Stop
                    $op.Status='Removed'
                }
                'RemoveRegistryKey'{
                    if(!(Test-LSRegistryOwnership $item $Session.Program)){throw '注册表键归属已变化'}
                    $op.Backup=$base+'.reg'
                    & "$env:SystemRoot\System32\reg.exe" export $item.OriginalId $op.Backup /y | Out-Null
                    if($LASTEXITCODE -ne 0){throw '注册表备份失败'}
                    Save-LSUninstallSession $Session
                    if(!(Test-LSRegistryOwnership $item $Session.Program)){throw '注册表键归属已变化'}
                    $match=[regex]::Match($item.OriginalId,'^HKEY_(LOCAL_MACHINE|CURRENT_USER)\\(.+)\\([^\\]+)$')
                    $hive=$(if($match.Groups[1].Value -eq 'LOCAL_MACHINE'){[Microsoft.Win32.Registry]::LocalMachine}else{[Microsoft.Win32.Registry]::CurrentUser})
                    $parent=$hive.OpenSubKey($match.Groups[2].Value,$true);if(!$parent){throw '注册表父位置不可写'}
                    try{$parent.DeleteSubKeyTree($match.Groups[3].Value,$true)}finally{$parent.Dispose()}
                    $op.Status='Removed'
                }
                default{throw '该类型没有清理执行器'}
            }
        }catch{$op.Status='Failed';$op.Error=$_.Exception.Message}
        Save-LSUninstallSession $Session
    }
    $Session.State='CleanupAttempted';Save-LSUninstallSession $Session
    Update-LSResidualReview $Session
}

Export-ModuleMember -Function Split-LSUninstallCommand,Get-LSOfficialUninstallTarget,New-LSUninstallSession,Invoke-LSOfficialUninstall,Update-LSResidualReview,Get-LSResidualVerdict,New-LSResidualPlan,Invoke-LSResidualCleanup,Get-LSLastUninstallSession,Test-LSCleanupDirectory
