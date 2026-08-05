[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [string]$TilesetImageLibrary,

    [Parameter(Mandatory = $true)]
    [string]$DestinationRoot,

    [switch]$Overwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourcePath = (Resolve-Path -LiteralPath $SourceRoot).Path
$sourceMapsPath = Join-Path $sourcePath 'Maps'
$libraryPath = (Resolve-Path -LiteralPath $TilesetImageLibrary).Path
$destinationPath = [IO.Path]::GetFullPath($DestinationRoot)
$converterPath = Join-Path $PSScriptRoot 'convert-tmx-to-workadventure-tmj.ps1'

if (-not (Test-Path -LiteralPath $sourceMapsPath -PathType Container)) {
    throw "Maps directory not found: $sourceMapsPath"
}
if (-not (Test-Path -LiteralPath $converterPath -PathType Leaf)) {
    throw "Converter not found: $converterPath"
}

$converted = [Collections.Generic.List[string]]::new()
$skipped = [Collections.Generic.List[string]]::new()
$failures = [Collections.Generic.List[object]]::new()
$sourceMaps = @(Get-ChildItem -LiteralPath $sourceMapsPath -Filter '*.tmx' -Recurse -File | Sort-Object FullName)

foreach ($sourceMap in $sourceMaps) {
    $relativeSource = [IO.Path]::GetRelativePath($sourceMapsPath, $sourceMap.FullName)
    if ($relativeSource -ieq 'ShuttleBay_New.tmx') {
        $skipped.Add("$relativeSource (already represented by shuttlebay.tmj)")
        continue
    }

    $relativeDestination = [IO.Path]::ChangeExtension($relativeSource, '.tmj')
    if ($relativeSource -ieq 'ShuttleBay.tmx') {
        $relativeDestination = 'ShuttleBay_legacy.tmj'
    }
    $destinationMap = Join-Path $destinationPath $relativeDestination

    if ((Test-Path -LiteralPath $destinationMap -PathType Leaf) -and -not $Overwrite) {
        $skipped.Add("$relativeSource (destination exists: $relativeDestination)")
        continue
    }

    try {
        Write-Output "Converting $relativeSource -> $relativeDestination"
        & $converterPath `
            -SourceMap $sourceMap.FullName `
            -TilesetImageLibrary $libraryPath `
            -DestinationMap $destinationMap | ForEach-Object { Write-Verbose $_ }
        $converted.Add($relativeDestination)
    }
    catch {
        $failures.Add([pscustomobject]@{
            source = $relativeSource
            destination = $relativeDestination
            error = $_.Exception.Message
        })
        Write-Warning "Failed: $relativeSource — $($_.Exception.Message)"
    }
}

Write-Output ''
Write-Output "Source maps found: $($sourceMaps.Count)"
Write-Output "Converted: $($converted.Count)"
Write-Output "Skipped: $($skipped.Count)"
Write-Output "Failed: $($failures.Count)"
if ($skipped.Count -gt 0) {
    Write-Output "Skipped maps:"
    $skipped | ForEach-Object { Write-Output "  $_" }
}
if ($failures.Count -gt 0) {
    Write-Output "Failures:"
    $failures | ForEach-Object { Write-Output "  $($_.source): $($_.error)" }
    exit 1
}
