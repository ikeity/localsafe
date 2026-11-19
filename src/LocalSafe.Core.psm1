# SPDX-License-Identifier: GPL-3.0-only
Set-StrictMode -Version 2.0

function Test-LSPathReference {
    param([AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Root)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $normalized = [Environment]::ExpandEnvironmentVariables($Text).Replace('/', '\')
    $prefix = $Root.Replace('/', '\').TrimEnd('\')
    # Match a full path component, never a neighboring directory with the same prefix.
    return [regex]::IsMatch($normalized, '(?i)(?<![\w.\\-])' + [regex]::Escape($prefix) + '(?=\\|["''\s]|$)')
}

function Test-LSNameReference {
    param([string]$Text, [string[]]$Names)
    foreach ($name in $Names) {
        if ($name.Length -ge 4 -and $Text.IndexOf($name, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

function Get-LSInventory {
    [CmdletBinding()]
    param()
    $records = New-Object System.Collections.Generic.List[object]
    $coverage = New-Object System.Collections.Generic.List[object]
    $collect = {
        param($Name, $Action)
        try {
            $items = @(& $Action)
            foreach ($item in $items) { $records.Add($item) }
            $coverage.Add([pscustomobject]@{ Source=$Name; Status='Complete'; Count=$items.Count; Error=$null })
        } catch {
            $coverage.Add([pscustomobject]@{ Source=$Name; Status='Failed'; Count=0; Error=$_.Exception.Message })
        }
    }
    & $collect 'Services' {
        Get-CimInstance Win32_Service -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Kind='Service'; Id=$_.Name; Name=$_.DisplayName; Reference=$_.PathName; State=$_.State; Detail=$_.StartMode }
        }
    }
    & $collect 'Drivers' {
        Get-CimInstance Win32_SystemDriver -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Kind='Driver'; Id=$_.Name; Name=$_.DisplayName; Reference=$_.PathName; State=$_.State; Detail=$_.StartMode }
        }
    }
    & $collect 'Processes' {
        Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Kind='Process'; Id=[string]$_.ProcessId; Name=$_.Name; Reference=$_.ExecutablePath; State='Running'; Detail='' }
        }
    }
    & $collect 'Startup' {
        Get-CimInstance Win32_StartupCommand -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Kind='Startup'; Id=($_.Location+'|'+$_.User+'|'+$_.Name); Name=$_.Name; Reference=$_.Command; State='Registered'; Detail=$_.Location }
        }
    }
    & $collect 'Uninstall' {
        foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
            if (!(Test-Path -LiteralPath $root)) { continue }
            foreach ($key in Get-ChildItem -LiteralPath $root -ErrorAction Stop) {
                $v = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                $get = { param($n) $p=$v.PSObject.Properties[$n]; if ($null -ne $p) { [string]$p.Value } else { '' } }
                [pscustomobject]@{ Kind='Uninstall'; Id=$key.Name; Name=(& $get 'DisplayName'); Reference=((& $get 'InstallLocation')+' | '+(& $get 'UninstallString')); State='Registered'; Detail=((& $get 'Publisher')+' | '+(& $get 'DisplayVersion')) }
            }
        }
    }
    & $collect 'ScheduledTasks' {
        Get-ScheduledTask -ErrorAction Stop | ForEach-Object {
            $task = $_
            $actions = @($task.Actions | ForEach-Object {
                $e=$_.PSObject.Properties['Execute']; $a=$_.PSObject.Properties['Arguments']; $w=$_.PSObject.Properties['WorkingDirectory']
                (@($e,$a,$w) | Where-Object { $null -ne $_ } | ForEach-Object { $_.Value }) -join ' '
            }) -join ' | '
            [pscustomobject]@{ Kind='Task'; Id=($task.TaskPath+$task.TaskName); Name=$task.TaskName; Reference=$actions; State=[string]$task.State; Detail=$task.TaskPath }
        }
    }
    & $collect 'Firewall' {
        $filters = @{}
        Get-NetFirewallApplicationFilter -ErrorAction Stop | ForEach-Object { $filters[$_.InstanceID] = $_.Program }
        Get-NetFirewallRule -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Kind='Firewall'; Id=$_.Name; Name=$_.DisplayName; Reference=[string]$filters[$_.InstanceID]; State=[string]$_.Enabled; Detail=([string]$_.Direction+' / '+[string]$_.Action) }
        }
    }
    & $collect 'Devices' {
        $deviceServices=@{}
        Get-CimInstance Win32_PnPEntity -ErrorAction Stop | ForEach-Object {$deviceServices[$_.DeviceID]=$_.Service}
        Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Kind='Device'; Id=$_.DeviceID; Name=$_.DeviceName; Reference=($_.DriverName+' | service: '+$deviceServices[$_.DeviceID]); State='Registered'; Detail=($_.InfName+' | '+$_.Manufacturer+' | '+$_.DriverVersion) }
        }
    }
    # These limits travel with every saved inventory; an empty list is not proof of absence.
    $limits = @(
        'Processes may hide executable paths without elevation.',
        'Only the current user and machine uninstall entries are covered; other user hives are not loaded.',
        'Device inventory does not enumerate every unused package in DriverStore.',
        'Snapshots compare these registration sources, not all filesystem or registry writes.',
        'A snapshot is not atomic; the system may change during collection.'
    )
    [pscustomobject]@{ SchemaVersion=1; CapturedAt=[DateTimeOffset]::Now.ToString('o'); Records=@($records.ToArray()); Coverage=@($coverage.ToArray()); Limitations=$limits }
}

function Find-LSAssociations {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Inventory, [AllowEmptyString()][string]$InstallPath='', [string[]]$Names=@(), [string[]]$ComponentNames=@())
    foreach ($record in $Inventory.Records) {
        $strength = $null; $reason = $null
        if ($InstallPath -and (Test-LSPathReference -Text $record.Reference -Root $InstallPath)) {
            $strength='Path'; $reason='Recorded path points inside the selected installation directory; this does not prove exclusive ownership.'
        } elseif (($record.Kind -in @('Driver','Device')) -and (Test-LSNameReference -Text ($record.Name+' '+$record.Id+' '+$record.Reference) -Names $ComponentNames)) {
            $strength='Component'; $reason='Name matches a driver component shipped in this directory; it may be shared or installed by an earlier version.'
        } elseif (Test-LSNameReference -Text ($record.Name+' '+$record.Id+' '+$record.Reference) -Names $Names) {
            $strength='Name'; $reason='Product name matches; ownership is unverified.'
        }
        if ($strength) {
            [pscustomobject]@{ Kind=$record.Kind; Name=$record.Name; Evidence=$strength; Reason=$reason; Reference=$record.Reference; State=$record.State; Detail=$record.Detail; Id=$record.Id }
        }
    }
}

function Get-LSScan {
    [CmdletBinding()]
    param([string]$InstallPath, [string[]]$Names=@(), $Inventory=$null, [switch]$AllowMissingPath)
    $root=''; $directoryAvailable=$false
    if($InstallPath) {
        try {
            $resolved = Get-Item -LiteralPath $InstallPath -ErrorAction Stop
            if (!$resolved.PSIsContainer) { throw 'Select an installation directory.' }
            $root = $resolved.FullName.TrimEnd('\'); $directoryAvailable=$true
        } catch {
            if(!$AllowMissingPath) {throw}
            $root=$InstallPath.TrimEnd('\')
        }
        if ($root -eq [IO.Path]::GetPathRoot($root).TrimEnd('\')) { throw 'Select a software directory, not an entire drive.' }
        if ($Names.Count -eq 0) { $Names = @([IO.Path]::GetFileName($root)) }
    }
    if(!$root -and $Names.Count -eq 0) {throw 'Provide an installation directory or product names.'}
    $coverage = New-Object System.Collections.Generic.List[object]
    $files = @(); $fileErrors=@()
    # Never descend through junctions or symlinks into unrelated directories.
    $queue = New-Object System.Collections.Generic.Queue[string]
    if($directoryAvailable) {$queue.Enqueue($root)}
    $list = New-Object System.Collections.Generic.List[object]
    while ($queue.Count -gt 0) {
        $dir = $queue.Dequeue()
        $children=@(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue -ErrorVariable +fileErrors)
        foreach ($child in $children) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($child.PSIsContainer) { $queue.Enqueue($child.FullName) } else { $list.Add($child) }
        }
    }
    $files=@($list.ToArray())
    $coverage.Add([pscustomobject]@{Source='InstallationFiles';Status=$(if(!$directoryAvailable){'Unavailable'}elseif($fileErrors.Count){'Partial'}else{'Complete'});Count=$files.Count;Error=$(if(!$directoryAvailable){'Installation directory is unknown, missing or inaccessible; only registrations and name candidates are checked.'}else{$fileErrors -join '; '})})
    $components=@($files | Where-Object { $_.Extension -in '.sys','.inf' } | ForEach-Object { $_.BaseName } | Sort-Object -Unique)
    if($null -eq $Inventory) {$Inventory = Get-LSInventory}
    $findings=New-Object System.Collections.Generic.List[object]
    foreach($item in @(Find-LSAssociations -Inventory $Inventory -InstallPath $root -Names $Names -ComponentNames $components)) { $findings.Add($item) }
    foreach ($file in $files | Where-Object { $_.Extension -in '.exe','.sys','.inf' }) {
        $detail=''
        if ($file.Extension -ne '.inf') { $v=$file.VersionInfo; $detail=($v.FileDescription+' | '+$v.CompanyName+' | '+$v.FileVersion) }
        $findings.Add([pscustomobject]@{ Kind='BundledFile';Name=$file.Name;Evidence='Path';Reason='Present in the installation directory; a bundled driver is not necessarily installed.';Reference=$file.FullName;State='Present';Detail=$detail;Id=$file.FullName })
    }
    # Shallow directory inspection: immediate children plus vendor/product grandchildren.
    $dataErrors=@()
    $dataRoots=@($env:ProgramData,$env:LOCALAPPDATA,$env:APPDATA,($env:USERPROFILE+'\AppData\LocalLow')) | Where-Object {$_} | Select-Object -Unique
    foreach($base in $dataRoots) {
        if (!(Test-Path -LiteralPath $base)) { continue }
        $dirs=@(Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction SilentlyContinue -ErrorVariable +dataErrors)
        foreach($dir in $dirs) {
            if ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) {continue}
            $candidates=@($dir)
            $candidates+=@(Get-ChildItem -LiteralPath $dir.FullName -Directory -Force -ErrorAction SilentlyContinue -ErrorVariable +dataErrors | Where-Object { !($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
            foreach($candidate in $candidates) {
                if (Test-LSNameReference -Text $candidate.Name -Names $Names) {
                    $findings.Add([pscustomobject]@{Kind='DataDirectory';Name=$candidate.Name;Evidence='Name';Reason='Directory name matches the product; contents and exclusive ownership were not inspected.';Reference=$candidate.FullName;State='Present';Detail='';Id=$candidate.FullName})
                }
            }
        }
    }
    $coverage.Add([pscustomobject]@{Source='DataDirectories';Status=$(if($dataErrors.Count){'Partial'}else{'Complete'});Count=@($findings | Where-Object {$_.Kind -eq 'DataDirectory'}).Count;Error=($dataErrors -join '; ')})
    # Match key names only; never dump arbitrary application values or credentials.
    $regErrors=@(); $regCount=0
    foreach($base in @('HKLM:\SOFTWARE','HKLM:\SOFTWARE\WOW6432Node','HKCU:\SOFTWARE','Registry::HKEY_CLASSES_ROOT')) {
        if (!(Test-Path -LiteralPath $base)) {continue}
        $keys=@(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue -ErrorVariable +regErrors)
        foreach($key in $keys) {
            $candidates=@($key)
            if ($base -ne 'Registry::HKEY_CLASSES_ROOT') {
                $candidates+=@(Get-ChildItem -LiteralPath $key.PSPath -ErrorAction SilentlyContinue -ErrorVariable +regErrors)
            }
            foreach($candidate in $candidates) {
                if(Test-LSNameReference -Text $candidate.PSChildName -Names $Names) {
                    $regCount++
                    $findings.Add([pscustomobject]@{Kind='RegistryKey';Name=$candidate.PSChildName;Evidence='Name';Reason='Registry key name matches the product; values were not collected.';Reference=$candidate.Name;State='Present';Detail='';Id=$candidate.Name})
                }
            }
        }
    }
    $coverage.Add([pscustomobject]@{Source='RegistryNames';Status=$(if($regErrors.Count){'Partial'}else{'Complete'});Count=$regCount;Error=($regErrors -join '; ')})
    [pscustomobject]@{
        SchemaVersion=1; CapturedAt=[DateTimeOffset]::Now.ToString('o'); InventoryAt=$Inventory.CapturedAt; InstallPath=$root; Names=$Names
        Findings=@($findings.ToArray() | Sort-Object Kind,Name,Id -Unique)
        Coverage=@($Inventory.Coverage)+@($coverage.ToArray())
        Limitations=@($Inventory.Limitations)+@('Registry names and data directories are searched only two levels deep; this is not an exhaustive residue search.','Name and component matches are candidates, never deletion authorization.','No exclusive ownership or cryptographic signature verification is performed.','Reparse points are skipped during filesystem traversal.','System registrations may come from a cached inventory; see InventoryAt for its timestamp.')
    }
}

function Compare-LSInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Before, [Parameter(Mandatory)]$After)
    foreach ($snapshot in @($Before,$After)) {
        if (!$snapshot.PSObject.Properties['SchemaVersion'] -or $snapshot.SchemaVersion -ne 1 -or !$snapshot.PSObject.Properties['Records']) {throw 'Expected a LocalSafe inventory snapshot (schema 1).'}
        if (@($snapshot.Coverage | Where-Object {$_.Status -ne 'Complete'}).Count) { throw 'One or more inventory sources failed. A full comparison would falsely imply additions or removals; collect complete snapshots first.' }
    }
    $old=@{}; $new=@{}
    foreach($r in $Before.Records) {$old[$r.Kind+'|'+$r.Id]=$r}
    foreach($r in $After.Records) {$new[$r.Kind+'|'+$r.Id]=$r}
    foreach($key in @(@($old.Keys)+@($new.Keys) | Sort-Object -Unique)) {
        $change=$null
        if (!$old.ContainsKey($key)) {$change='Added'}
        elseif (!$new.ContainsKey($key)) {$change='Removed'}
        else {
            foreach($field in @('Name','Reference','State','Detail')) {
                if ([string]$old[$key].$field -cne [string]$new[$key].$field) { $change='Changed'; break }
            }
        }
        if($change) {[pscustomobject]@{Change=$change;Key=$key;Before=$old[$key];After=$new[$key]}}
    }
}

function Save-LSLocalJson {
    param([Parameter(Mandatory)]$Value, [string]$Label='scan')
    $folder=Join-Path $env:LOCALAPPDATA 'LocalSafe\Private'
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $path=Join-Path $folder ((Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'-'+$Label+'.local.json')
    $Value | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

Export-ModuleMember -Function Test-LSPathReference,Test-LSNameReference,Get-LSInventory,Find-LSAssociations,Get-LSScan,Compare-LSInventory,Save-LSLocalJson
