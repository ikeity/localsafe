# SPDX-License-Identifier: GPL-3.0-only
param([string]$Version='0.3.0',[string]$OutputDirectory)
$ErrorActionPreference='Stop'
if($Version -ne '0.3.0'){throw 'This release script targets the version declared in the launcher.'}
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if(!$OutputDirectory){$OutputDirectory=Join-Path $repo 'dist'}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$stage=Join-Path $OutputDirectory ('package-'+[guid]::NewGuid().ToString('N'))
$archive=Join-Path $stage 'source.zip'
New-Item -ItemType Directory -Path $stage | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem,System.Windows.Forms
Push-Location $repo
try{
    $commit=(& git rev-parse HEAD).Trim();if($LASTEXITCODE -ne 0){throw 'Cannot resolve source commit.'}
    & git archive --format=zip --prefix=LocalSafe/ --output=$archive $commit LICENSE README.md Start-LocalSafe.cmd src
    if($LASTEXITCODE -ne 0){throw 'Cannot archive the committed release sources.'}
    [IO.Compression.ZipFile]::ExtractToDirectory($archive,$stage)
    Remove-Item -LiteralPath $archive
    $root=Join-Path $stage 'LocalSafe'
    $compiler=[CodeDom.Compiler.CompilerParameters]::new()
    $compiler.GenerateExecutable=$true;$compiler.GenerateInMemory=$false
    $compiler.OutputAssembly=Join-Path $root 'LocalSafe.exe'
    $compiler.CompilerOptions='/target:winexe /win32icon:"'+(Join-Path $root 'src\assets\LocalSafe.ico')+'"'
    foreach($assembly in @('System.dll','System.Core.dll','System.Windows.Forms.dll',[System.Management.Automation.PowerShell].Assembly.Location)){[void]$compiler.ReferencedAssemblies.Add($assembly)}
    Add-Type -Path @((Join-Path $root 'src\LocalSafe.Launcher.cs'),(Join-Path $root 'src\LocalSafe.Instance.cs')) -CompilerParameters $compiler
    $forbidden=@(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {$_.Name -match '\.(local|report|snapshot)\.json$|\.(log|pdb|tmp)$'})
    if($forbidden.Count){throw 'Local/private or debug artifacts entered the package.'}
    $zip=Join-Path $OutputDirectory ('LocalSafe-v'+$Version+'-windows-x64.zip')
    if(Test-Path -LiteralPath $zip){Remove-Item -LiteralPath $zip}
    [IO.Compression.ZipFile]::CreateFromDirectory($stage,$zip,[IO.Compression.CompressionLevel]::Optimal,$false)
    $hash=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'SHA256SUMS.txt'),($hash+'  '+[IO.Path]::GetFileName($zip)+"`n"),[Text.UTF8Encoding]::new($false))
    [pscustomobject]@{Commit=$commit;Archive=$zip;SHA256=$hash}
}finally{
    Pop-Location
    $resolved=[IO.Path]::GetFullPath($stage)
    if([IO.Path]::GetDirectoryName($resolved) -ieq $OutputDirectory -and [IO.Path]::GetFileName($resolved) -like 'package-*'){
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
