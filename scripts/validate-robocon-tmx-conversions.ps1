[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [string]$DestinationRoot,

    [string[]]$IncludeMaps = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Canvas {
    param([Parameter(Mandatory = $true)][Xml.XmlElement]$Map)

    $minimumX = [int64]0
    $minimumY = [int64]0
    $maximumX = [int64]$Map.GetAttribute('width')
    $maximumY = [int64]$Map.GetAttribute('height')
    $chunks = @($Map.SelectNodes('./layer/data/chunk'))
    foreach ($chunk in $chunks) {
        $chunkX = [int64]$chunk.GetAttribute('x')
        $chunkY = [int64]$chunk.GetAttribute('y')
        $minimumX = [math]::Min($minimumX, $chunkX)
        $minimumY = [math]::Min($minimumY, $chunkY)
        $maximumX = [math]::Max($maximumX, $chunkX + [int64]$chunk.GetAttribute('width'))
        $maximumY = [math]::Max($maximumY, $chunkY + [int64]$chunk.GetAttribute('height'))
    }
    return [pscustomobject]@{
        width = $maximumX - $minimumX
        height = $maximumY - $minimumY
        shiftX = -$minimumX
        shiftY = -$minimumY
    }
}

function Get-ExpectedLayerData {
    param(
        [Parameter(Mandatory = $true)][Xml.XmlElement]$Layer,
        [Parameter(Mandatory = $true)][object]$Canvas
    )

    $cellCount = [int64]$Canvas.width * [int64]$Canvas.height
    $result = [uint64[]]::new([int]$cellCount)
    $dataNode = $Layer.SelectSingleNode('./data')
    $chunks = @($dataNode.SelectNodes('./chunk'))
    if ($chunks.Count -gt 0) {
        foreach ($chunk in $chunks) {
            $chunkWidth = [int64]$chunk.GetAttribute('width')
            $chunkHeight = [int64]$chunk.GetAttribute('height')
            $values = @($chunk.InnerText -split '[,\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [uint64]$_ })
            if ($values.Count -ne $chunkWidth * $chunkHeight) {
                throw "Invalid source chunk on layer '$($Layer.GetAttribute('name'))'."
            }
            $destinationX = [int64]$chunk.GetAttribute('x') + [int64]$Canvas.shiftX
            $destinationY = [int64]$chunk.GetAttribute('y') + [int64]$Canvas.shiftY
            for ($y = 0; $y -lt $chunkHeight; $y++) {
                for ($x = 0; $x -lt $chunkWidth; $x++) {
                    $sourceIndex = $y * $chunkWidth + $x
                    $destinationIndex = ($destinationY + $y) * [int64]$Canvas.width + $destinationX + $x
                    $result[[int]$destinationIndex] = $values[[int]$sourceIndex]
                }
            }
        }
        return $result
    }

    $values = @($dataNode.InnerText -split '[,\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [uint64]$_ })
    if ($values.Count -eq 0) {
        return $result
    }
    $sourceWidth = [int64]$Layer.GetAttribute('width')
    $sourceHeight = [int64]$Layer.GetAttribute('height')
    if ($values.Count -ne $sourceWidth * $sourceHeight) {
        throw "Invalid source data on layer '$($Layer.GetAttribute('name'))'."
    }
    $destinationX = [int64]$Canvas.shiftX
    $destinationY = [int64]$Canvas.shiftY
    if ($Layer.HasAttribute('x')) { $destinationX += [int64]$Layer.GetAttribute('x') }
    if ($Layer.HasAttribute('y')) { $destinationY += [int64]$Layer.GetAttribute('y') }
    for ($y = 0; $y -lt $sourceHeight; $y++) {
        for ($x = 0; $x -lt $sourceWidth; $x++) {
            $sourceIndex = $y * $sourceWidth + $x
            $destinationIndex = ($destinationY + $y) * [int64]$Canvas.width + $destinationX + $x
            $result[[int]$destinationIndex] = $values[[int]$sourceIndex]
        }
    }
    return $result
}

$sourcePath = (Resolve-Path -LiteralPath $SourceRoot).Path
$sourceMapsPath = Join-Path $sourcePath 'Maps'
$destinationPath = (Resolve-Path -LiteralPath $DestinationRoot).Path
$errors = [Collections.Generic.List[string]]::new()
$records = [Collections.Generic.List[object]]::new()
$sourceMaps = @(Get-ChildItem -LiteralPath $sourceMapsPath -Filter '*.tmx' -Recurse -File | Sort-Object FullName)
if ($IncludeMaps.Count -gt 0) {
    $includeSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($includeMap in $IncludeMaps) { [void]$includeSet.Add($includeMap) }
    $sourceMaps = @($sourceMaps | Where-Object { $includeSet.Contains([IO.Path]::GetRelativePath($sourceMapsPath, $_.FullName)) })
}

foreach ($sourceMap in $sourceMaps) {
    $relativeSource = [IO.Path]::GetRelativePath($sourceMapsPath, $sourceMap.FullName)
    $relativeDestination = if ($relativeSource -ieq 'ShuttleBay_New.tmx') {
        'shuttlebay.tmj'
    }
    elseif ($relativeSource -ieq 'ShuttleBay.tmx') {
        'ShuttleBay_legacy.tmj'
    }
    else {
        [IO.Path]::ChangeExtension($relativeSource, '.tmj')
    }
    $outputPath = Join-Path $destinationPath $relativeDestination
    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        $errors.Add("${relativeSource}: output is missing ($relativeDestination)")
        continue
    }

    try {
        $sourceDocument = [Xml.XmlDocument]::new()
        $sourceDocument.Load($sourceMap.FullName)
        $sourceMapNode = $sourceDocument.DocumentElement
        $outputMap = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
        $canvas = Get-Canvas -Map $sourceMapNode

        if ([int64]$outputMap.width -ne [int64]$canvas.width -or [int64]$outputMap.height -ne [int64]$canvas.height) {
            throw "map dimensions differ: expected $($canvas.width)x$($canvas.height), found $($outputMap.width)x$($outputMap.height)"
        }
        if ([int64]$outputMap.tilewidth -ne [int64]$sourceMapNode.GetAttribute('tilewidth') -or [int64]$outputMap.tileheight -ne [int64]$sourceMapNode.GetAttribute('tileheight')) {
            throw 'tile dimensions differ from source'
        }
        if ($outputMap.infinite -ne $false) {
            throw 'output map is not finite'
        }

        $floorLayers = @($outputMap.layers | Where-Object { $_.name -eq 'floorLayer' })
        if ($floorLayers.Count -ne 1 -or $floorLayers[0].type -ne 'objectgroup' -or @($floorLayers[0].objects).Count -ne 0) {
            throw 'expected exactly one empty floorLayer object layer'
        }

        $outputTileLayersById = @{}
        foreach ($outputLayer in @($outputMap.layers | Where-Object { $_.type -eq 'tilelayer' })) {
            $outputTileLayersById[[string]$outputLayer.id] = $outputLayer
        }
        $usedGids = [Collections.Generic.HashSet[uint64]]::new()
        $sourceTileLayerCount = 0
        foreach ($sourceLayer in $sourceMapNode.SelectNodes('./layer')) {
            $sourceName = $sourceLayer.GetAttribute('name')
            if ($sourceName -match '(?i)^(separator|-+)$') {
                continue
            }
            $sourceTileLayerCount++
            $layerId = $sourceLayer.GetAttribute('id')
            if (-not $outputTileLayersById.ContainsKey($layerId)) {
                throw "source layer '$sourceName' (id $layerId) is missing"
            }
            $outputLayer = $outputTileLayersById[$layerId]
            if ($outputLayer.name -ne $sourceName) {
                throw "layer id $layerId changed name from '$sourceName' to '$($outputLayer.name)'"
            }
            $expectedData = @(Get-ExpectedLayerData -Layer $sourceLayer -Canvas $canvas)
            $actualData = @($outputLayer.data)
            if ($actualData.Count -ne $expectedData.Count) {
                throw "layer '$sourceName' has $($actualData.Count) cells; expected $($expectedData.Count)"
            }
            for ($cellIndex = 0; $cellIndex -lt $expectedData.Count; $cellIndex++) {
                $actual = [uint64]$actualData[$cellIndex]
                if ($actual -ne [uint64]$expectedData[$cellIndex]) {
                    throw "layer '$sourceName' differs at cell $cellIndex"
                }
                $gid = $actual -band [uint64]0x0FFFFFFF
                if ($gid -ne 0) { [void]$usedGids.Add($gid) }
            }
        }
        if ($outputTileLayersById.Count -ne $sourceTileLayerCount) {
            throw "output contains $($outputTileLayersById.Count) tile layers; expected $sourceTileLayerCount"
        }

        $outputTilesets = @($outputMap.tilesets | Sort-Object firstgid)
        foreach ($tileset in $outputTilesets) {
            if ($tileset.PSObject.Properties.Name -contains 'source') {
                throw "tileset '$($tileset.name)' is externally referenced"
            }
            $imagePath = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $outputPath) ([string]$tileset.image)))
            if (-not (Test-Path -LiteralPath $imagePath -PathType Leaf)) {
                throw "tileset image is missing: $($tileset.image)"
            }
            $firstGid = [uint64]$tileset.firstgid
            $lastGidExclusive = $firstGid + [uint64]$tileset.tilecount
            $isUsed = $false
            foreach ($gid in $usedGids) {
                if ($gid -ge $firstGid -and $gid -lt $lastGidExclusive) { $isUsed = $true; break }
            }
            if (-not $isUsed) {
                throw "embedded tileset '$($tileset.name)' is unused"
            }
        }
        foreach ($gid in $usedGids) {
            $covered = $false
            foreach ($tileset in $outputTilesets) {
                $firstGid = [uint64]$tileset.firstgid
                if ($gid -ge $firstGid -and $gid -lt $firstGid + [uint64]$tileset.tilecount) { $covered = $true; break }
            }
            if (-not $covered) {
                throw "tile GID $gid has no embedded tileset"
            }
        }

        $records.Add([pscustomobject]@{
            source = $relativeSource
            output = $relativeDestination
            width = [int64]$outputMap.width
            height = [int64]$outputMap.height
            tileSize = [int64]$outputMap.tilewidth
            layers = @($outputMap.layers).Count
            tilesets = $outputTilesets.Count
        })
    }
    catch {
        $errors.Add("${relativeSource}: $($_.Exception.Message)")
    }
}

Write-Output "Source maps checked: $($sourceMaps.Count)"
Write-Output "Valid conversions: $($records.Count)"
Write-Output "Validation errors: $($errors.Count)"
Write-Output "Embedded tilesets: $(@($records | Measure-Object tilesets -Sum).Sum) total across maps"
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Output "  $_" }
    exit 1
}
