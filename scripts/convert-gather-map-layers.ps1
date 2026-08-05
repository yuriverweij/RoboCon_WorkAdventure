param(
    [Parameter(Mandatory = $true)]
    [string] $SourceMap,

    [Parameter(Mandatory = $true)]
    [string] $OutputMap,

    [string] $MapName = "RoboCon 2026",

    [string] $PreviewImage,

    [string[]] $CollisionLayers = @("Walls", "Furniture", "Lounge", "Hall Seating", "Screen"),

    [string] $TmxRasterizerPath = "C:\Program Files\Tiled\tmxrasterizer.exe"
)

$ErrorActionPreference = "Stop"

$tileWidth = 32
$tileHeight = 32
$sourceMapPath = (Resolve-Path -LiteralPath $SourceMap).Path
$sourceDirectory = Split-Path -Parent $sourceMapPath
$outputMapPath = [System.IO.Path]::GetFullPath($OutputMap)
$outputDirectory = Split-Path -Parent $outputMapPath
$outputStem = [System.IO.Path]::GetFileNameWithoutExtension($outputMapPath)

if (-not (Test-Path -LiteralPath $TmxRasterizerPath)) {
    $rasterizerCommand = Get-Command "tmxrasterizer.exe" -ErrorAction SilentlyContinue
    if ($null -eq $rasterizerCommand) {
        throw "Tiled's tmxrasterizer was not found. Install Tiled or pass -TmxRasterizerPath."
    }
    $TmxRasterizerPath = $rasterizerCommand.Source
}

[xml] $source = Get-Content -Raw -LiteralPath $sourceMapPath
[System.Xml.XmlElement] $sourceMapNode = $source.SelectSingleNode("/map")
$sourceWidth = [int] $sourceMapNode.GetAttribute("width")
$sourceHeight = [int] $sourceMapNode.GetAttribute("height")
$sourceTileWidth = [int] $sourceMapNode.GetAttribute("tilewidth")
$sourceTileHeight = [int] $sourceMapNode.GetAttribute("tileheight")
$sourceTileCount = $sourceWidth * $sourceHeight
$sourceLayers = @($sourceMapNode.SelectNodes("layer"))

if ($sourceTileWidth -ne 16 -or $sourceTileHeight -ne 16) {
    throw "The layer-preserving converter expects a 16x16 Gather map."
}
if ($sourceLayers.Count -eq 0) {
    throw "The source map contains no tile layers."
}

$maxOffsetX = 0
$maxOffsetY = 0
foreach ($layer in $sourceLayers) {
    $offsetX = if ($layer.HasAttribute("offsetx")) { [double] $layer.GetAttribute("offsetx") } else { 0 }
    $offsetY = if ($layer.HasAttribute("offsety")) { [double] $layer.GetAttribute("offsety") } else { 0 }
    $maxOffsetX = [Math]::Max($maxOffsetX, $offsetX)
    $maxOffsetY = [Math]::Max($maxOffsetY, $offsetY)
}

$sourcePixelWidth = ($sourceWidth * $sourceTileWidth) + [Math]::Ceiling($maxOffsetX)
$sourcePixelHeight = ($sourceHeight * $sourceTileHeight) + [Math]::Ceiling($maxOffsetY)
$width = [int] [Math]::Ceiling($sourcePixelWidth / $tileWidth)
$height = [int] [Math]::Ceiling($sourcePixelHeight / $tileHeight)
$outputPixelWidth = $width * $tileWidth
$outputPixelHeight = $height * $tileHeight
$tileCount = $width * $height
$sourceCellsPerOutputCellX = $tileWidth / $sourceTileWidth
$sourceCellsPerOutputCellY = $tileHeight / $sourceTileHeight

function Get-CsvData([System.Xml.XmlElement] $layer, [int] $expectedCount) {
    $dataNode = $layer.SelectSingleNode("data")
    $values = @($dataNode.InnerText -split '[,\s]+' | Where-Object { $_ -ne '' } | ForEach-Object { [uint32] $_ })
    if ($values.Count -ne $expectedCount) {
        throw "Layer '$($layer.GetAttribute('name'))' contains $($values.Count) tiles; expected $expectedCount."
    }
    return $values
}

function Get-OccupiedOutputCells([uint32[]] $sourceData) {
    $occupiedCells = [System.Collections.Generic.HashSet[int]]::new()
    for ($sourceIndex = 0; $sourceIndex -lt $sourceData.Count; $sourceIndex++) {
        if (($sourceData[$sourceIndex] -band [uint32] 0x1FFFFFFF) -eq 0) {
            continue
        }

        $sourceX = $sourceIndex % $sourceWidth
        $sourceY = [Math]::Floor($sourceIndex / $sourceWidth)
        $targetX = [Math]::Floor($sourceX / $sourceCellsPerOutputCellX)
        $targetY = [Math]::Floor($sourceY / $sourceCellsPerOutputCellY)
        [void] $occupiedCells.Add(($targetY * $width) + $targetX)
    }
    return @($occupiedCells | Sort-Object)
}

function New-LayerAtlas([string] $sourcePath, [string] $outputPath, [int[]] $occupiedCells) {
    if ($occupiedCells.Count -eq 0) {
        return
    }

    $occupiedCellsPath = $outputPath + ".cells.json"
    $atlasBuilderPath = Join-Path $PSScriptRoot "build-layer-atlas.mjs"
    $nodePath = (Get-Command "node.exe" -ErrorAction Stop).Source
    try {
        [System.IO.File]::WriteAllText($occupiedCellsPath, ($occupiedCells | ConvertTo-Json -Compress), [System.Text.UTF8Encoding]::new($false))
        $arguments = @($atlasBuilderPath, $sourcePath, $outputPath, $occupiedCellsPath, $tileWidth, $width, 64)
        $process = Start-Process -FilePath $nodePath -ArgumentList $arguments -Wait -PassThru -NoNewWindow
        if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outputPath)) {
            throw "Could not build the 32 px atlas '$outputPath'."
        }
    }
    finally {
        if (Test-Path -LiteralPath $occupiedCellsPath) {
            Remove-Item -LiteralPath $occupiedCellsPath -Force
        }
    }
}

function Get-SafeFileName([string] $name) {
    $safeName = [System.Text.RegularExpressions.Regex]::Replace($name, '[^A-Za-z0-9._-]+', '-')
    $safeName = $safeName.Trim('-').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        return "layer"
    }
    return $safeName
}

function Set-TagAttribute([string] $tag, [string] $name, [string] $value) {
    $pattern = '\s' + [System.Text.RegularExpressions.Regex]::Escape($name) + '="[^"]*"'
    $replacement = ' {0}="{1}"' -f $name, $value
    if ([System.Text.RegularExpressions.Regex]::IsMatch($tag, $pattern)) {
        return [System.Text.RegularExpressions.Regex]::Replace($tag, $pattern, $replacement, 1)
    }
    return $tag.Insert($tag.Length - 1, $replacement)
}

function Invoke-TmxRasterizer([string] $mapPath, [string] $layerName, [string] $imagePath) {
    $arguments = @("--no-smoothing")
    if (-not [string]::IsNullOrEmpty($layerName)) {
        $arguments += @("--show-layer", $layerName)
    }
    $arguments += @($mapPath, $imagePath)

    $process = Start-Process -FilePath $TmxRasterizerPath -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $imagePath)) {
        throw "Tiled could not render layer '$layerName' from '$mapPath'."
    }
}

New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$assetRoot = Join-Path $outputDirectory "robocon"
$layerAssetFolderName = "${outputStem}-layers"
$layerAssetDirectory = Join-Path $assetRoot $layerAssetFolderName
$fullAssetRoot = [System.IO.Path]::GetFullPath($assetRoot).TrimEnd('\') + '\'
$fullLayerAssetDirectory = [System.IO.Path]::GetFullPath($layerAssetDirectory)
if (-not $fullLayerAssetDirectory.StartsWith($fullAssetRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to replace a layer asset directory outside '$assetRoot'."
}
if (Test-Path -LiteralPath $fullLayerAssetDirectory) {
    Remove-Item -LiteralPath $fullLayerAssetDirectory -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $fullLayerAssetDirectory | Out-Null

# Tiled's renderer is used as the source of truth for tile flips, transparent
# colors, external TSX files, and image-collection tiles. A temporary copy gives
# every layer a unique name and removes offsets while rendering. The offsets are
# restored as editable layer metadata in the WorkAdventure map.
$temporaryMapPath = Join-Path $sourceDirectory (".wa-layer-render-" + [guid]::NewGuid().ToString("N") + ".tmx")
$sourceText = [System.IO.File]::ReadAllText($sourceMapPath)
$script:temporaryLayerIndex = 0
$temporaryMapText = [System.Text.RegularExpressions.Regex]::Replace(
    $sourceText,
    '<layer\b[^>]*>',
    {
        param($match)
        $tag = $match.Value
        $uniqueName = "__wa_layer_{0:D3}" -f $script:temporaryLayerIndex
        $tag = Set-TagAttribute $tag "name" $uniqueName
        $tag = Set-TagAttribute $tag "visible" "1"
        $tag = Set-TagAttribute $tag "opacity" "1"
        $tag = Set-TagAttribute $tag "offsetx" "0"
        $tag = Set-TagAttribute $tag "offsety" "0"
        $script:temporaryLayerIndex++
        return $tag
    })

if ($script:temporaryLayerIndex -ne $sourceLayers.Count) {
    throw "Temporary render map contains $script:temporaryLayerIndex layers; expected $($sourceLayers.Count)."
}

[System.IO.File]::WriteAllText($temporaryMapPath, $temporaryMapText, [System.Text.UTF8Encoding]::new($false))

$targetLayers = [System.Collections.Generic.List[object]]::new()
$targetTilesets = [System.Collections.Generic.List[object]]::new()
$nextFirstGid = 1

try {
    for ($layerIndex = 0; $layerIndex -lt $sourceLayers.Count; $layerIndex++) {
        [System.Xml.XmlElement] $sourceLayer = $sourceLayers[$layerIndex]
        $sourceLayerId = [int] $sourceLayer.GetAttribute("id")
        $sourceLayerName = $sourceLayer.GetAttribute("name")
        $uniqueLayerName = "__wa_layer_{0:D3}" -f $layerIndex
        $safeLayerName = Get-SafeFileName $sourceLayerName
        $assetFileName = "{0:D2}-{1:D2}-{2}.png" -f ($layerIndex + 1), $sourceLayerId, $safeLayerName
        $rawImagePath = Join-Path $fullLayerAssetDirectory (".raw-" + $assetFileName)
        $atlasImagePath = Join-Path $fullLayerAssetDirectory $assetFileName

        $sourceLayerData = Get-CsvData $sourceLayer $sourceTileCount
        $occupiedCells = Get-OccupiedOutputCells $sourceLayerData
        if ($occupiedCells.Count -gt 0) {
            Invoke-TmxRasterizer $temporaryMapPath $uniqueLayerName $rawImagePath
            try {
                New-LayerAtlas $rawImagePath $atlasImagePath $occupiedCells
            }
            finally {
                if (Test-Path -LiteralPath $rawImagePath) {
                    Remove-Item -LiteralPath $rawImagePath -Force
                }
            }
        }

        $layerData = [uint32[]]::new($tileCount)
        if ($occupiedCells.Count -gt 0) {
            $layerFirstGid = $nextFirstGid
            for ($tileIndex = 0; $tileIndex -lt $occupiedCells.Count; $tileIndex++) {
                $layerData[$occupiedCells[$tileIndex]] = $layerFirstGid + $tileIndex
            }

            $atlasColumns = [Math]::Min(64, $occupiedCells.Count)
            $atlasRows = [int] [Math]::Ceiling($occupiedCells.Count / $atlasColumns)
            $targetTilesets.Add([ordered]@{
                columns = $atlasColumns
                firstgid = $layerFirstGid
                image = "robocon/$layerAssetFolderName/$assetFileName"
                imageheight = $atlasRows * $tileHeight
                imagewidth = $atlasColumns * $tileWidth
                margin = 0
                name = "Layer $sourceLayerId - $sourceLayerName"
                spacing = 0
                tilecount = $occupiedCells.Count
                tileheight = $tileHeight
                tilewidth = $tileWidth
            })
            $nextFirstGid += $occupiedCells.Count
        }

        $layerVisible = -not $sourceLayer.HasAttribute("visible") -or $sourceLayer.GetAttribute("visible") -ne "0"
        $layerOpacity = if ($sourceLayer.HasAttribute("opacity")) { [double] $sourceLayer.GetAttribute("opacity") } else { 1 }
        $layerOffsetX = if ($sourceLayer.HasAttribute("offsetx")) { [double] $sourceLayer.GetAttribute("offsetx") } else { 0 }
        $layerOffsetY = if ($sourceLayer.HasAttribute("offsety")) { [double] $sourceLayer.GetAttribute("offsety") } else { 0 }

        $targetLayers.Add([ordered]@{
            data = $layerData
            height = $height
            id = $sourceLayerId
            name = $sourceLayerName
            offsetx = $layerOffsetX
            offsety = $layerOffsetY
            opacity = $layerOpacity
            type = "tilelayer"
            visible = $layerVisible
            width = $width
            x = 0
            y = 0
        })

        Write-Output "Converted layer $($layerIndex + 1)/$($sourceLayers.Count): $sourceLayerName ($($occupiedCells.Count) occupied 32 px cells)."
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryMapPath) {
        Remove-Item -LiteralPath $temporaryMapPath -Force
    }
}

# Gather collision layers are combined while retaining every visual source
# layer independently. A WorkAdventure cell is blocked when either of its 2x2
# source cells is blocked.
$sourceCollision = [uint32[]]::new($sourceTileCount)
$matchedCollisionLayers = 0
foreach ($sourceLayer in $sourceLayers) {
    if ($CollisionLayers -contains $sourceLayer.GetAttribute("name")) {
        $matchedCollisionLayers++
        $data = Get-CsvData $sourceLayer $sourceTileCount
        for ($index = 0; $index -lt $sourceTileCount; $index++) {
            if (($data[$index] -band 0x1FFFFFFF) -ne 0) {
                $sourceCollision[$index] = 1
            }
        }
    }
}
if ($matchedCollisionLayers -eq 0) {
    throw "None of the requested collision layers were found."
}

$collision = [uint32[]]::new($tileCount)
for ($y = 0; $y -lt $height; $y++) {
    for ($x = 0; $x -lt $width; $x++) {
        $outputIndex = ($y * $width) + $x
        for ($offsetY = 0; $offsetY -lt $sourceCellsPerOutputCellY; $offsetY++) {
            $sourceY = ($y * $sourceCellsPerOutputCellY) + $offsetY
            if ($sourceY -ge $sourceHeight) { continue }
            for ($offsetX = 0; $offsetX -lt $sourceCellsPerOutputCellX; $offsetX++) {
                $sourceX = ($x * $sourceCellsPerOutputCellX) + $offsetX
                if ($sourceX -ge $sourceWidth) { continue }
                if ($sourceCollision[($sourceY * $sourceWidth) + $sourceX] -ne 0) {
                    $collision[$outputIndex] = 1
                }
            }
        }
    }
}

for ($x = 0; $x -lt $width; $x++) {
    $collision[$x] = 1
    $collision[(($height - 1) * $width) + $x] = 1
}
for ($y = 0; $y -lt $height; $y++) {
    $collision[$y * $width] = 1
    $collision[($y * $width) + $width - 1] = 1
}

$collisionFirstGid = $nextFirstGid
$collisionGid = $collisionFirstGid + 2
for ($index = 0; $index -lt $tileCount; $index++) {
    if ($collision[$index] -ne 0) {
        $collision[$index] = $collisionGid
    }
}

$targetTilesets.Add([ordered]@{
    columns = 6
    firstgid = $collisionFirstGid
    image = "tilesets/WA_Special_Zones.png"
    imageheight = 64
    imagewidth = 192
    margin = 0
    name = "WA_Special_Zones"
    spacing = 0
    tilecount = 12
    tileheight = $tileHeight
    tiles = @(
        [ordered]@{
            id = 2
            properties = @(
                [ordered]@{ name = "collides"; type = "bool"; value = $true }
            )
        }
    )
    tilewidth = $tileWidth
})

$highestSourceLayerId = ($sourceLayers | ForEach-Object { [int] $_.GetAttribute("id") } | Measure-Object -Maximum).Maximum
$collisionLayerId = $highestSourceLayerId + 1
$areasLayerId = $collisionLayerId + 1
$targetLayers.Add([ordered]@{
    data = $collision
    height = $height
    id = $collisionLayerId
    name = "collisions"
    opacity = 0
    type = "tilelayer"
    visible = $true
    width = $width
    x = 0
    y = 0
})

$startWidth = 4 * $tileWidth
$startHeight = 3 * $tileHeight
$startX = [Math]::Floor(($outputPixelWidth - $startWidth) / 2)
$startY = $outputPixelHeight - (8 * $tileHeight)
$targetLayers.Add([ordered]@{
    draworder = "topdown"
    id = $areasLayerId
    name = "areas"
    objects = @(
        [ordered]@{
            height = $startHeight
            id = 1
            name = "start"
            properties = @(
                [ordered]@{ name = "start"; type = "bool"; value = $true }
            )
            rotation = 0
            type = "area"
            visible = $true
            width = $startWidth
            x = $startX
            y = $startY
        }
    )
    opacity = 1
    type = "objectgroup"
    visible = $true
    x = 0
    y = 0
})

$mapProperties = [System.Collections.Generic.List[object]]::new()
$mapProperties.Add([ordered]@{ name = "mapDescription"; type = "string"; value = "RoboCon 2026 virtual conference venue, ported as editable layers from Gather." })
$mapProperties.Add([ordered]@{ name = "mapName"; type = "string"; value = $MapName })
$mapProperties.Add([ordered]@{ name = "script"; type = "string"; value = "src/main.ts" })

if (-not [string]::IsNullOrWhiteSpace($PreviewImage)) {
    $previewSourcePath = (Resolve-Path -LiteralPath $PreviewImage).Path
    $previewFileName = "${outputStem}_preview.png"
    $previewTargetPath = Join-Path $assetRoot $previewFileName
    New-Item -ItemType Directory -Force -Path $assetRoot | Out-Null
    Copy-Item -LiteralPath $previewSourcePath -Destination $previewTargetPath -Force
    $mapProperties.Add([ordered]@{ name = "mapImage"; type = "string"; value = "robocon/$previewFileName" })
}

$map = [ordered]@{
    compressionlevel = -1
    height = $height
    infinite = $false
    layers = $targetLayers
    nextlayerid = $areasLayerId + 1
    nextobjectid = 2
    orientation = "orthogonal"
    properties = $mapProperties
    renderorder = "right-down"
    tiledversion = "1.11.2"
    tileheight = $tileHeight
    tilesets = $targetTilesets
    tilewidth = $tileWidth
    type = "map"
    version = "1.10"
    width = $width
}

$json = $map | ConvertTo-Json -Depth 30
Set-Content -LiteralPath $outputMapPath -Value $json -Encoding utf8

$collisionCount = @($collision | Where-Object { $_ -ne 0 }).Count
$visualTileCount = $collisionFirstGid - 1
Write-Output "Created $outputMapPath ($width x $height, $($sourceLayers.Count) retained layers, $visualTileCount visual tiles, $collisionCount collision tiles)."
