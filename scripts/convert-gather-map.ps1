param(
    [Parameter(Mandatory = $true)]
    [string] $SourceMap,

    [Parameter(Mandatory = $true)]
    [string] $BackgroundImage,

    [Parameter(Mandatory = $true)]
    [string] $ForegroundImage,

    [Parameter(Mandatory = $true)]
    [string] $OutputMap,

    [string] $MapName = "RoboCon 2026",

    [string[]] $CollisionLayers = @("Walls", "Furniture", "Lounge", "Hall Seating", "Screen"),

    [double] $ArtworkScale = 1.0
)

$ErrorActionPreference = "Stop"

[xml] $source = Get-Content -LiteralPath $SourceMap
[System.Xml.XmlElement] $sourceMap = $source.SelectSingleNode("/map")
$sourceWidth = [int] $sourceMap.GetAttribute("width")
$sourceHeight = [int] $sourceMap.GetAttribute("height")
$sourceTileWidth = [int] $sourceMap.GetAttribute("tilewidth")
$sourceTileHeight = [int] $sourceMap.GetAttribute("tileheight")
$sourceTileCount = $sourceWidth * $sourceHeight

if ($sourceTileWidth -ne 16 -or $sourceTileHeight -ne 16) {
    throw "The converter currently expects a 16x16 Gather map."
}

# WorkAdventure's world grid and player sprites are 32 px. The Gather render is
# scaled to the requested visual size, and enough source cells are combined to
# keep collision geometry aligned to the 32 px WorkAdventure grid.
$tileWidth = 32
$tileHeight = 32
$sourcePixelWidth = $sourceWidth * $sourceTileWidth
$sourcePixelHeight = $sourceHeight * $sourceTileHeight
$scaledSourceTileWidth = $sourceTileWidth * $ArtworkScale
$scaledSourceTileHeight = $sourceTileHeight * $ArtworkScale
$sourceCellsPerOutputCellX = $tileWidth / $scaledSourceTileWidth
$sourceCellsPerOutputCellY = $tileHeight / $scaledSourceTileHeight

if ($ArtworkScale -le 0 -or
    $sourceCellsPerOutputCellX -ne [Math]::Floor($sourceCellsPerOutputCellX) -or
    $sourceCellsPerOutputCellY -ne [Math]::Floor($sourceCellsPerOutputCellY)) {
    throw "ArtworkScale must produce a whole number of Gather cells per 32 px WorkAdventure cell."
}

$sourceCellsPerOutputCellX = [int] $sourceCellsPerOutputCellX
$sourceCellsPerOutputCellY = [int] $sourceCellsPerOutputCellY
$collisionWidth = [Math]::Ceiling($sourceWidth / $sourceCellsPerOutputCellX)
$collisionHeight = [Math]::Ceiling($sourceHeight / $sourceCellsPerOutputCellY)

Add-Type -AssemblyName System.Drawing

function Get-ImageSize([string] $path) {
    $image = [System.Drawing.Image]::FromFile($path)
    try {
        return @{ width = $image.Width; height = $image.Height }
    }
    finally {
        $image.Dispose()
    }
}

function Copy-ScaledImage([string] $sourcePath, [string] $targetPath, [double] $scale, [int] $canvasWidth, [int] $canvasHeight) {
    $sourceImage = [System.Drawing.Bitmap]::FromFile($sourcePath)
    $targetWidth = [int] [Math]::Round($sourceImage.Width * $scale)
    $targetHeight = [int] [Math]::Round($sourceImage.Height * $scale)
    $targetImage = New-Object System.Drawing.Bitmap $canvasWidth, $canvasHeight
    $graphics = [System.Drawing.Graphics]::FromImage($targetImage)
    try {
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
        $graphics.DrawImage($sourceImage, 0, 0, $targetWidth, $targetHeight)
        $targetImage.Save($targetPath, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $targetImage.Dispose()
        $sourceImage.Dispose()
    }
}

function Get-CsvData($layer, [int] $expectedCount) {
    $values = @($layer.data.'#text' -split '[,\s]+' | Where-Object { $_ -ne '' } | ForEach-Object { [uint32] $_ })
    if ($values.Count -ne $expectedCount) {
        throw "Layer '$($layer.GetAttribute('name'))' contains $($values.Count) tiles; expected $expectedCount."
    }
    return $values
}

$backgroundSize = Get-ImageSize $BackgroundImage
$foregroundSize = Get-ImageSize $ForegroundImage
if ($backgroundSize.width -ne $sourcePixelWidth -or [Math]::Abs($backgroundSize.height - $sourcePixelHeight) -gt 2) {
    throw "Background dimensions $($backgroundSize.width)x$($backgroundSize.height) do not match map dimensions ${sourcePixelWidth}x${sourcePixelHeight}."
}
if ($foregroundSize.width -ne $backgroundSize.width -or $foregroundSize.height -ne $backgroundSize.height) {
    throw "Foreground and background dimensions differ."
}

# Keep every source pixel. The canvas is padded (never stretched) to a whole
# number of 32 px WorkAdventure tiles.
$scaledArtworkWidth = [int] [Math]::Round($backgroundSize.width * $ArtworkScale)
$scaledArtworkHeight = [int] [Math]::Round($backgroundSize.height * $ArtworkScale)
$width = [Math]::Max($collisionWidth, [Math]::Ceiling($scaledArtworkWidth / $tileWidth))
$height = [Math]::Max($collisionHeight, [Math]::Ceiling($scaledArtworkHeight / $tileHeight))
$tileCount = $width * $height

$sourceCollision = [uint32[]]::new($sourceTileCount)
$matchedLayers = 0
foreach ($layer in $sourceMap.SelectNodes("layer")) {
    if ($CollisionLayers -contains $layer.GetAttribute('name')) {
        $matchedLayers++
        $data = Get-CsvData $layer $sourceTileCount
        for ($index = 0; $index -lt $sourceTileCount; $index++) {
            if ($data[$index] -ne 0) {
                $sourceCollision[$index] = 1
            }
        }
    }
}

if ($matchedLayers -eq 0) {
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

# Always close the outer edge. This prevents players from walking into the void if
# a decorative source layer leaves a transparent tile at the map boundary.
for ($x = 0; $x -lt $width; $x++) {
    $collision[$x] = 1
    $collision[(($height - 1) * $width) + $x] = 1
}
for ($y = 0; $y -lt $height; $y++) {
    $collision[$y * $width] = 1
    $collision[($y * $width) + $width - 1] = 1
}

$backgroundFirstGid = 1
$foregroundFirstGid = $backgroundFirstGid + $tileCount
$collisionFirstGid = $foregroundFirstGid + $tileCount
$collisionGid = $collisionFirstGid + 2

$background = [uint32[]]::new($tileCount)
$foreground = [uint32[]]::new($tileCount)
for ($index = 0; $index -lt $tileCount; $index++) {
    $background[$index] = $backgroundFirstGid + $index
    $foreground[$index] = $foregroundFirstGid + $index
}

for ($index = 0; $index -lt $tileCount; $index++) {
    if ($collision[$index] -ne 0) {
        $collision[$index] = $collisionGid
    }
}

$outputDirectory = Split-Path -Parent $OutputMap
$outputStem = [System.IO.Path]::GetFileNameWithoutExtension($OutputMap)
$backgroundFileName = "${outputStem}_BG.png"
$foregroundFileName = "${outputStem}_FG.png"
$backgroundRelativePath = "robocon/$backgroundFileName"
$foregroundRelativePath = "robocon/$foregroundFileName"
$backgroundTarget = Join-Path $outputDirectory "robocon\$backgroundFileName"
$foregroundTarget = Join-Path $outputDirectory "robocon\$foregroundFileName"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backgroundTarget) | Out-Null
$outputPixelWidth = $width * $tileWidth
$outputPixelHeight = $height * $tileHeight
Copy-ScaledImage $BackgroundImage $backgroundTarget $ArtworkScale $outputPixelWidth $outputPixelHeight
Copy-ScaledImage $ForegroundImage $foregroundTarget $ArtworkScale $outputPixelWidth $outputPixelHeight

$startWidth = 4 * $tileWidth
$startHeight = 3 * $tileHeight
$startX = [Math]::Floor(($outputPixelWidth - $startWidth) / 2)
$startY = $outputPixelHeight - (8 * $tileHeight)

$map = [ordered]@{
    compressionlevel = -1
    height = $height
    infinite = $false
    layers = @(
        [ordered]@{
            data = $background
            height = $height
            id = 1
            name = "background"
            opacity = 1
            type = "tilelayer"
            visible = $true
            width = $width
            x = 0
            y = 0
        },
        [ordered]@{
            data = $collision
            height = $height
            id = 2
            name = "collisions"
            opacity = 0
            type = "tilelayer"
            visible = $true
            width = $width
            x = 0
            y = 0
        },
        [ordered]@{
            draworder = "topdown"
            id = 3
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
        },
        [ordered]@{
            data = $foreground
            height = $height
            id = 4
            name = "above"
            opacity = 1
            type = "tilelayer"
            visible = $true
            width = $width
            x = 0
            y = 0
        }
    )
    nextlayerid = 5
    nextobjectid = 2
    orientation = "orthogonal"
    properties = @(
        [ordered]@{ name = "mapDescription"; type = "string"; value = "RoboCon 2026 virtual conference venue, ported from Gather." },
        [ordered]@{ name = "mapImage"; type = "string"; value = $backgroundRelativePath },
        [ordered]@{ name = "mapName"; type = "string"; value = $MapName },
        [ordered]@{ name = "script"; type = "string"; value = "src/main.ts" }
    )
    renderorder = "right-down"
    tiledversion = "1.11.2"
    tileheight = $tileHeight
    tilesets = @(
        [ordered]@{
            columns = $width
            firstgid = $backgroundFirstGid
            image = $backgroundRelativePath
            imageheight = $outputPixelHeight
            imagewidth = $outputPixelWidth
            margin = 0
            name = "${outputStem}_BG"
            spacing = 0
            tilecount = $tileCount
            tileheight = $tileHeight
            tilewidth = $tileWidth
        },
        [ordered]@{
            columns = $width
            firstgid = $foregroundFirstGid
            image = $foregroundRelativePath
            imageheight = $outputPixelHeight
            imagewidth = $outputPixelWidth
            margin = 0
            name = "${outputStem}_FG"
            spacing = 0
            tilecount = $tileCount
            tileheight = $tileHeight
            tilewidth = $tileWidth
        },
        [ordered]@{
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
        }
    )
    tilewidth = $tileWidth
    type = "map"
    version = "1.10"
    width = $width
}

$json = $map | ConvertTo-Json -Depth 20
Set-Content -LiteralPath $OutputMap -Value $json -Encoding utf8

$collisionCount = @($collision | Where-Object { $_ -ne 0 }).Count
Write-Output "Created $OutputMap ($width x $height, $collisionCount collision tiles, $matchedLayers source layers)."
