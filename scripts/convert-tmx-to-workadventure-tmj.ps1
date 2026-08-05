[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceMap,

    [Parameter(Mandatory = $true)]
    [string]$TilesetImageLibrary,

    [Parameter(Mandatory = $true)]
    [string]$DestinationMap,

    [string]$ForegroundSeparatorLayer = '',

    [string]$ForegroundLayerPattern = '(?i)^(fore|front)'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OptionalInt {
    param(
        [Parameter(Mandatory = $true)][Xml.XmlElement]$Element,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int64]$Default
    )

    if ($Element.HasAttribute($Name)) {
        return [int64]$Element.GetAttribute($Name)
    }
    return $Default
}

function Get-OptionalDouble {
    param(
        [Parameter(Mandatory = $true)][Xml.XmlElement]$Element,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][double]$Default
    )

    if ($Element.HasAttribute($Name)) {
        return [double]::Parse($Element.GetAttribute($Name), [Globalization.CultureInfo]::InvariantCulture)
    }
    return $Default
}

function Get-OptionalBool {
    param(
        [Parameter(Mandatory = $true)][Xml.XmlElement]$Element,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Default
    )

    if ($Element.HasAttribute($Name)) {
        return $Element.GetAttribute($Name) -ne '0'
    }
    return $Default
}

function Convert-TiledProperties {
    param([Xml.XmlNodeList]$PropertyNodes)

    $properties = [Collections.Generic.List[object]]::new()
    foreach ($property in $PropertyNodes) {
        $type = if ($property.HasAttribute('type')) { $property.GetAttribute('type') } else { 'string' }
        $rawValue = if ($property.HasAttribute('value')) { $property.GetAttribute('value') } else { $property.InnerText }
        $value = switch ($type) {
            'bool' { $rawValue -eq 'true' -or $rawValue -eq '1' }
            'int' { [int64]$rawValue }
            'float' { [double]::Parse($rawValue, [Globalization.CultureInfo]::InvariantCulture) }
            default { $rawValue }
        }
        $properties.Add([ordered]@{
            name = $property.GetAttribute('name')
            type = $type
            value = $value
        })
    }
    return @($properties)
}

function Convert-CsvLayerData {
    param(
        [Parameter(Mandatory = $true)][Xml.XmlElement]$Layer,
        [Parameter(Mandatory = $true)][int64]$CanvasWidth,
        [Parameter(Mandatory = $true)][int64]$CanvasHeight,
        [Parameter(Mandatory = $true)][int64]$CoordinateShiftX,
        [Parameter(Mandatory = $true)][int64]$CoordinateShiftY
    )

    $dataNode = $Layer.SelectSingleNode('./data')
    if ($null -eq $dataNode -or $dataNode.GetAttribute('encoding') -ne 'csv' -or $dataNode.HasAttribute('compression')) {
        throw "Layer '$($Layer.GetAttribute('name'))' does not use uncompressed CSV data."
    }

    $chunks = @($dataNode.SelectNodes('./chunk'))
    $canvasCellCount = $CanvasWidth * $CanvasHeight
    if ($canvasCellCount -gt [int]::MaxValue) {
        throw "Layer '$($Layer.GetAttribute('name'))' is too large to flatten."
    }
    $canvasData = [uint64[]]::new([int]$canvasCellCount)

    if ($chunks.Count -gt 0) {
        foreach ($chunk in $chunks) {
            $chunkWidth = [int64]$chunk.GetAttribute('width')
            $chunkHeight = [int64]$chunk.GetAttribute('height')
            $chunkValues = [Collections.Generic.List[uint64]]::new()
            foreach ($value in $chunk.InnerText -split '[,\s]+') {
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $chunkValues.Add([uint64]$value)
                }
            }
            if ($chunkValues.Count -ne $chunkWidth * $chunkHeight) {
                throw "Chunk in layer '$($Layer.GetAttribute('name'))' contains $($chunkValues.Count) cells; expected $($chunkWidth * $chunkHeight)."
            }

            $destinationX = [int64]$chunk.GetAttribute('x') + $CoordinateShiftX
            $destinationY = [int64]$chunk.GetAttribute('y') + $CoordinateShiftY
            if ($destinationX -lt 0 -or $destinationY -lt 0 -or $destinationX + $chunkWidth -gt $CanvasWidth -or $destinationY + $chunkHeight -gt $CanvasHeight) {
                throw "Chunk in layer '$($Layer.GetAttribute('name'))' falls outside the flattened map canvas."
            }
            for ($y = 0; $y -lt $chunkHeight; $y++) {
                for ($x = 0; $x -lt $chunkWidth; $x++) {
                    $sourceIndex = $y * $chunkWidth + $x
                    $destinationIndex = ($destinationY + $y) * $CanvasWidth + $destinationX + $x
                    $canvasData[[int]$destinationIndex] = $chunkValues[[int]$sourceIndex]
                }
            }
        }
        return $canvasData
    }

    $sourceData = [Collections.Generic.List[uint64]]::new()
    foreach ($value in $dataNode.InnerText -split '[,\s]+') {
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $sourceData.Add([uint64]$value)
        }
    }
    $sourceWidth = [int64]$Layer.GetAttribute('width')
    $sourceHeight = [int64]$Layer.GetAttribute('height')
    $expectedCells = $sourceWidth * $sourceHeight
    if ($sourceData.Count -eq 0) {
        return $canvasData
    }
    if ($sourceData.Count -ne $expectedCells) {
        throw "Layer '$($Layer.GetAttribute('name'))' contains $($sourceData.Count) cells; expected $expectedCells."
    }

    $destinationX = Get-OptionalInt -Element $Layer -Name 'x' -Default 0
    $destinationY = Get-OptionalInt -Element $Layer -Name 'y' -Default 0
    $destinationX += $CoordinateShiftX
    $destinationY += $CoordinateShiftY
    if ($destinationX -lt 0 -or $destinationY -lt 0 -or $destinationX + $sourceWidth -gt $CanvasWidth -or $destinationY + $sourceHeight -gt $CanvasHeight) {
        throw "Layer '$($Layer.GetAttribute('name'))' falls outside the flattened map canvas."
    }
    for ($y = 0; $y -lt $sourceHeight; $y++) {
        for ($x = 0; $x -lt $sourceWidth; $x++) {
            $sourceIndex = $y * $sourceWidth + $x
            $destinationIndex = ($destinationY + $y) * $CanvasWidth + $destinationX + $x
            $canvasData[[int]$destinationIndex] = $sourceData[[int]$sourceIndex]
        }
    }
    return $canvasData
}

function New-FloorLayer {
    param([Parameter(Mandatory = $true)][int64]$Id)

    return [ordered]@{
        draworder = 'topdown'
        id = $Id
        name = 'floorLayer'
        objects = @()
        opacity = 1.0
        type = 'objectgroup'
        visible = $true
        x = 0
        y = 0
    }
}

$sourceMapPath = (Resolve-Path -LiteralPath $SourceMap).Path
$sourceMapDirectory = Split-Path -Parent $sourceMapPath
$libraryPath = (Resolve-Path -LiteralPath $TilesetImageLibrary).Path
$destinationMapPath = [IO.Path]::GetFullPath($DestinationMap)
$destinationMapDirectory = Split-Path -Parent $destinationMapPath

$mapDocument = [Xml.XmlDocument]::new()
$mapDocument.Load($sourceMapPath)
$mapRoot = $mapDocument.DocumentElement
if ($null -eq $mapRoot -or $mapRoot.LocalName -ne 'map') {
    throw "Not a Tiled TMX map: $sourceMapPath"
}

if ($mapRoot.GetAttribute('orientation') -ne 'orthogonal') {
    throw 'Only orthogonal maps are supported by this converter.'
}

$sourceMapWidth = [int64]$mapRoot.GetAttribute('width')
$sourceMapHeight = [int64]$mapRoot.GetAttribute('height')
$canvasMinimumX = [int64]0
$canvasMinimumY = [int64]0
$canvasMaximumX = $sourceMapWidth
$canvasMaximumY = $sourceMapHeight
$chunkNodes = @($mapRoot.SelectNodes('./layer/data/chunk'))
foreach ($chunk in $chunkNodes) {
    $chunkX = [int64]$chunk.GetAttribute('x')
    $chunkY = [int64]$chunk.GetAttribute('y')
    $chunkRight = $chunkX + [int64]$chunk.GetAttribute('width')
    $chunkBottom = $chunkY + [int64]$chunk.GetAttribute('height')
    $canvasMinimumX = [math]::Min($canvasMinimumX, $chunkX)
    $canvasMinimumY = [math]::Min($canvasMinimumY, $chunkY)
    $canvasMaximumX = [math]::Max($canvasMaximumX, $chunkRight)
    $canvasMaximumY = [math]::Max($canvasMaximumY, $chunkBottom)
}
$outputMapWidth = $canvasMaximumX - $canvasMinimumX
$outputMapHeight = $canvasMaximumY - $canvasMinimumY
$coordinateShiftX = -$canvasMinimumX
$coordinateShiftY = -$canvasMinimumY

$mapsDirectory = $null
$directoryCursor = [IO.DirectoryInfo]$sourceMapDirectory
while ($null -ne $directoryCursor) {
    if ($directoryCursor.Name -ieq 'Maps') {
        $mapsDirectory = $directoryCursor.FullName
        break
    }
    $directoryCursor = $directoryCursor.Parent
}
$sourceLookupRoot = if ($null -ne $mapsDirectory) {
    Split-Path -Parent $mapsDirectory
}
else {
    $sourceMapDirectory
}
$mapReferenceBase = if ($null -ne $mapsDirectory -and $sourceMapPath.Contains('_Archive_previous_years')) {
    $mapsDirectory
}
else {
    $sourceMapDirectory
}

$script:sourceFileIndex = $null
function Resolve-SourceFile {
    param(
        [Parameter(Mandatory = $true)][string]$BaseDirectory,
        [Parameter(Mandatory = $true)][string]$Reference
    )

    try {
        $candidate = if ([IO.Path]::IsPathRooted($Reference)) {
            [IO.Path]::GetFullPath($Reference)
        }
        else {
            [IO.Path]::GetFullPath((Join-Path $BaseDirectory $Reference))
        }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    catch {
        # Fall through to filename lookup for stale absolute or relocated references.
    }

    if ($null -eq $script:sourceFileIndex) {
        $script:sourceFileIndex = @{}
        foreach ($sourceFile in Get-ChildItem -LiteralPath $sourceLookupRoot -Recurse -File) {
            $key = $sourceFile.Name.ToLowerInvariant()
            if (-not $script:sourceFileIndex.ContainsKey($key)) {
                $script:sourceFileIndex[$key] = [Collections.Generic.List[string]]::new()
            }
            $script:sourceFileIndex[$key].Add($sourceFile.FullName)
        }
    }

    $leafName = [IO.Path]::GetFileName($Reference).ToLowerInvariant()
    if ($script:sourceFileIndex.ContainsKey($leafName)) {
        $matches = @($script:sourceFileIndex[$leafName])
        if ($matches.Count -eq 1) {
            return $matches[0]
        }
    }
    return $null
}

$layerDataById = @{}
$usedGids = [Collections.Generic.HashSet[uint64]]::new()
foreach ($sourceTileLayer in $mapRoot.SelectNodes('./layer')) {
    $sourceLayerName = $sourceTileLayer.GetAttribute('name')
    $isSeparatorLayer = (-not [string]::IsNullOrWhiteSpace($ForegroundSeparatorLayer) -and $sourceLayerName -eq $ForegroundSeparatorLayer) -or
        $sourceLayerName -match '(?i)^(separator|-+)$'
    if ($isSeparatorLayer) {
        continue
    }
    $layerData = @(Convert-CsvLayerData -Layer $sourceTileLayer -CanvasWidth $outputMapWidth -CanvasHeight $outputMapHeight -CoordinateShiftX $coordinateShiftX -CoordinateShiftY $coordinateShiftY)
    $layerDataById[$sourceTileLayer.GetAttribute('id')] = $layerData
    foreach ($rawGid in $layerData) {
        $gid = [uint64]$rawGid -band [uint64]0x0FFFFFFF
        if ($gid -ne 0) {
            [void]$usedGids.Add($gid)
        }
    }
}

$imageByHash = @{}
$libraryImagesByName = @{}
$imageDimensionsByPath = @{}
Add-Type -AssemblyName System.Drawing
function Get-ImageDimensions {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not $imageDimensionsByPath.ContainsKey($Path)) {
        $image = [Drawing.Image]::FromFile($Path)
        try {
            $imageDimensionsByPath[$Path] = [pscustomobject]@{
                width = [int64]$image.Width
                height = [int64]$image.Height
            }
        }
        finally {
            $image.Dispose()
        }
    }
    return $imageDimensionsByPath[$Path]
}
foreach ($libraryImage in Get-ChildItem -LiteralPath $libraryPath -Recurse -File) {
    if ($libraryImage.Extension -notin @('.png', '.jpg', '.jpeg', '.webp')) {
        continue
    }
    $hash = (Get-FileHash -LiteralPath $libraryImage.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($imageByHash.ContainsKey($hash)) {
        throw "Duplicate image content in library: $($libraryImage.FullName) and $($imageByHash[$hash])"
    }
    $imageByHash[$hash] = $libraryImage.FullName
    $imageNameKey = $libraryImage.Name.ToLowerInvariant()
    if (-not $libraryImagesByName.ContainsKey($imageNameKey)) {
        $libraryImagesByName[$imageNameKey] = [Collections.Generic.List[string]]::new()
    }
    $libraryImagesByName[$imageNameKey].Add($libraryImage.FullName)
}

$mapTilesets = @($mapRoot.SelectNodes('./tileset') | Sort-Object { [int64]$_.GetAttribute('firstgid') })
$tilesets = [Collections.Generic.List[object]]::new()
$omittedTilesets = [Collections.Generic.List[string]]::new()
for ($tilesetIndex = 0; $tilesetIndex -lt $mapTilesets.Count; $tilesetIndex++) {
    $mapTileset = $mapTilesets[$tilesetIndex]
    $firstGid = [int64]$mapTileset.GetAttribute('firstgid')
    $nextFirstGid = [int64]::MaxValue
    for ($nextTilesetIndex = $tilesetIndex + 1; $nextTilesetIndex -lt $mapTilesets.Count; $nextTilesetIndex++) {
        $candidateFirstGid = [int64]$mapTilesets[$nextTilesetIndex].GetAttribute('firstgid')
        if ($candidateFirstGid -gt $firstGid) {
            $nextFirstGid = $candidateFirstGid
            break
        }
    }
    $tilesetIsUsed = $false
    foreach ($usedGid in $usedGids) {
        if ($usedGid -ge $firstGid -and $usedGid -lt $nextFirstGid) {
            $tilesetIsUsed = $true
            break
        }
    }
    if (-not $tilesetIsUsed) {
        $omittedName = if ($mapTileset.HasAttribute('name')) { $mapTileset.GetAttribute('name') } else { $mapTileset.GetAttribute('source') }
        $omittedTilesets.Add($omittedName)
        continue
    }

    $externalReference = $mapTileset.GetAttribute('source')
    if (-not [string]::IsNullOrWhiteSpace($externalReference)) {
        $definitionPath = Resolve-SourceFile -BaseDirectory $mapReferenceBase -Reference $externalReference
        if ($null -eq $definitionPath) {
            throw "Tileset definition not found for reference: $externalReference"
        }
        $tilesetDocument = [Xml.XmlDocument]::new()
        $tilesetDocument.Load($definitionPath)
        $tilesetRoot = $tilesetDocument.DocumentElement
        $imageBaseDirectory = Split-Path -Parent $definitionPath
    }
    else {
        $tilesetRoot = $mapTileset
        $imageBaseDirectory = $mapReferenceBase
    }

    $tilesetLastGidExclusive = $firstGid + [int64]$tilesetRoot.GetAttribute('tilecount')
    $tilesetHasValidUsedGid = $false
    foreach ($usedGid in $usedGids) {
        if ($usedGid -ge $firstGid -and $usedGid -lt $tilesetLastGidExclusive) {
            $tilesetHasValidUsedGid = $true
            break
        }
    }
    if (-not $tilesetHasValidUsedGid) {
        $omittedTilesets.Add($tilesetRoot.GetAttribute('name'))
        continue
    }

    $unsupportedMetadata = @($tilesetRoot.SelectNodes('./tile|./wangsets|./terraintypes|./transformations|./tileoffset'))
    if ($unsupportedMetadata.Count -gt 0) {
        throw "Tileset '$($tilesetRoot.GetAttribute('name'))' contains metadata this converter does not handle."
    }

    $imageNodes = @($tilesetRoot.SelectNodes('./image[@source]'))
    if ($imageNodes.Count -ne 1) {
        throw "Tileset '$($tilesetRoot.GetAttribute('name'))' must contain exactly one root image."
    }
    $imageNode = $imageNodes[0]
    $sourceImagePath = Resolve-SourceFile -BaseDirectory $imageBaseDirectory -Reference $imageNode.GetAttribute('source')
    if ($null -eq $sourceImagePath) {
        $missingImageName = [IO.Path]::GetFileName($imageNode.GetAttribute('source')).ToLowerInvariant()
        $libraryNameMatches = @()
        if ($libraryImagesByName.ContainsKey($missingImageName)) {
            $libraryNameMatches = @($libraryImagesByName[$missingImageName])
        }
        if ($libraryNameMatches.Count -ne 1) {
            throw "Tileset image not found for reference: $($imageNode.GetAttribute('source'))"
        }
        $libraryImagePath = $libraryNameMatches[0]
    }
    else {
        $imageHash = (Get-FileHash -LiteralPath $sourceImagePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not $imageByHash.ContainsKey($imageHash)) {
            throw "No checksum-identical library image found for: $sourceImagePath"
        }
        $libraryImagePath = $imageByHash[$imageHash]
    }
    $relativeImagePath = [IO.Path]::GetRelativePath($destinationMapDirectory, $libraryImagePath).Replace('\', '/')
    $imageDimensions = Get-ImageDimensions -Path $libraryImagePath
    $tileset = [ordered]@{
        columns = [int64]$tilesetRoot.GetAttribute('columns')
        firstgid = [int64]$mapTileset.GetAttribute('firstgid')
        image = $relativeImagePath
        imageheight = $imageDimensions.height
        imagewidth = $imageDimensions.width
        margin = Get-OptionalInt -Element $tilesetRoot -Name 'margin' -Default 0
        name = $tilesetRoot.GetAttribute('name')
        spacing = Get-OptionalInt -Element $tilesetRoot -Name 'spacing' -Default 0
        tilecount = [int64]$tilesetRoot.GetAttribute('tilecount')
        tileheight = [int64]$tilesetRoot.GetAttribute('tileheight')
        tilewidth = [int64]$tilesetRoot.GetAttribute('tilewidth')
    }
    if ($imageNode.HasAttribute('trans')) {
        $tileset['transparentcolor'] = "#$($imageNode.GetAttribute('trans'))"
    }
    $tilesetProperties = @(Convert-TiledProperties -PropertyNodes $tilesetRoot.SelectNodes('./properties/property'))
    if ($tilesetProperties.Count -gt 0) {
        $tileset['properties'] = $tilesetProperties
    }
    $tilesets.Add($tileset)
}

$sourceLayers = @($mapRoot.SelectNodes('./layer'))
$separatorLayers = @($sourceLayers | Where-Object {
    $layerName = $_.GetAttribute('name')
    (-not [string]::IsNullOrWhiteSpace($ForegroundSeparatorLayer) -and $layerName -eq $ForegroundSeparatorLayer) -or
    $layerName -match '(?i)^(separator|-+)$'
})
if ($separatorLayers.Count -gt 1) {
    throw "Multiple foreground separator layers were found: $(@($separatorLayers | ForEach-Object { $_.GetAttribute('name') }) -join ', ')"
}
$separatorLayer = if ($separatorLayers.Count -eq 1) { $separatorLayers[0] } else { $null }
$firstForegroundLayer = @()
if ($null -eq $separatorLayer) {
    $firstForegroundLayer = @($sourceLayers | Where-Object { $_.GetAttribute('name') -match $ForegroundLayerPattern } | Select-Object -First 1)
}

$sourceNextLayerId = Get-OptionalInt -Element $mapRoot -Name 'nextlayerid' -Default 1
$floorLayerId = if ($null -ne $separatorLayer) {
    [int64]$separatorLayer.GetAttribute('id')
}
else {
    $sourceNextLayerId
}
$outputNextLayerId = if ($null -ne $separatorLayer) { $sourceNextLayerId } else { $floorLayerId + 1 }
$floorPlacement = if ($null -ne $separatorLayer) {
    "replaced '$($separatorLayer.GetAttribute('name'))'"
}
elseif ($firstForegroundLayer.Count -eq 1) {
    "inserted before '$($firstForegroundLayer[0].GetAttribute('name'))'"
}
else {
    'appended after tile layers'
}

$layers = [Collections.Generic.List[object]]::new()
$floorLayerInserted = $false
$skippedImageLayers = [Collections.Generic.List[string]]::new()
foreach ($sourceLayer in $mapRoot.ChildNodes) {
    if ($sourceLayer.NodeType -ne [Xml.XmlNodeType]::Element -or $sourceLayer.LocalName -notin @('layer', 'objectgroup', 'imagelayer', 'group')) {
        continue
    }
    if ($sourceLayer.LocalName -eq 'imagelayer') {
        $skippedImageLayers.Add($sourceLayer.GetAttribute('name'))
        continue
    }
    if ($sourceLayer.LocalName -ne 'layer') {
        throw "Unsupported source layer type '$($sourceLayer.LocalName)' on layer '$($sourceLayer.GetAttribute('name'))'."
    }

    if ($null -ne $separatorLayer -and $sourceLayer -eq $separatorLayer) {
        $layers.Add((New-FloorLayer -Id $floorLayerId))
        $floorLayerInserted = $true
        continue
    }

    if (-not $floorLayerInserted -and $firstForegroundLayer.Count -eq 1 -and $sourceLayer -eq $firstForegroundLayer[0]) {
        $layers.Add((New-FloorLayer -Id $floorLayerId))
        $floorLayerInserted = $true
    }

    $data = $layerDataById[$sourceLayer.GetAttribute('id')]

    $layer = [ordered]@{
        data = @($data)
        height = $outputMapHeight
        id = [int64]$sourceLayer.GetAttribute('id')
        name = $sourceLayer.GetAttribute('name')
        opacity = Get-OptionalDouble -Element $sourceLayer -Name 'opacity' -Default 1.0
        type = 'tilelayer'
        visible = Get-OptionalBool -Element $sourceLayer -Name 'visible' -Default $true
        width = $outputMapWidth
        x = 0
        y = 0
    }
    if ($sourceLayer.HasAttribute('offsetx')) {
        $layer['offsetx'] = Get-OptionalDouble -Element $sourceLayer -Name 'offsetx' -Default 0
    }
    if ($sourceLayer.HasAttribute('offsety')) {
        $layer['offsety'] = Get-OptionalDouble -Element $sourceLayer -Name 'offsety' -Default 0
    }
    if ($sourceLayer.HasAttribute('locked')) {
        $layer['locked'] = Get-OptionalBool -Element $sourceLayer -Name 'locked' -Default $false
    }
    $layerProperties = @(Convert-TiledProperties -PropertyNodes $sourceLayer.SelectNodes('./properties/property'))
    if ($layerProperties.Count -gt 0) {
        $layer['properties'] = $layerProperties
    }
    $layers.Add($layer)
}

if (-not $floorLayerInserted) {
    $layers.Add((New-FloorLayer -Id $floorLayerId))
    $floorLayerInserted = $true
}

$map = [ordered]@{
    compressionlevel = -1
    height = $outputMapHeight
    infinite = $false
    layers = @($layers)
    nextlayerid = $outputNextLayerId
    nextobjectid = Get-OptionalInt -Element $mapRoot -Name 'nextobjectid' -Default 1
    orientation = $mapRoot.GetAttribute('orientation')
    renderorder = $mapRoot.GetAttribute('renderorder')
    tiledversion = $mapRoot.GetAttribute('tiledversion')
    tileheight = [int64]$mapRoot.GetAttribute('tileheight')
    tilesets = @($tilesets)
    tilewidth = [int64]$mapRoot.GetAttribute('tilewidth')
    type = 'map'
    version = $mapRoot.GetAttribute('version')
    width = $outputMapWidth
}
$mapProperties = @(Convert-TiledProperties -PropertyNodes $mapRoot.SelectNodes('./properties/property'))
if ($mapProperties.Count -gt 0) {
    $map['properties'] = $mapProperties
}

$destinationParent = Split-Path -Parent $destinationMapPath
if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
    New-Item -ItemType Directory -Path $destinationParent | Out-Null
}
$map | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $destinationMapPath -Encoding utf8NoBOM

Write-Output "Source: $sourceMapPath"
Write-Output "Destination: $destinationMapPath"
Write-Output "Map: $($map.width)x$($map.height) tiles at $($map.tilewidth)x$($map.tileheight) pixels"
if ($chunkNodes.Count -gt 0) {
    Write-Output "Flattened infinite chunks with coordinate shift ($coordinateShiftX, $coordinateShiftY)"
}
Write-Output "Layers: $($layers.Count) (including floorLayer)"
Write-Output "Embedded tilesets: $($tilesets.Count)"
Write-Output "Unused tilesets omitted: $($omittedTilesets.Count)"
Write-Output "floorLayer: $floorPlacement"
if ($skippedImageLayers.Count -gt 0) {
    Write-Output "Skipped image guide layers: $($skippedImageLayers -join ', ')"
}
