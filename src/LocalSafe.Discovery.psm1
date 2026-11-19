# SPDX-License-Identifier: GPL-3.0-only
Set-StrictMode -Version 2.0

function Resolve-LSProgramDirectory {
    param([string]$InstallLocation, [string]$DisplayIcon, [string]$UninstallString)
    $blocked=@($env:SystemRoot,($env:SystemRoot+'\System32'),($env:SystemRoot+'\SysWOW64'),$env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramData,$env:LOCALAPPDATA,$env:APPDATA,$env:USERPROFILE,($env:LOCALAPPDATA+'\Programs')) | Where-Object {$_} | ForEach-Object {$_.TrimEnd('\')}
    foreach($candidate in @(
        @{Text=$InstallLocation;Source='InstallLocation';Direct=$true},
        @{Text=$DisplayIcon;Source='DisplayIcon';Direct=$false},
        @{Text=$UninstallString;Source='UninstallString';Direct=$false}
    )) {
        if ([string]::IsNullOrWhiteSpace($candidate.Text)) {continue}
        $path=[Environment]::ExpandEnvironmentVariables($candidate.Text.Trim())
        if ($candidate.Direct) {$path=$path.Trim('"').TrimEnd('\')}
        else {
            $match=[regex]::Match($path,'^(?:"([^"\r\n]+\.exe)"|([^"\r\n]+?\.exe))(?=\s|,|$)','IgnoreCase')
            if(!$match.Success) {continue}
            $exe=$match.Groups[1].Value; if(!$exe){$exe=$match.Groups[2].Value}
            if(!(Test-Path -LiteralPath $exe -PathType Leaf)) {continue}
            $path=[IO.Path]::GetDirectoryName($exe)
        }
        try {
            if($path -notmatch '^[A-Za-z]:\\') {continue}
            $path=[IO.Path]::GetFullPath($path).TrimEnd('\')
            if($path -eq [IO.Path]::GetPathRoot($path).TrimEnd('\') -or $blocked -contains $path) {continue}
            if(!$candidate.Direct -and $env:SystemRoot -and $path.StartsWith($env:SystemRoot+'\',[StringComparison]::OrdinalIgnoreCase)) {continue}
            return [pscustomobject]@{Path=$path;Source=$candidate.Source;Exists=(Test-Path -LiteralPath $path -PathType Container)}
        } catch {continue}
    }
    [pscustomobject]@{Path='';Source='Unknown';Exists=$false}
}

function Merge-LSProgramEntries {
    param([object[]]$Entries)
    # Keep different versions, publishers, scopes and directories separate.
    $groups=@{}
    foreach($entry in $Entries) {
        $key=@($entry.Name,$entry.Publisher,$entry.Version,$entry.InstallPath,$entry.Scope,$entry.Kind) -join '|'
        if(!$groups.ContainsKey($key)) {
            $icon='';if($entry.PSObject.Properties['IconReference']){$icon=[string]$entry.IconReference}
            $groups[$key]=[pscustomobject]@{Id=$entry.Id;Name=$entry.Name;Publisher=$entry.Publisher;Version=$entry.Version;InstallPath=$entry.InstallPath;PathSource=$entry.PathSource;PathExists=$entry.PathExists;Scope=$entry.Scope;Kind=$entry.Kind;IconReference=$icon;RegistrationIds=@($entry.Id)}
        } else {$groups[$key].RegistrationIds+=@($entry.Id)}
    }
    @($groups.Values | Sort-Object Name,Version,Scope)
}

function Get-LSInstalledPrograms {
    [CmdletBinding()]
    param()
    $entries=New-Object System.Collections.Generic.List[object]
    $coverage=New-Object System.Collections.Generic.List[object]
    foreach($source in @(
        @{Root='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';Scope='Machine'},
        @{Root='HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall';Scope='Machine'},
        @{Root='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';Scope='CurrentUser'}
    )) {
        $errors=@(); $count=0
        if(!(Test-Path -LiteralPath $source.Root)) {continue}
        $keys=@(Get-ChildItem -LiteralPath $source.Root -ErrorAction SilentlyContinue -ErrorVariable +errors)
        foreach($key in $keys) {
            try {
                $v=Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                $get={param($n) $p=$v.PSObject.Properties[$n];if($null -ne $p){[string]$p.Value}else{''}}
                $name=& $get 'DisplayName'
                if(!$name -or (& $get 'SystemComponent') -eq '1' -or (& $get 'ParentKeyName') -or (& $get 'ReleaseType') -in @('Update','Hotfix','Security Update')) {continue}
                $directory=Resolve-LSProgramDirectory -InstallLocation (& $get 'InstallLocation') -DisplayIcon (& $get 'DisplayIcon') -UninstallString (& $get 'UninstallString')
                $entries.Add([pscustomobject]@{Id=$key.Name;Name=$name;Publisher=(& $get 'Publisher');Version=(& $get 'DisplayVersion');InstallPath=$directory.Path;PathSource=$directory.Source;PathExists=$directory.Exists;Scope=$source.Scope;Kind='Desktop';IconReference=(& $get 'DisplayIcon')})
                $count++
            } catch {$errors+=@($_)}
        }
        $coverage.Add([pscustomobject]@{Source=$source.Root;Status=$(if($errors.Count){'Partial'}else{'Complete'});Count=$count;Error=($errors -join '; ')})
    }
    $startNames=@{}; $startNamesAvailable=$false
    try {
        foreach($shortcut in @(Get-StartApps -ErrorAction Stop)) {
            if($shortcut.AppID -like '*!*') {
                $family=($shortcut.AppID -split '!',2)[0]
                if(!$startNames.ContainsKey($family)) {$startNames[$family]=$shortcut.Name}
            }
        }
        $startNamesAvailable=$true
        $coverage.Add([pscustomobject]@{Source='StartMenuNames';Status='Complete';Count=$startNames.Count;Error=''})
    } catch {$coverage.Add([pscustomobject]@{Source='StartMenuNames';Status='Failed';Count=0;Error=$_.Exception.Message})}
    try {
        $count=0
        foreach($app in @(Get-AppxPackage -ErrorAction Stop)) {
            if($app.IsFramework -or $app.IsResourcePackage -or $app.NonRemovable) {continue}
            if($startNamesAvailable -and !$startNames.ContainsKey($app.PackageFamilyName)) {continue}
            $name=$app.Name;if($startNames.ContainsKey($app.PackageFamilyName)){$name=$startNames[$app.PackageFamilyName]}
            $publisher=[string]$app.Publisher
            $cn=[regex]::Match($publisher,'^CN=(?:"([^"]+)"|([^,]+))')
            if($cn.Success){$publisher=$cn.Groups[1].Value;if(!$publisher){$publisher=$cn.Groups[2].Value}}
            $icon=''
            try {
                $manifestPath=Join-Path $app.InstallLocation 'AppxManifest.xml'
                [xml]$manifest=[IO.File]::ReadAllText($manifestPath)
                $visual=$manifest.SelectSingleNode('//*[local-name()="VisualElements"]')
                if($visual){
                    $logo=[IO.Path]::GetFullPath((Join-Path $app.InstallLocation $visual.GetAttribute('Square44x44Logo')))
                    if($logo.StartsWith($app.InstallLocation.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){
                        $logoDir=[IO.Path]::GetDirectoryName($logo);$stem=[IO.Path]::GetFileNameWithoutExtension($logo)
                        $variants=@(Get-ChildItem -LiteralPath $logoDir -Filter ($stem+'*.png') -File -ErrorAction SilentlyContinue | Sort-Object @{Expression={
                            if($_.Name -match 'targetsize-64.*altform-lightunplated'){0}
                            elseif($_.Name -match 'targetsize-44.*altform-lightunplated'){1}
                            elseif($_.Name -match 'targetsize-(44|64).*altform-unplated'){2}
                            elseif($_.Name -match 'scale-200'){3}else{4}
                        }},Name)
                        if($variants.Count){$icon=$variants[0].FullName}
                    }
                }
            }catch{$icon=''}
            $entries.Add([pscustomobject]@{Id=$app.PackageFullName;Name=$name;Publisher=$publisher;Version=[string]$app.Version;InstallPath=[string]$app.InstallLocation;PathSource='PackageLocation';PathExists=(Test-Path -LiteralPath $app.InstallLocation -PathType Container);Scope='CurrentUser';Kind='Store';IconReference=$icon})
            $count++
        }
        $coverage.Add([pscustomobject]@{Source='CurrentUserStorePackages';Status='Complete';Count=$count;Error=''})
    } catch {$coverage.Add([pscustomobject]@{Source='CurrentUserStorePackages';Status='Failed';Count=0;Error=$_.Exception.Message})}
    [pscustomobject]@{SchemaVersion=1;CapturedAt=[DateTimeOffset]::Now.ToString('o');Programs=@(Merge-LSProgramEntries -Entries $entries.ToArray());Coverage=@($coverage.ToArray());Limitations=@('Only machine and current-user registrations are read; portable applications and other users are not exhaustively discovered.','Directory inference from icons or uninstall commands is labeled separately; it does not prove exclusive ownership.','Frameworks, system components and update child entries are omitted from the application list.','Store apps are limited to current-user packages with Start menu entries when those names are available; package identities are the fallback.')}
}

Export-ModuleMember -Function Get-LSInstalledPrograms,Resolve-LSProgramDirectory,Merge-LSProgramEntries
