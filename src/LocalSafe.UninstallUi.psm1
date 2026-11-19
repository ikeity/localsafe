# SPDX-License-Identifier: GPL-3.0-only
function Get-LSReviewPresentation {
    param($Session)
    $v=$Session.Verdict
    $titles=@{Remaining='发现遗留';UninstallUnverified='卸载状态待确认';OperationFailed='部分清理未完成';Incomplete='检查未完成';ExitUnverified='卸载状态待确认';Quarantined='已隔离，文件仍保留';ClearWithinScope='检查范围内未发现遗留';NotChecked='尚未检查'}
    $title=$titles[$v.Code];if(!$title){$title=$v.Title}
    if($v.Code -eq 'Remaining' -and !$v.Direct -and !$v.Eligible){$title='仍有待核对项'}
    $summary=('{0} 项可清理 · {1} 项保留' -f $v.Eligible,($v.Remaining-$v.Eligible))
    if($v.Failures){$summary+=' · '+$v.Failures+' 项失败'}
    if($v.Incomplete){$summary+=' · '+$v.Incomplete+' 处未完成检查'}
    if($v.Quarantined){$summary+=' · '+$v.Quarantined+' 个隔离目录'}
    [pscustomobject]@{Title=$title;Summary=$summary}
}
function New-LSCleanupConfirmation {
    param([Parameter(Mandatory)]$Owner,[Parameter(Mandatory)][object[]]$Items,$WorkArea=$null)
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
    [xml]$xml=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'LocalSafe.CleanupConfirmation.xaml') -Raw -Encoding UTF8
    $window=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xml))
    $window.Owner=$Owner
    if(!$WorkArea){
        $handle=[Windows.Interop.WindowInteropHelper]::new($Owner).Handle
        $screen=[Windows.Forms.Screen]::FromHandle($handle).WorkingArea
        $source=[Windows.PresentationSource]::FromVisual($Owner)
        if($source -and $source.CompositionTarget){
            $matrix=$source.CompositionTarget.TransformFromDevice
            $origin=$matrix.Transform([Windows.Point]::new($screen.Left,$screen.Top))
            $extent=$matrix.Transform([Windows.Vector]::new($screen.Width,$screen.Height))
            $WorkArea=[Windows.Rect]::new($origin.X,$origin.Y,$extent.X,$extent.Y)
        }else{$WorkArea=[Windows.SystemParameters]::WorkArea}
    }
    $window.MaxWidth=[Math]::Max(1,$WorkArea.Width-32);$window.MaxHeight=[Math]::Max(1,$WorkArea.Height-32)
    $window.Width=[Math]::Min(760,$window.MaxWidth);$window.Height=[Math]::Min(640,$window.MaxHeight)
    $window.MinWidth=[Math]::Min(420,$window.Width);$window.MinHeight=[Math]::Min(300,$window.Height)
    $window.WindowStartupLocation='Manual'
    $window.Left=[Math]::Max($WorkArea.Left+16,[Math]::Min($Owner.Left+($Owner.ActualWidth-$window.Width)/2,$WorkArea.Right-$window.Width-16))
    $window.Top=[Math]::Max($WorkArea.Top+16,[Math]::Min($Owner.Top+($Owner.ActualHeight-$window.Height)/2,$WorkArea.Bottom-$window.Height-16))
    $window.FindName('Count').Text='确认处理 '+$Items.Count+' 项'
    $window.FindName('Targets').ItemsSource=$Items
    $window.FindName('Confirm').Add_Click({$window.DialogResult=$true}.GetNewClosure())
    $window.Add_ContentRendered({[void]$window.FindName('Cancel').Focus()}.GetNewClosure())
    return $window
}
function Show-LSUninstallDialog {
    param([Parameter(Mandatory)]$Program,$Owner,$ExistingSession=$null)
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    Import-Module (Join-Path $PSScriptRoot 'LocalSafe.Uninstall.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'LocalSafe.Media.psm1')
    [xml]$markup=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="卸载与遗留检查 · LocalSafe" Width="1120" Height="780" MinWidth="920" MinHeight="640" WindowStartupLocation="CenterOwner" Background="White" FontFamily="Microsoft YaHei UI" UseLayoutRounding="True" SnapsToDevicePixels="True" TextOptions.TextFormattingMode="Display" FontSize="14" Foreground="#202326">
 <Grid Margin="28"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <DockPanel Margin="0,0,0,20"><Border Width="56" Height="56" Background="#F5F7F6" CornerRadius="12" Margin="0,0,16,0" DockPanel.Dock="Left"><Image x:Name="ProductIcon" Width="40" Height="40"/></Border><StackPanel VerticalAlignment="Center"><TextBlock x:Name="Product" FontSize="26" FontWeight="Medium"/><TextBlock x:Name="Phase" Foreground="#697176" Margin="0,8,0,0"/></StackPanel></DockPanel>
  <Border Grid.Row="1" Background="#F7F9F8" CornerRadius="12" Padding="16" Margin="0,0,0,20"><StackPanel><TextBlock x:Name="VerdictTitle" Text="正在准备检查" FontSize="20" FontWeight="Medium" Margin="0,0,0,8" TextWrapping="Wrap"/><TextBlock x:Name="Summary" TextWrapping="Wrap" Foreground="#697176" AutomationProperties.Name="遗留数量与检查状态"/></StackPanel></Border>
  <DataGrid x:Name="Items" Grid.Row="2" AutoGenerateColumns="False" CanUserAddRows="False" HeadersVisibility="Column" SelectionMode="Single" SelectionUnit="FullRow" GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#ECEEEF" RowHeaderWidth="0" BorderBrush="#ECEEEF" Background="White" AutomationProperties.Name="卸载后的遗留及清理计划">
   <DataGrid.Columns><DataGridTemplateColumn Width="44"><DataGridTemplateColumn.CellTemplate><DataTemplate><CheckBox IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" IsEnabled="{Binding CanClean}" HorizontalAlignment="Center" VerticalAlignment="Center" ToolTip="{Binding Reason}" AutomationProperties.Name="{Binding Name}"><CheckBox.Style><Style TargetType="CheckBox"><Style.Triggers><DataTrigger Binding="{Binding CanClean}" Value="False"><Setter Property="Visibility" Value="Collapsed"/></DataTrigger></Style.Triggers></Style></CheckBox.Style></CheckBox></DataTemplate></DataGridTemplateColumn.CellTemplate></DataGridTemplateColumn><DataGridTemplateColumn Header="关联项" Width="*" IsReadOnly="True"><DataGridTemplateColumn.CellTemplate><DataTemplate><DockPanel Margin="0,4"><Border Width="32" Height="32" Background="#F2F5F3" CornerRadius="8" DockPanel.Dock="Left" Margin="0,0,12,0"><Image Source="{Binding TypeIcon}" Width="18" Height="18" ToolTip="{Binding KindLabel}" AutomationProperties.Name="{Binding KindLabel}"/></Border><StackPanel><TextBlock Text="{Binding Name}"/><TextBlock Text="{Binding Reference}" Foreground="#697176" FontSize="12" TextTrimming="CharacterEllipsis" ToolTip="{Binding Reference}"/></StackPanel></DockPanel></DataTemplate></DataGridTemplateColumn.CellTemplate></DataGridTemplateColumn><DataGridTextColumn Header="依据" Binding="{Binding EvidenceLabel}" Width="88" IsReadOnly="True"/><DataGridTextColumn Header="处理" Binding="{Binding ActionLabel}" Width="180" IsReadOnly="True"/></DataGrid.Columns>
  </DataGrid>
  <Expander Grid.Row="3" Header="详情" Margin="0,12,0,12"><ScrollViewer MaxHeight="200" VerticalScrollBarVisibility="Auto"><StackPanel><TextBox x:Name="ReviewDetails" IsReadOnly="True" TextWrapping="Wrap" BorderThickness="0" AutomationProperties.Name="卸载退出码、检查范围及执行记录"/><TextBox x:Name="Evidence" IsReadOnly="True" TextWrapping="Wrap" AcceptsReturn="True" BorderThickness="0" Margin="0,12,0,0" AutomationProperties.Name="所选项目的关联依据与保留原因"/></StackPanel></ScrollViewer></Expander>
  <Grid Grid.Row="4"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><DockPanel><StackPanel DockPanel.Dock="Right" Orientation="Horizontal" HorizontalAlignment="Right"><Button x:Name="Elevate" Content="以管理员身份继续…" Margin="0,0,8,0" Visibility="Collapsed"/><Button x:Name="Backup" Content="打开记录" Margin="0,0,8,0" IsEnabled="False"/><Button x:Name="Recheck" Content="重新检查遗留" Margin="0,0,8,0" IsEnabled="False"/><Button x:Name="Primary" Content="准备中…" IsEnabled="False" Background="#17635B" Foreground="White" BorderBrush="#17635B"/></StackPanel><TextBlock x:Name="Status" VerticalAlignment="Center" Foreground="#697176" TextWrapping="Wrap" MaxWidth="420"/></DockPanel><ProgressBar x:Name="Progress" Grid.Row="1" Height="2" IsIndeterminate="True" Margin="0,16,0,0" Foreground="#17635B" Background="#EDF0EF" BorderThickness="0"/></Grid>
 </Grid>
</Window>
'@
    $dialog=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $markup))
    if($Owner){$dialog.Owner=$Owner;$dialog.Resources=$Owner.Resources}
    $dialog.ShowInTaskbar=$false
    $u=@{};foreach($name in @('Product','ProductIcon','Phase','VerdictTitle','Summary','ReviewDetails','Items','Evidence','Elevate','Backup','Recheck','Primary','Status','Progress')){$u[$name]=$dialog.FindName($name)}
    $glyphs=@{InstallDirectory='folder';Service='settings';Driver='cpu';Device='monitor';Startup='power';Task='calendar-clock';Firewall='shield';Process='layers';Uninstall='package';RegistryKey='database';BundledFile='file';DataDirectory='folder'}
    if($Owner){
        $dialog.Icon=$Owner.Icon
        foreach($entry in @(@('Backup','folder.Default'),@('Recheck','scan-search.Default'),@('Primary','trash.Light'))){$u[$entry[0]].Style=$Owner.Resources['IconAction'];$u[$entry[0]].Tag=$Owner.Resources[('Icon.'+$entry[1])]}
        $image=Get-LSProgramIcon $Program;if(!$image){$image=$Owner.Resources['Icon.package.Default']};$u.ProductIcon.Source=$image
    }
    # A dedicated state object avoids module-global collisions between dialog invocations.
    $state=[pscustomobject]@{Session=$ExistingSession;Job=$null;Mode='';Rows=@();Started=$false;Folder=$PSScriptRoot;Elevated=([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))}
    $u.Product.Text=$Program.Name
    $createConfirmation=${function:New-LSCleanupConfirmation}
    $presentReview=${function:Get-LSReviewPresentation}
    $selectAll=New-Object Windows.Controls.CheckBox
    $selectAll.ToolTip='全选可处理项 / 取消全选'
    $selectAll.HorizontalAlignment='Center';$selectAll.VerticalAlignment='Center';$selectAll.IsEnabled=$false
    [Windows.Automation.AutomationProperties]::SetName($selectAll,'全选可处理项')
    $u.Items.Columns[0].Header=$selectAll
    $syncSelection={
        $eligible=@($state.Rows | Where-Object {$_.CanClean})
        $count=@($eligible | Where-Object {$_.Selected}).Count
        $selectAll.IsEnabled=(!$state.Job -and $eligible.Count -gt 0)
        $selectAll.IsChecked=$(if(!$count){$false}elseif($count -eq $eligible.Count){$true}else{$null})
        if($eligible.Count -gt 0){$u.Status.Text='已选 '+$count+' / '+$eligible.Count+' 项'}
    }.GetNewClosure()
    $selectAll.Add_Click({
        [void]$u.Items.CommitEdit()
        $checked=($selectAll.IsChecked -eq $true)
        foreach($row in $state.Rows){$row.Selected=($row.CanClean -and $checked)}
        $u.Items.Items.Refresh()
        & $syncSelection
    }.GetNewClosure())
    $u.Items.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent,[Windows.RoutedEventHandler]{
        param($sender,$event)
        if($event.OriginalSource -is [Windows.Controls.CheckBox] -and $event.OriginalSource -ne $selectAll){
            $binding=$event.OriginalSource.GetBindingExpression([Windows.Controls.Primitives.ToggleButton]::IsCheckedProperty)
            if($binding){$binding.UpdateSource()}
            & $syncSelection
        }
    }.GetNewClosure())
    $start={param($mode)
        $selectAll.IsEnabled=$false;$u.Items.IsEnabled=$false
        $state.Mode=$mode;$u.Primary.IsEnabled=$false;$u.Recheck.IsEnabled=$false;$u.Progress.Visibility='Visible'
        $u.Status.Text=$(switch($mode){'Prepare'{'正在读取卸载入口和卸载前清单…'}'Uninstall'{'请完成软件自带卸载窗口，结束后自动检查'}'Review'{'正在重新检查遗留，不使用缓存…'}'Cleanup'{'正在逐项备份并执行已确认的操作…'}})
        if($mode -eq 'Uninstall'){$u.Phase.Text='正在等待自带卸载程序结束';$u.VerdictTitle.Text='卸载正在进行，尚未检查遗留';$u.Summary.Text='当前表格暂为卸载前记录；不能据此判断残留。卸载程序结束后自动切换为新检查结果。'}
        elseif($mode -eq 'Review'){$u.Phase.Text='正在重新检查遗留';$u.VerdictTitle.Text='检查中，请以上次结果的时间为准'}
        elseif($mode -eq 'Cleanup'){$u.Phase.Text='正在执行已确认项';$u.VerdictTitle.Text='清理中，完成后将自动复查'}
        $ids=@($state.Rows | Where-Object {$_.Selected -and $_.CanClean} | ForEach-Object {$_.Id})
        $state.Job=Start-Job -ScriptBlock {
            param($folder,$mode,$program,$session,$ids)
            $ErrorActionPreference='Stop';Import-Module (Join-Path $folder 'LocalSafe.Uninstall.psm1') -Force
            switch($mode){'Prepare'{New-LSUninstallSession $program}'Uninstall'{Invoke-LSOfficialUninstall $session -Confirmed}'Review'{Update-LSResidualReview $session}'Cleanup'{Invoke-LSResidualCleanup $session -SelectedIds $ids -Confirmed}}
        } -ArgumentList $state.Folder,$mode,$Program,$state.Session,$ids
    }.GetNewClosure()
    $show={
        $s=$state.Session;$u.Backup.IsEnabled=$true
        if($s.State -eq 'Prepared'){
            $u.VerdictTitle.Text='等待确认启动卸载';$u.VerdictTitle.Foreground='#697176'
            $u.Phase.Text='卸载前清单';$u.Primary.Content='启动自带卸载程序';$u.Primary.IsEnabled=$true
            $beforeKinds=@{Service='服务';Driver='驱动';Device='设备';Startup='启动项';Task='任务';Firewall='防火墙';Process='进程';Uninstall='卸载登记';RegistryKey='注册表';BundledFile='随附文件';DataDirectory='数据目录'}
            $beforeEvidence=@{Path='路径关联';Component='组件匹配';Name='名称候选'}
            $u.Items.ItemsSource=@($s.Before.Findings | ForEach-Object {[pscustomobject]@{Name=$_.Name;Reference=$_.Reference;KindLabel=$beforeKinds[$_.Kind];TypeIcon=$dialog.Resources[('Icon.'+$glyphs[$_.Kind]+'.Default')];EvidenceLabel=$beforeEvidence[$_.Evidence];ActionLabel='卸载前记录';CanClean=$false;Selected=$false;Reason=$_.Reason;Detail=$_.Detail}})
            [Windows.Automation.AutomationProperties]::SetName($u.Items,'卸载前关联清单')
            $u.Summary.Text='完成自带卸载程序后，自动检查遗留'
            $u.ReviewDetails.Text=$s.Target.FilePath+"`r`n"+$s.Target.Arguments
            $u.Status.Text='等待确认启动卸载程序';return
        }
        $u.Phase.Text='卸载后检查';$u.Recheck.IsEnabled=$true
        [Windows.Automation.AutomationProperties]::SetName($u.Items,'卸载后遗留及清理计划')
        $kinds=@{InstallDirectory='安装目录';Service='服务';Driver='驱动';Device='设备';Startup='启动项';Task='计划任务';Firewall='防火墙';Process='进程';Uninstall='卸载登记';RegistryKey='注册表';BundledFile='随附文件';DataDirectory='数据目录'}
        $actions=@{ReviewOnly='仅供核对';QuarantineDirectory='隔离目录';QuarantineDataDirectory='隔离数据目录';RemoveStartup='移除启动值';RemoveService='删除已停止服务';RemoveFirewall='移除规则';RemoveTask='移除任务';RemoveRegistryKey='移除产品键'}
        $evidence=@{Path='路径关联';Component='组件匹配';Name='名称候选';RegistryPath='键值指向';ProductLocation='产品专属位置'}
        $holds=@{OwnershipUnverified='归属待确认';UninstallUnverified='卸载待确认';SharedLocation='共享位置';InferredLocation='安装位置待确认';ProtectedLocation='受保护位置';DriverReview='驱动依赖待核对';RunningComponent='组件仍在运行';BundledFile='随目录统一处理'}
        $state.Rows=@($s.Review.Items | Sort-Object @{Expression={if($_.CanClean){0}else{1}}},Kind,Name | ForEach-Object {
            $row=[ordered]@{};foreach($property in $_.PSObject.Properties){$row[$property.Name]=$property.Value}
            $row.KindLabel=$kinds[$_.Kind];$row.ActionLabel=$actions[$_.Action];$row.EvidenceLabel=$evidence[$_.Evidence]
            if(!$_.CanClean){$label=$holds[$_.HoldReason];if(!$label){$label='归属待确认'};$row.ActionLabel='保留 · '+$label}
            if($_.RequiresElevation -and !$state.Elevated){$row.ActionLabel+=' · 需管理员'}
            $row.TypeIcon=$dialog.Resources[('Icon.'+$glyphs[$_.Kind]+'.Default')]
            [pscustomobject]$row
        })
        $u.Items.ItemsSource=$state.Rows
        $allowed=@($state.Rows | Where-Object {$_.CanClean}).Count
        $u.Elevate.Visibility=$(if(!$state.Elevated -and @($state.Rows | Where-Object {$_.CanClean -and $_.RequiresElevation}).Count){'Visible'}else{'Collapsed'})
        $u.Primary.Content='清理所选…';$u.Primary.IsEnabled=($allowed -gt 0)
        $coverage=@($s.After.Coverage | Where-Object {$_.Status -ne 'Complete'})
        # The worker computes and persists this with the same fresh review. UI closures
        # consume data only, avoiding command resolution across dynamic module scopes.
        $verdict=$s.Verdict
        $presentation=& $presentReview $s
        $u.VerdictTitle.Text=$presentation.Title;$u.VerdictTitle.Foreground=$verdict.Color
        $u.Summary.Text=$presentation.Summary
        $u.ReviewDetails.Text=$verdict.Summary+"`r`n检查时间："+$s.Review.CapturedAt+"`r`n卸载登记："+$(if($s.Review.StillRegistered){'仍存在或无法确认'}else{'已消失'})+' · 卸载退出码：'+[string]$s.ExitCode+$(if($s.Error){"`r`n"+$s.Error})
        $u.Status.Text='已重新检查 · '+$s.Review.CapturedAt+$(if($s.ExitCode -eq 3010){' · 软件要求重启，未自动重启'})
        $u.ReviewDetails.Text+="`r`n"+(@($coverage | ForEach-Object {$_.Source+': '+$_.Status+' '+$_.Error}) -join "`r`n")+"`r`n"+(@($s.Operations | ForEach-Object {$_.Action+' · '+$_.Status+' · '+$_.Target+' '+$_.Error+$(if($_.Quarantine){' → '+$_.Quarantine})}) -join "`r`n")
        $u.Evidence.Text=''
    }.GetNewClosure()
    $u.Items.Add_SelectionChanged({if($u.Items.SelectedItem){$r=$u.Items.SelectedItem;$u.Evidence.Text=$r.Name+"`r`n"+$r.Reference+"`r`n`r`n"+$r.Reason+"`r`n"+$r.Detail+"`r`n`r`n"+(@($state.Session.Operations | ForEach-Object {$_.Action+' · '+$_.Status+' · '+$_.Target+' '+$_.Error}) -join "`r`n")}}.GetNewClosure())
    $u.Primary.Add_Click({
        if($state.Session.State -eq 'Prepared'){
            $message='将启动 '+$Program.Name+' 的自带卸载程序：'+"`r`n`r`n"+$state.Session.Target.FilePath+"`r`n"+$state.Session.Target.Arguments+"`r`n`r`n继续？"
            if([Windows.MessageBox]::Show($dialog,$message,'启动卸载','YesNo','Question') -eq 'Yes'){& $start 'Uninstall'}
        }else{
            [void]$u.Items.CommitEdit()
            $selected=@($state.Rows | Where-Object {$_.Selected -and $_.CanClean})
            if(!$selected.Count){$u.Status.Text='请先勾选要处理的遗留项';return}
            if(!$state.Elevated -and @($selected | Where-Object {$_.RequiresElevation}).Count){$u.Status.Text='所选项需要管理员权限，请点击管理员入口后重新勾选';return}
            $confirmation=& $createConfirmation -Owner $dialog -Items $selected
            if($confirmation.ShowDialog() -eq $true){& $start 'Cleanup'}
        }
    }.GetNewClosure())
    $u.Elevate.Add_Click({
        try{
            $entry=Join-Path $state.Folder 'Start-LocalSafe.ps1'
            Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$entry+'" -LastUninstall') -ErrorAction Stop
            $u.Status.Text='请在管理员窗口重新检查、勾选并确认；此窗口没有执行清理'
        }catch{$u.Status.Text='未启动管理员窗口：'+$_.Exception.Message}
    }.GetNewClosure())
    $u.Recheck.Add_Click({& $start 'Review'}.GetNewClosure())
    $u.Backup.Add_Click({if($state.Session){Start-Process explorer.exe -ArgumentList ('"'+$state.Session.Folder+'"')}}.GetNewClosure())
    $timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
        if(!$state.Job -or $state.Job.State -notin @('Completed','Failed','Stopped')){return}
        try{
            if($state.Job.State -ne 'Completed'){throw $state.Job.ChildJobs[0].JobStateInfo.Reason}
            $state.Session=Receive-Job $state.Job -ErrorAction Stop
            & $show
        }catch{$u.VerdictTitle.Text='检查或操作失败';$u.VerdictTitle.Foreground='#8A571C';$u.Status.Text='操作未完成';$u.Summary.Text='展开详情查看错误';$u.ReviewDetails.Text=$_.Exception.Message;$u.Recheck.IsEnabled=($null -ne $state.Session -and $state.Session.State -ne 'Prepared')}
        finally{Remove-Job $state.Job -Force;$state.Job=$null;$u.Progress.Visibility='Hidden';$u.Items.IsEnabled=$true;& $syncSelection}
    }.GetNewClosure())
    $dialog.Add_ContentRendered({if(!$state.Started){$state.Started=$true;if($state.Session -and $state.Session.State -ne 'Prepared'){& $start 'Review'}else{& $start 'Prepare'}}}.GetNewClosure())
    $dialog.Add_Closing({param($sender,$event)
        if($state.Job -and $state.Mode -eq 'Cleanup'){$event.Cancel=$true;$u.Status.Text='正在处理已确认项，请等待本轮备份和操作完成'}
    }.GetNewClosure())
    $dialog.Add_Closed({$timer.Stop();if($state.Job){Stop-Job $state.Job;Remove-Job $state.Job -Force}}.GetNewClosure())
    $timer.Start();[void]$dialog.ShowDialog()
    if($state.Session){
        try{$latest=Get-Content -LiteralPath (Join-Path $state.Session.Folder 'session.local.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop;$state.Session=$latest}catch{}
    }
    return $state.Session
}
Export-ModuleMember -Function Show-LSUninstallDialog
