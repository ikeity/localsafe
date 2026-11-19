# SPDX-License-Identifier: GPL-3.0-only
param([switch]$ShowLastUninstall)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
Import-Module (Join-Path $PSScriptRoot 'LocalSafe.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'LocalSafe.Discovery.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'LocalSafe.Cache.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'LocalSafe.Uninstall.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'LocalSafe.UninstallUi.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'LocalSafe.Media.psm1') -Force
[xml]$xaml=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'LocalSafe.Window.xaml') -Raw -Encoding UTF8
$window=[Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$icons=New-LSIconResources
$window.Resources.MergedDictionaries.Add($icons)
$window.Icon=[Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new((Join-Path $PSScriptRoot 'assets\LocalSafe.png')))
$window.Add_SourceInitialized({
    if('LocalSafeInstance' -as [type]){
        $handle=[Windows.Interop.WindowInteropHelper]::new($window).Handle
        $script:activationHook=[Windows.Interop.HwndSourceHook]{
            param($hwnd,$message,$wparam,$lparam,[ref]$handled)
            if($message -eq [LocalSafeInstance]::ActivationMessage){[LocalSafeInstance]::ActivateWindow($hwnd);$handled.Value=$true}
            return [IntPtr]::Zero
        }
        [Windows.Interop.HwndSource]::FromHwnd($handle).AddHook($script:activationHook)
        [LocalSafeInstance]::AttachMainWindow($handle)
    }
})
$ui=@{}
foreach($name in @('Refresh','Search','SearchHint','Programs','ListEmpty','CatalogStatus','Save','Tools','Snapshot','Compare','Browse','Uninstall','LastUninstall','AppIcon','AppName','AppMeta','AppPath','Rescan','PathCount','ComponentCount','NameCount','Tabs','ResultCount','KindFilter','Results','ResultEmpty','EvidencePanel','EvidenceText','Coverage','Progress','Status')) {$ui[$name]=$window.FindName($name)}
foreach($item in $ui.Tools.ContextMenu.Items) {if($item.Name){$ui[$item.Name]=$item}}
$script:catalog=$null; $script:inventory=$null; $script:programs=@(); $script:rows=@(); $script:result=$null
$script:scanCache=@{}; $script:cacheMisses=@{}; $script:activeProgram=$null; $script:refreshTarget=$null
$script:job=$null; $script:operation=''; $script:resultLabel='scan'; $script:selected=$null; $script:activeId=''; $script:shownId=''; $script:suspendSelection=$false
$kindLabels=@{Service='服务';Driver='系统驱动';Device='设备';Startup='启动项';Task='计划任务';Firewall='防火墙';Process='进程';Uninstall='卸载记录';RegistryKey='注册表';BundledFile='随附文件';DataDirectory='数据目录'}
$evidenceLabels=@{Path='路径关联';Component='组件匹配';Name='名称候选';Added='新增';Removed='移除';Changed='变更'}
$stateLabels=@{Running='运行中';Stopped='已停止';Registered='已登记';Present='存在';True='已启用';False='已禁用';Ready='就绪';Disabled='已禁用'}
$kindIcons=@{Service='settings';Driver='cpu';Device='monitor';Startup='power';Task='calendar-clock';Firewall='shield';Process='layers';Uninstall='package';RegistryKey='database';BundledFile='file';DataDirectory='folder'}
function Set-Working([bool]$busy) {
    $ui.Progress.Visibility=$(if($busy){'Visible'}else{'Hidden'})
    foreach($name in @('Refresh','Snapshot','Compare','Browse','LastUninstall')) {$ui[$name].IsEnabled=!$busy}
    $desktop=($script:selected -and $script:selected.PSObject.Properties['Kind'] -and $script:selected.Kind -eq 'Desktop')
    $ui.Uninstall.IsEnabled=(!$busy -and $desktop)
    $ui.Rescan.IsEnabled=(!$busy -and $null -ne $script:selected)
    $ui.Save.IsEnabled=(!$busy -and $null -ne $script:result)
}
function Start-Worker([string]$Mode,$Program=$null,[string]$Before='', [string]$After='') {
    Set-Working $true
    $script:operation=$Mode
    if($Program){$script:activeId=$Program.Id;$script:activeProgram=$Program}
    $script:job=Start-Job -ScriptBlock {
        param($Folder,$Mode,$Program,$Inventory,$Before,$After)
        $ErrorActionPreference='Stop'
        Import-Module (Join-Path $Folder 'LocalSafe.Core.psm1') -Force
        Import-Module (Join-Path $Folder 'LocalSafe.Discovery.psm1') -Force
        switch($Mode) {
            'Discover' {Get-LSInstalledPrograms}
            'Inventory' {Get-LSInventory}
            'Scan' {
                $names=@($Program.Name)
                if($Program.InstallPath){
                    $leaf=[IO.Path]::GetFileName($Program.InstallPath.TrimEnd('\'))
                    if($leaf -notin @('Application','app','bin','x64','x86','Current','Programs','Client','Uninstall','Installer','WindowsApps')){$names+=@($leaf)}
                }
                Get-LSScan -InstallPath $Program.InstallPath -Names ($names | Sort-Object -Unique) -Inventory $Inventory -AllowMissingPath
            }
            'Snapshot' {Get-LSInventory}
            'Compare' {
                $b=Get-Content -LiteralPath $Before -Raw | ConvertFrom-Json
                $a=Get-Content -LiteralPath $After -Raw | ConvertFrom-Json
                [pscustomobject]@{SchemaVersion=1;BeforeAt=$b.CapturedAt;AfterAt=$a.CapturedAt;Changes=@(Compare-LSInventory -Before $b -After $a);Limitations=@('快照比较仅覆盖系统登记记录，不包括所有文件和注册表写入。','变化只表示时间上的关联，不能证明由某个安装程序造成。')}
            }
        }
    } -ArgumentList $PSScriptRoot,$Mode,(ConvertTo-LSProgramRecord $Program),$script:inventory,$Before,$After
}
function Update-ProgramList {
    $query=$ui.Search.Text.Trim()
    $filtered=@($script:programs | Where-Object {!$query -or ($_.Name+' '+$_.Publisher).IndexOf($query,[StringComparison]::OrdinalIgnoreCase) -ge 0})
    $script:suspendSelection=$true
    $previous=$script:selected
    $ui.Programs.ItemsSource=$filtered
    $script:suspendSelection=$false
    $ui.ListEmpty.Text=$(if($query){'没有匹配的软件'}else{'未发现已登记的软件'})
    $ui.ListEmpty.Visibility=$(if($filtered.Count){'Collapsed'}else{'Visible'})
    $ui.CatalogStatus.Text=('{0} 款软件' -f $script:programs.Count)+$(if($query){' · 筛选出 '+$filtered.Count+' 款'}else{''})
    if($filtered.Count) {
        $retain=@($filtered | Where-Object {$previous -and $_.Id -eq $previous.Id})
        if($retain.Count){$ui.Programs.SelectedItem=$retain[0]}else{$ui.Programs.SelectedIndex=0}
    }
}
function Update-Results {
    $tag=[string]$ui.KindFilter.SelectedItem.Tag
    $visible=@($script:rows | Where-Object {
        $tag -eq 'All' -or $_.Kind -eq $tag -or
        ($tag -eq 'Drivers' -and $_.Kind -in @('Driver','Device')) -or
        ($tag -eq 'StartupTasks' -and $_.Kind -in @('Startup','Task')) -or
        ($tag -eq 'Registry' -and $_.Kind -in @('RegistryKey','Uninstall')) -or
        ($tag -eq 'Files' -and $_.Kind -in @('BundledFile','DataDirectory'))
    })
    $ui.Results.ItemsSource=$visible
    $ui.ResultCount.Text=('{0} 项记录' -f $visible.Count)
    $ui.ResultEmpty.Text='本次检查未发现匹配项'
    $ui.ResultEmpty.Visibility=$(if($visible.Count){'Collapsed'}else{'Visible'})
}
function Show-Program($Program) {
    $script:selected=$Program
    if($ui.ContainsKey('AppIcon')){
        $image=$Program.PSObject.Properties['IconSource']
        $ui.AppIcon.Source=$(if($image -and $image.Value){$image.Value}else{$icons['Icon.package.Default']})
    }
    $ui.AppName.Text=$Program.Name
    $publisher=$Program.Publisher;if($publisher -match '^[0-9a-f-]{36}$'){$publisher=''}
    $ui.AppMeta.Text=(@($publisher,$Program.Version) | Where-Object {$_}) -join ' · '
    if(!$ui.AppMeta.Text){$ui.AppMeta.Text='无发布者或版本记录'}
    $source=@{InstallLocation='安装记录';DisplayIcon='由图标路径推断';UninstallString='由卸载路径推断';PackageLocation='应用包记录';Manual='手动目录';Unknown='目录未知'}
    $ui.AppPath.Text=$(if($Program.InstallPath){$Program.InstallPath+$(if($Program.PathSource -in @('DisplayIcon','UninstallString')){' · 推断位置'})}else{'未记录安装目录'})
    $ui.AppPath.ToolTip=$ui.AppPath.Text+' · '+$source[$Program.PathSource]
    if($script:shownId -eq $Program.Id -and $script:result){return}
    $cached=Get-ProgramCachedScan $Program
    if($null -ne $cached){Show-Scan -Result $cached -Program $Program -FromCache;Set-Working ($null -ne $script:job);return}
    $script:result=$null; $script:rows=@(); $ui.Results.ItemsSource=@(); $ui.Save.IsEnabled=$false
    $ui.PathCount.Text='—';$ui.ComponentCount.Text='—';$ui.NameCount.Text='—';$ui.ResultCount.Text='正在检查'
    $ui.ResultEmpty.Text='正在检查 '+$Program.Name+'…';$ui.ResultEmpty.Visibility='Visible'
    $ui.Coverage.Text='正在检查，完成后将列出实际覆盖范围'
    $ui.Status.Text='正在检查 '+$Program.Name+'…'
    if($null -eq $script:job -and $null -ne $script:inventory){Start-Worker -Mode Scan -Program $Program}
}
function Get-ProgramCachedScan($Program) {
    $key=Get-LSScanCacheKey $Program
    if($script:scanCache.ContainsKey($key)){return $script:scanCache[$key]}
    if(!$script:cacheMisses.ContainsKey($key)){
        $cached=Read-LSScanCache $Program
        if($null -ne $cached){$script:scanCache[$key]=$cached;return $cached}
        $script:cacheMisses[$key]=$true
    }
    return $null
}
function Ensure-SelectedResult {
    if(!$script:selected -or $null -ne $script:job){return}
    $cached=Get-ProgramCachedScan $script:selected
    if($null -ne $cached){Show-Scan -Result $cached -Program $script:selected -FromCache;Set-Working $false}
    elseif($null -ne $script:inventory){Start-Worker -Mode Scan -Program $script:selected}
}
function Convert-ResultRows($Findings) {
    foreach($r in $Findings) {
        $state=$stateLabels[[string]$r.State];if(!$state){$state=[string]$r.State}
        $glyph=$kindIcons[[string]$r.Kind];if(!$glyph){$glyph='file'}
        $color=$(if([string]$r.State -in @('Running','True')){'#26786B'}else{'#8B9390'})
        [pscustomobject]@{Kind=$r.Kind;KindLabel=$kindLabels[[string]$r.Kind];TypeIcon=$icons[('Icon.'+$glyph+'.Default')];StatusColor=$color;Name=$r.Name;Reference=$r.Reference;Evidence=$r.Evidence;EvidenceLabel=$evidenceLabels[[string]$r.Evidence];StateLabel=$state;Detail=$r.Detail;Reason=$r.Reason;Id=$r.Id}
    }
}
function Show-Scan($Result,$Program,[switch]$FromCache) {
    $script:result=$Result; $script:shownId=$Program.Id; $script:resultLabel='scan'
    $order=@{Service=0;Driver=1;Device=2;Startup=3;Task=4;Firewall=5;Process=6;Uninstall=7;RegistryKey=8;DataDirectory=9;BundledFile=10}
    $script:rows=@(Convert-ResultRows $Result.Findings | Sort-Object @{Expression={$order[$_.Kind]}},Name,Id)
    foreach($e in @('Path','Component','Name')) {$ui[($e+'Count')].Text=[string]@($Result.Findings | Where-Object {$_.Evidence -eq $e}).Count}
    Update-Results
    $issues=@($Result.Coverage | Where-Object {$_.Status -ne 'Complete'})
    $sourceNames=@{Services='服务';Drivers='系统驱动';Processes='进程';Startup='启动项';Uninstall='卸载记录';ScheduledTasks='计划任务';Firewall='防火墙';Devices='设备';InstallationFiles='安装目录文件';DataDirectories='数据目录';RegistryNames='注册表名称'}
    $statusNames=@{Complete='已读取';Partial='部分覆盖';Failed='读取失败';Unavailable='不可用'}
    $lines=@($Result.Coverage | ForEach-Object {$sourceNames[$_.Source]+'  ·  '+$statusNames[$_.Status]+'  ·  '+$_.Count+$(if($_.Error){"`r`n"+$_.Error})})
    $catalogLines=@();if($script:catalog){$catalogLines=@($script:catalog.Coverage | ForEach-Object {$_.Source+' · '+$statusNames[$_.Status]+' · '+$_.Count+$(if($_.Error){"`r`n"+$_.Error})})}
    $ui.Coverage.Text=($lines -join "`r`n`r`n")+"`r`n`r`n软件发现来源`r`n"+($catalogLines -join "`r`n")+"`r`n`r`n系统记录读取时间："+$Result.InventoryAt+"`r`n本次检查时间："+$Result.CapturedAt+"`r`n`r`n路径关联表示记录指向安装目录；组件匹配和名称候选仍需核对。关联不等于独占归属，不能直接作为删除清单。`r`n`r`n数据目录和注册表键只查两层，跳过文件重解析点；未加载的其他用户注册表、未使用的驱动包和全部历史写入不在完整覆盖范围内。程序不验证数字签名。普通检查只读；卸载与清理需在专用流程中确认。"
    $time=([DateTimeOffset]::Parse($Result.CapturedAt)).LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss')
    $ui.Status.Text=$(if($FromCache){'缓存结果'}else{'检查完成'})+' · '+$time+' · '+$(if($issues.Count){$issues.Count.ToString()+' 个来源未完整覆盖'}else{'非实时记录'})
}
$ui.Search.Add_TextChanged({$ui.SearchHint.Visibility=$(if($ui.Search.Text){'Collapsed'}else{'Visible'});$searchTimer.Stop();$searchTimer.Start()})
$ui.Programs.Add_SelectionChanged({if(!$script:suspendSelection -and $ui.Programs.SelectedItem){Show-Program $ui.Programs.SelectedItem}})
$ui.KindFilter.Add_SelectionChanged({Update-Results})
$ui.Results.Add_SelectionChanged({
    $r=$ui.Results.SelectedItem
    $ui.EvidencePanel.IsEnabled=($null -ne $r)
    if($r) {
        $reason=@{Path='系统记录的路径与安装目录关联，尚未验证是否独占';Component='与安装目录附带的驱动组件名称匹配，可能共享或来自旧版本';Name='名称匹配，仅是待核对候选'}[[string]$r.Evidence]
        if(!$reason){$reason=$r.Reason}
        $ui.EvidenceText.Text=$r.Name+"`r`n"+$reason+"`r`n`r`n"+$r.Reference+"`r`n"+$r.Detail+"`r`n"+$r.Id
    } else {$ui.EvidenceText.Text='';$ui.EvidencePanel.IsExpanded=$false}
})
$ui.Refresh.Add_Click({$script:inventory=$null;$script:shownId='';$ui.Status.Text='正在重新发现软件列表 · 保留已有检查结果';Start-Worker -Mode Discover})
$ui.Rescan.Add_Click({$script:refreshTarget=$script:selected;$ui.Status.Text='正在更新检查 · 保留上次结果';Start-Worker -Mode Inventory})
$ui.Uninstall.Add_Click({
    try{
        $target=$script:selected
        $session=Show-LSUninstallDialog -Program (ConvertTo-LSProgramRecord $target) -Owner $window
        if($session -and $session.State -ne 'Prepared'){
            $key=Get-LSScanCacheKey $target;$script:scanCache.Remove($key);$script:cacheMisses.Remove($key)
            Remove-LSScanCache $target
            $script:shownId='';$script:inventory=$null
            $ui.Status.Text='卸载记录已保存在本机 · 正在更新软件列表'
            Start-Worker -Mode Discover
        }
    }catch{$ui.Status.Text='卸载流程失败：'+$_.Exception.Message}
})
$ui.LastUninstall.Add_Click({
    try{
        $last=Get-LSLastUninstallSession
        if(!$last){$ui.Status.Text='还没有卸载记录';return}
        [void](Show-LSUninstallDialog -Program $last.Program -Owner $window -ExistingSession $last)
        $script:inventory=$null;Start-Worker -Mode Discover
    }catch{$ui.Status.Text='读取卸载记录失败：'+$_.Exception.Message}
})
$ui.Tools.Add_Click({$ui.Tools.ContextMenu.PlacementTarget=$ui.Tools;$ui.Tools.ContextMenu.IsOpen=$true})
$ui.Snapshot.Add_Click({$ui.Status.Text='正在保存系统快照…';Start-Worker -Mode Snapshot})
$ui.Compare.Add_Click({
    $dialog=New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter='LocalSafe JSON (*.json)|*.json';$dialog.Title='选择较早的系统快照'
    if(!$dialog.ShowDialog()) {return};$before=$dialog.FileName
    $dialog.Title='选择较晚的系统快照';if(!$dialog.ShowDialog()){return}
    $script:shownId='';$ui.Status.Text='正在比较系统快照…';Start-Worker -Mode Compare -Before $before -After $dialog.FileName
})
$ui.Browse.Add_Click({
    $dialog=New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description='检查未登记或便携软件的目录'
    if($dialog.ShowDialog() -eq 'OK'){
        $path=$dialog.SelectedPath
        $script:shownId='';Show-Program ([pscustomobject]@{Id=('manual|'+$path);Name=[IO.Path]::GetFileName($path);Publisher='';Version='';InstallPath=$path;PathSource='Manual'})
    }
    $dialog.Dispose()
})
$ui.Save.Add_Click({try{$ui.Status.Text='已保存到本机：'+(Save-LSLocalJson -Value $script:result -Label $script:resultLabel)}catch{$ui.Status.Text='保存失败：'+$_.Exception.Message}})
$searchTimer=New-Object Windows.Threading.DispatcherTimer
$searchTimer.Interval=[TimeSpan]::FromMilliseconds(300)
$searchTimer.Add_Tick({$searchTimer.Stop();Update-ProgramList})
$timer=New-Object Windows.Threading.DispatcherTimer
$timer.Interval=[TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({
    if($null -eq $script:job -or $script:job.State -notin @('Completed','Failed','Stopped')) {return}
    $next='';$mode=$script:operation
    try {
        if($script:job.State -ne 'Completed'){throw $script:job.ChildJobs[0].JobStateInfo.Reason}
        $value=Receive-Job $script:job -ErrorAction Stop
        switch($mode){
            'Discover'{
                $script:catalog=$value
                $script:programs=@($value.Programs | ForEach-Object {
                    $_ | Add-Member -NotePropertyName IconSource -NotePropertyValue (Get-LSProgramIcon $_) -Force
                    $subtitle=$_.Publisher
                    if(!$subtitle -or $subtitle -match '^[0-9a-f-]{36}$'){$subtitle=$(if($_.Kind -eq 'Store'){'商店应用'}else{$_.Version})}
                    $_ | Add-Member -NotePropertyName Subtitle -NotePropertyValue $subtitle -Force
                    $_
                })
                Update-ProgramList;$next='Inventory'
                $ui.Status.Text='已发现 '+$script:programs.Count+' 款软件 · 正在读取系统关联记录…'
                $ui.Coverage.Text=($value.Limitations -join "`r`n")
            }
            'Inventory'{$script:inventory=$value;if($script:refreshTarget){$next='RefreshScan'}elseif($script:selected){$next='Ensure'}else{$ui.Status.Text='未选择软件；可在更多菜单检查其他目录'}}
            'Scan'{
                $key=Get-LSScanCacheKey $script:activeProgram
                $script:scanCache[$key]=$value
                $cacheError=''
                try{Write-LSScanCache -Program $script:activeProgram -Report $value}catch{$cacheError=' · 本机缓存写入失败：'+$_.Exception.Message}
                if($script:selected -and (Get-LSScanCacheKey $script:selected) -eq $key){Show-Scan -Result $value -Program $script:activeProgram;$ui.Status.Text+=$cacheError}
                else{$next='Ensure'}
            }
            'Snapshot'{
                $ui.Status.Text='快照已保存到本机：'+(Save-LSLocalJson -Value $value -Label snapshot)
                if($script:selected -and $script:shownId -ne $script:selected.Id){$next='Ensure'}
            }
            'Compare'{
                $script:result=$value;$script:resultLabel='compare';$script:shownId='';$ui.AppIcon.Source=$icons['Icon.layers.Accent'];$ui.AppName.Text='系统快照变化';$ui.AppMeta.Text=$value.BeforeAt+' → '+$value.AfterAt;$ui.AppPath.Text='系统登记差异 · 不代表安装程序归属'
                $findings=@($value.Changes | ForEach-Object {$r=$_.After;if(!$r){$r=$_.Before};[pscustomobject]@{Kind=$r.Kind;Name=$r.Name;Reference=$r.Reference;Evidence=$_.Change;State=$r.State;Detail=$r.Detail;Reason='系统登记快照之间的变化';Id=$r.Id}})
                $script:rows=@(Convert-ResultRows $findings);Update-Results
                $ui.PathCount.Text='—';$ui.ComponentCount.Text='—';$ui.NameCount.Text='—'
                $ui.Coverage.Text=$value.Limitations -join "`r`n";$ui.Status.Text='比较完成 · '+$value.Changes.Count+' 项记录变化'
            }
        }
    } catch {
        $ui.Status.Text='检查失败：'+$_.Exception.Message
        $ui.ResultEmpty.Text='未能完成检查，请查看下方错误';$ui.ResultEmpty.Visibility='Visible'
        $ui.Coverage.Text=$_.Exception.ToString()
    } finally {
        Remove-Job $script:job -Force;$script:job=$null;Set-Working $false
    }
    if($next -eq 'Inventory'){Start-Worker -Mode Inventory}
    elseif($next -eq 'RefreshScan'){$target=$script:refreshTarget;$script:refreshTarget=$null;Start-Worker -Mode Scan -Program $target}
    elseif($next -eq 'Ensure'){Ensure-SelectedResult}
})
$script:lastUninstallOpened=$false
$window.Add_ContentRendered({
    if($ShowLastUninstall -and !$script:lastUninstallOpened){
        $script:lastUninstallOpened=$true
        try{$last=Get-LSLastUninstallSession;if($last){[void](Show-LSUninstallDialog -Program $last.Program -Owner $window -ExistingSession $last)}}catch{$ui.Status.Text='读取卸载结果失败：'+$_.Exception.Message}
    }
    if($null -eq $script:catalog -and $null -eq $script:job){Start-Worker -Mode Discover}
})
$window.Add_Closed({$timer.Stop();$searchTimer.Stop();if($null -ne $script:job){Stop-Job $script:job;Remove-Job $script:job -Force}})
$timer.Start()
[void]$window.ShowDialog()
