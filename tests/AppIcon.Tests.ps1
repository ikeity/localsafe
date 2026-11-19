# SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationCore,WindowsBase
$icon=Join-Path $PSScriptRoot '..\src\assets\LocalSafe.ico'
$decoder=[Windows.Media.Imaging.IconBitmapDecoder]::new([Uri]::new([IO.Path]::GetFullPath($icon)),[Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,[Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
$sizes=@($decoder.Frames | ForEach-Object {$_.PixelWidth})
foreach($size in @(16,20,24,32,40,48,64,128,256)){if($sizes -notcontains $size){throw ('Missing native icon size: '+$size)}}
foreach($frame in $decoder.Frames){
    $image=[Windows.Media.Imaging.FormatConvertedBitmap]::new($frame,[Windows.Media.PixelFormats]::Bgra32,$null,0)
    $pixels=[byte[]]::new($image.PixelWidth*$image.PixelHeight*4);$image.CopyPixels($pixels,$image.PixelWidth*4,0)
    $filled=0;for($i=3;$i -lt $pixels.Length;$i+=4){if($pixels[$i] -gt 127){$filled++}}
    if($filled -lt $image.PixelWidth*$image.PixelHeight*0.75){throw 'Application icon must occupy its canvas at small shell sizes.'}
}
'PASS: native ICO has nine sizes and substantial visible coverage at every size.'
