# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [ValidateSet('Scan','Discover','Snapshot','Compare')][string]$Mode='Scan',
    [string]$InstallPath,
    [string[]]$Names=@(),
    [string]$Before,
    [string]$After,
    [switch]$Save
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'LocalSafe.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'LocalSafe.Discovery.psm1') -Force
switch($Mode) {
    'Discover' {$result=Get-LSInstalledPrograms}
    'Scan' {
        if (!$InstallPath) { throw 'Scan requires -InstallPath.' }
        $result=Get-LSScan -InstallPath $InstallPath -Names $Names
    }
    'Snapshot' { $result=Get-LSInventory }
    'Compare' {
        if (!$Before -or !$After) {throw 'Compare requires -Before and -After snapshot files.'}
        $b=Get-Content -LiteralPath $Before -Raw | ConvertFrom-Json
        $a=Get-Content -LiteralPath $After -Raw | ConvertFrom-Json
        $result=[pscustomobject]@{SchemaVersion=1;BeforeAt=$b.CapturedAt;AfterAt=$a.CapturedAt;Changes=@(Compare-LSInventory -Before $b -After $a);Limitations=@('Changes are correlations, not proof that a particular installer caused them.','Only the inventory sources are compared; this is not filesystem or registry write monitoring.')}
    }
}
if($Save) { Save-LSLocalJson -Value $result -Label $Mode.ToLowerInvariant() } else { $result | ConvertTo-Json -Depth 14 }
