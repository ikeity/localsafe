# SPDX-License-Identifier: GPL-3.0-only
# Run with Windows PowerShell -STA. No software or system records are changed.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\LocalSafe.UninstallUi.psm1') -Force
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
function Assert($value,$message){if(!$value){throw $message}}
$factory=& (Get-Module LocalSafe.UninstallUi) {${function:New-LSCleanupConfirmation}}
$owner=[Windows.Window]::new();$owner.Left=100;$owner.Top=100
[void][Windows.Interop.WindowInteropHelper]::new($owner).EnsureHandle()
$rows=@(1..200 | ForEach-Object {[pscustomobject]@{Name=('Example item '+$_);ActionLabel='Isolate directory';Reference=('C:\ExampleVendor\'+('LongProductName\'*12)+$_)}})
try{
    foreach($area in @([Windows.Rect]::new(0,0,1280,720),[Windows.Rect]::new(-960,0,960,540))){
        $window=& $factory -Owner $owner -Items $rows -WorkArea $area
        $window.Show();$window.UpdateLayout()
        Assert ($window.Height -le $area.Height-32 -and $window.Top -ge $area.Top -and $window.Top+$window.Height -le $area.Bottom) 'Confirmation must remain inside the target monitor working area.'
        Assert ($window.Left -ge $area.Left -and $window.Left+$window.Width -le $area.Right) 'Negative monitor coordinates must stay in bounds.'
        $button=$window.FindName('Confirm');$point=$button.TranslatePoint([Windows.Point]::new(0,0),$window)
        Assert ($button.ActualHeight -gt 0 -and $point.Y -ge 0 -and $point.Y+$button.ActualHeight -le $window.Height) 'Confirmation button must remain visible with a long selection.'
        $targets=$window.FindName('Targets')
        Assert ($targets.Items.Count -eq 200 -and $targets.ActualHeight -gt 0 -and $targets.ActualHeight -lt $window.Height) 'Full list must occupy bounded space.'
        function FindScroll($visual){
            if($visual -is [Windows.Controls.ScrollViewer]){return $visual}
            for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($visual);$i++){
                $found=FindScroll ([Windows.Media.VisualTreeHelper]::GetChild($visual,$i));if($found){return $found}
            }
        }
        $scroll=FindScroll $targets
        Assert ($scroll -and $scroll.ScrollableHeight -gt 0) 'Long selections must scroll internally.'
        $scroll.ScrollToEnd();$window.UpdateLayout()
        Assert ($scroll.VerticalOffset -gt 0) 'End of selection must be reachable by scrolling.'
        Assert ($window.FindName('Cancel').IsCancel -and !$button.IsDefault) 'Escape cancels and Enter does not default to destructive confirmation.'
        $window.Close()
    }
}finally{$owner.Close()}
'PASS: 200-item confirmation stays within small/offset work areas, preserves visible actions and scrolls to the end.'
