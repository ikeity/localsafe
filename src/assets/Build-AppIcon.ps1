# SPDX-License-Identifier: GPL-3.0-only
# Reproducible application artwork, distinct from the thin UI action glyphs.
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationCore,WindowsBase
$frames=@()
foreach($size in @(16,20,24,32,40,48,64,128,256)){
    $visual=[Windows.Media.DrawingVisual]::new();$dc=$visual.RenderOpen()
    $dc.PushTransform([Windows.Media.ScaleTransform]::new($size/64.0,$size/64.0))
    $teal=[Windows.Media.BrushConverter]::new().ConvertFromInvariantString('#17635B')
    $dc.DrawRoundedRectangle($teal,$null,[Windows.Rect]::new(1,1,62,62),14,14)
    $shield=[Windows.Media.Geometry]::Parse('M32,10 L49,17 L49,30 C49,41 42,49 32,54 C22,49 15,41 15,30 L15,17 Z')
    $dc.DrawGeometry([Windows.Media.Brushes]::White,$null,$shield)
    $pen=[Windows.Media.Pen]::new($teal,4.5);$pen.StartLineCap='Round';$pen.EndLineCap='Round';$pen.LineJoin='Round'
    $dc.DrawGeometry($null,$pen,[Windows.Media.Geometry]::Parse('M23,31 L29,37 L41,24'))
    $dc.Pop();$dc.Close()
    $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($size,$size,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($visual)
    $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=[IO.MemoryStream]::new();$encoder.Save($stream);$bytes=$stream.ToArray();$stream.Dispose()
    $frames+=@([pscustomobject]@{Size=$size;Bytes=$bytes})
    if($size -eq 256){[IO.File]::WriteAllBytes((Join-Path $PSScriptRoot 'LocalSafe.png'),$bytes)}
}
$output=[IO.File]::Create((Join-Path $PSScriptRoot 'LocalSafe.ico'));$writer=[IO.BinaryWriter]::new($output)
try{
    $writer.Write([uint16]0);$writer.Write([uint16]1);$writer.Write([uint16]$frames.Count)
    $offset=6+16*$frames.Count
    foreach($frame in $frames){
        $dimension=$(if($frame.Size -eq 256){0}else{$frame.Size})
        $writer.Write([byte]$dimension);$writer.Write([byte]$dimension);$writer.Write([byte]0);$writer.Write([byte]0)
        $writer.Write([uint16]1);$writer.Write([uint16]32);$writer.Write([uint32]$frame.Bytes.Length);$writer.Write([uint32]$offset)
        $offset+=$frame.Bytes.Length
    }
    foreach($frame in $frames){$writer.Write([byte[]]$frame.Bytes)}
}finally{$writer.Dispose();$output.Dispose()}
