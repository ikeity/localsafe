# SPDX-License-Identifier: GPL-3.0-only
Set-StrictMode -Version 2.0

function Get-LSScanCacheKey {
    param([Parameter(Mandatory)]$Program)
    # Identity includes location and version: a reinstall must not reuse another installation's result.
    $fields=@('Id','Name','InstallPath','Version','Publisher','Scope')
    $identity=@(foreach($field in $fields){$p=$Program.PSObject.Properties[$field];if($p){[string]$p.Value}else{''}})
    # A normal-user scan must not hide newly accessible evidence after elevation.
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    $identity+=@([string]$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
    $bytes=[Text.Encoding]::UTF8.GetBytes(($identity | ConvertTo-Json -Compress))
    $sha=[Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant() }
    finally {$sha.Dispose()}
}

function Read-LSScanCache {
    param([Parameter(Mandatory)]$Program,[string]$Directory=(Join-Path $env:LOCALAPPDATA 'LocalSafe\Private\Cache'))
    $key=Get-LSScanCacheKey $Program
    $path=Join-Path $Directory ($key+'.local.json')
    if(!(Test-Path -LiteralPath $path -PathType Leaf)){return $null}
    try {
        $envelope=Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if($envelope.CacheVersion -ne 1 -or $envelope.Key -cne $key){return $null}
        $report=$envelope.Report
        if($report.SchemaVersion -ne 1 -or !$report.CapturedAt -or !$report.PSObject.Properties['InventoryAt'] -or !$report.PSObject.Properties['Findings'] -or !$report.PSObject.Properties['Coverage']){return $null}
        $date=[DateTimeOffset]::MinValue
        if(![DateTimeOffset]::TryParse([string]$report.CapturedAt,[ref]$date)){return $null}
        if([string]$report.InstallPath -ine [string]$Program.InstallPath){return $null}
        return $report
    } catch {return $null} # Corrupt/obsolete cache is a miss, never an empty successful scan.
}

function Write-LSScanCache {
    param([Parameter(Mandatory)]$Program,[Parameter(Mandatory)]$Report,[string]$Directory=(Join-Path $env:LOCALAPPDATA 'LocalSafe\Private\Cache'))
    $key=Get-LSScanCacheKey $Program
    New-Item -ItemType Directory -Path $Directory -Force -ErrorAction Stop | Out-Null
    $path=Join-Path $Directory ($key+'.local.json')
    $temp=Join-Path $Directory ($key+'.'+[guid]::NewGuid().ToString('N')+'.tmp')
    try {
        [pscustomobject]@{CacheVersion=1;Key=$key;Report=$Report} | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $temp -Encoding UTF8 -ErrorAction Stop
        # Publish only complete JSON. The previous result survives a failed replacement.
        if(Test-Path -LiteralPath $path){[IO.File]::Replace($temp,$path,[NullString]::Value)}else{[IO.File]::Move($temp,$path)}
    } finally {if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue}}
}

function Remove-LSScanCache {
    param([Parameter(Mandatory)]$Program,[string]$Directory=(Join-Path $env:LOCALAPPDATA 'LocalSafe\Private\Cache'))
    $path=Join-Path $Directory ((Get-LSScanCacheKey $Program)+'.local.json')
    if(Test-Path -LiteralPath $path -PathType Leaf){Remove-Item -LiteralPath $path -ErrorAction Stop}
}
Export-ModuleMember -Function Get-LSScanCacheKey,Read-LSScanCache,Write-LSScanCache,Remove-LSScanCache
