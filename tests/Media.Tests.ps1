# SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\LocalSafe.Media.psm1') -Force
function Assert($Condition,[string]$Message){if(!$Condition){throw $Message}}
$icons=New-LSIconResources
Assert ($icons.Count -ge 60) 'Local icon assets must render in all three tones.'
foreach($key in $icons.Keys){Assert ($icons[$key].IsFrozen -and $icons[$key].Width -ge 24 -and $icons[$key].Height -ge 24) ('Invalid icon geometry: '+$key)}
$program=[pscustomobject]@{Id='ExampleApp';Name='ExampleApp';InstallPath='C:\ExampleVendor\ExampleApp';IconReference=($env:SystemRoot+'\System32\shell32.dll,0');Version='1.0'}
$icon=Get-LSProgramIcon $program
Assert ($null -ne $icon -and $icon.IsFrozen) 'Extract a local Windows resource icon without launching an executable.'
$program | Add-Member -NotePropertyName IconSource -NotePropertyValue $icon
$program | Add-Member -NotePropertyName Subtitle -NotePropertyValue 'ExampleVendor'
$record=ConvertTo-LSProgramRecord $program
Assert (!$record.PSObject.Properties['IconSource'] -and !$record.PSObject.Properties['Subtitle']) 'Presentation images must never enter background jobs or uninstall journals.'
Assert ($record.Id -eq $program.Id -and $record.IconReference -eq $program.IconReference) 'Preserve program identity and icon hints.'
$remote=[pscustomobject]@{IconReference='\\example.invalid\share\app.exe'}
Assert ($null -eq (Get-LSProgramIcon $remote)) 'Never request remote icon resources.'
$missing=[pscustomobject]@{IconReference='C:\FictionalMissing\app.exe'}
Assert ($null -eq (Get-LSProgramIcon $missing)) 'Missing artwork must use the generic app fallback.'
[xml]$xaml=Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\LocalSafe.Window.xaml') -Raw -Encoding UTF8
$window=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
$window.Resources.MergedDictionaries.Add($icons)
foreach($match in [regex]::Matches($xaml.OuterXml,'DynamicResource (Icon\.[^}]+)')){Assert ($icons.Contains($match.Groups[1].Value)) ('Missing icon resource: '+$match.Groups[1].Value)}
Assert ($window.FindName('KindFilter').Items.Count -eq 8) 'Keep all existing filter categories accessible.'
Assert ($window.FindName('AppIcon') -and $window.FindName('Uninstall')) 'Keep app identity and uninstall entry in the live XAML.'
$dialogSource=Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\LocalSafe.UninstallUi.psm1') -Raw -Encoding UTF8
$markup=[regex]::Match($dialogSource,"(?s)\[xml\]\`$markup=@'\r?\n(.*?)\r?\n'@")
Assert $markup.Success 'Uninstall dialog markup must be available for verification.'
[xml]$dialogXml=$markup.Groups[1].Value
$dialog=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $dialogXml))
$dialog.Resources=$window.Resources
$dialog.FindName('Primary').Style=$window.Resources['IconAction']
$dialog.FindName('Primary').Tag=$icons['Icon.trash.Light']
Assert ($dialog.FindName('ProductIcon') -and $dialog.FindName('Items')) 'Uninstall workflow retains product identity and its review table.'
$dialog.Close()
$window.Close()
'PASS: local SVG rendering, native icon extraction, offline fallback, domain/presentation separation and WPF layout loading.'
