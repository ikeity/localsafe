# SPDX-License-Identifier: GPL-3.0-only
Add-Type -AssemblyName PresentationCore,PresentationFramework,WindowsBase
$script:imageCache=@{}

function New-LSIconResources {
    $resources=New-Object Windows.ResourceDictionary
    $palette=@{Default='#697772';Accent='#17635B';Light='#FFFFFF'}
    foreach($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'assets\lucide') -Filter '*.svg' -File){
        [xml]$svg=Get-Content -LiteralPath $file.FullName -Raw
        foreach($tone in $palette.Keys){
            $drawing=New-Object Windows.Media.DrawingGroup
            $bounds=New-Object Windows.Media.RectangleGeometry ([Windows.Rect]::new(0,0,24,24))
            $drawing.Children.Add([Windows.Media.GeometryDrawing]::new([Windows.Media.Brushes]::Transparent,$null,$bounds))
            $brush=[Windows.Media.BrushConverter]::new().ConvertFromInvariantString($palette[$tone])
            $pen=[Windows.Media.Pen]::new($brush,1.5);$pen.StartLineCap='Round';$pen.EndLineCap='Round';$pen.LineJoin='Round'
            foreach($node in $svg.DocumentElement.ChildNodes){
                if($node -isnot [Xml.XmlElement]){continue}
                $number={param($name,$fallback=0) $value=$node.GetAttribute($name);if($value){[double]::Parse($value,[Globalization.CultureInfo]::InvariantCulture)}else{[double]$fallback}}
                $geometry=$null
                switch($node.LocalName){
                    'path'{$geometry=[Windows.Media.Geometry]::Parse($node.GetAttribute('d'))}
                    'circle'{$geometry=[Windows.Media.EllipseGeometry]::new([Windows.Point]::new((& $number 'cx'),(& $number 'cy')),(& $number 'r'),(& $number 'r'))}
                    'ellipse'{$geometry=[Windows.Media.EllipseGeometry]::new([Windows.Point]::new((& $number 'cx'),(& $number 'cy')),(& $number 'rx'),(& $number 'ry'))}
                    'rect'{$geometry=[Windows.Media.RectangleGeometry]::new([Windows.Rect]::new((& $number 'x'),(& $number 'y'),(& $number 'width'),(& $number 'height')),(& $number 'rx'),(& $number 'ry' (& $number 'rx')))}
                    'line'{$geometry=[Windows.Media.LineGeometry]::new([Windows.Point]::new((& $number 'x1'),(& $number 'y1')),[Windows.Point]::new((& $number 'x2'),(& $number 'y2')))}
                    'polyline'{$geometry=[Windows.Media.Geometry]::Parse('M '+$node.GetAttribute('points'))}
                    'polygon'{$geometry=[Windows.Media.Geometry]::Parse('M '+$node.GetAttribute('points')+' Z')}
                    default{throw ('Unsupported local icon geometry: '+$node.LocalName)}
                }
                $drawing.Children.Add([Windows.Media.GeometryDrawing]::new($null,$pen,$geometry))
            }
            $source=[Windows.Media.DrawingImage]::new($drawing);$source.Freeze()
            $resources.Add(('Icon.'+$file.BaseName+'.'+$tone),$source)
        }
    }
    return ,$resources
}

function Get-LSProgramIcon {
    param([Parameter(Mandatory)]$Program)
    $property=$Program.PSObject.Properties['IconReference']
    if(!$property -or !$property.Value){return $null}
    $hint=[Environment]::ExpandEnvironmentVariables([string]$property.Value).Trim()
    $index=0;$path=$hint.Trim('"')
    $match=[regex]::Match($hint,'^(?:"([^"]+)"|(.+?))(?:,\s*(-?\d+))?$')
    if($match.Success){$path=$match.Groups[1].Value;if(!$path){$path=$match.Groups[2].Value};if($match.Groups[3].Success){$index=[int]$match.Groups[3].Value}}
    # Never resolve shell namespaces, URLs, UNC/network paths, or execute an application.
    if($path -notmatch '^[A-Za-z]:\\' -or $path.Substring(2).Contains(':')){return $null}
    try{
        $path=[IO.Path]::GetFullPath($path)
        $root=[IO.Path]::GetPathRoot($path)
        $drive=[IO.DriveInfo]::new($root)
        if($drive.DriveType -in @([IO.DriveType]::Network,[IO.DriveType]::Unknown,[IO.DriveType]::NoRootDirectory)){return $null}
        $walk=$root
        foreach($part in $path.Substring($root.Length).Split('\')){
            $walk=Join-Path $walk $part
            if([IO.File]::GetAttributes($walk) -band [IO.FileAttributes]::ReparsePoint){return $null}
        }
        if(!(Test-Path -LiteralPath $path -PathType Leaf)){return $null}
    }catch{return $null}
    $extension=[IO.Path]::GetExtension($path).ToLowerInvariant()
    if($extension -notin @('.png','.jpg','.jpeg','.ico','.exe','.dll')){return $null}
    $key=$path.ToLowerInvariant()+'|'+$index+'|'+[IO.File]::GetLastWriteTimeUtc($path).Ticks
    if($script:imageCache.ContainsKey($key)){return $script:imageCache[$key]}
    $source=$null
    try {
        if($extension -in @('.exe','.dll')){
            if(!('LocalSafe.NativeIcon' -as [type])){
                Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace LocalSafe {
 public static class NativeIcon {
  [DllImport("shell32.dll", CharSet=CharSet.Unicode)]
  public static extern int SHDefExtractIcon(string file, int index, uint flags, out IntPtr large, out IntPtr small, uint sizes);
  [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr icon);
 }
}
'@
            }
            $large=[IntPtr]::Zero;$small=[IntPtr]::Zero
            try{
                $code=[LocalSafe.NativeIcon]::SHDefExtractIcon($path,$index,0,[ref]$large,[ref]$small,2097216)
                if($code -eq 0 -and $large -ne [IntPtr]::Zero){$source=[Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($large,[Windows.Int32Rect]::Empty,[Windows.Media.Imaging.BitmapSizeOptions]::FromWidthAndHeight(64,64));$source.Freeze()}
            }finally{if($large -ne [IntPtr]::Zero){[void][LocalSafe.NativeIcon]::DestroyIcon($large)};if($small -ne [IntPtr]::Zero){[void][LocalSafe.NativeIcon]::DestroyIcon($small)}}
        }else{
            $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
            try{$bitmap=[Windows.Media.Imaging.BitmapImage]::new();$bitmap.BeginInit();$bitmap.CacheOption='OnLoad';$bitmap.DecodePixelWidth=64;$bitmap.StreamSource=$stream;$bitmap.EndInit();$bitmap.Freeze();$source=$bitmap}finally{$stream.Dispose()}
        }
    }catch{$source=$null}
    $script:imageCache[$key]=$source
    return $source
}

function ConvertTo-LSProgramRecord {
    param($Program)
    if($null -eq $Program){return $null}
    $record=[ordered]@{}
    foreach($property in $Program.PSObject.Properties){
        if($property.Name -notin @('IconSource','Initial','Subtitle') -and $property.Value -isnot [Windows.Media.ImageSource]){$record[$property.Name]=$property.Value}
    }
    [pscustomobject]$record
}
Export-ModuleMember -Function New-LSIconResources,Get-LSProgramIcon,ConvertTo-LSProgramRecord
