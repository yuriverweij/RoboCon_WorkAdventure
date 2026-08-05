[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,

    [Parameter(Mandatory = $true)]
    [string]$DestinationDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SafeSlug {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value -match '^(?i)Tile([A-E]\d*)$') {
        $Value = "tile-$($Matches[1])"
    }
    $normalized = $Value.Replace('ß', 'ss').Normalize([Text.NormalizationForm]::FormD)
    $ascii = -join @(
        foreach ($character in $normalized.ToCharArray()) {
            $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($character)
            if ($category -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
                $character
            }
        }
    )
    $slug = ($ascii.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        return 'image'
    }
    return $slug
}

function Get-ImageCategory {
    param([Parameter(Mandatory = $true)][string]$FileName)

    $name = [IO.Path]::GetFileNameWithoutExtension($FileName)
    switch -Regex ($name) {
        '(?i)(galaxy|parallax|shadow|glow)' { return 'effects' }
        '(?i)^(after|arrows?|confhall|covid-safe|rffooter|robot-bar|robotbar45|shuttlebay|speakers|sprints|world)' { return 'signage' }
        '(?i)(^bop$|^bqa|humanitec|^imbus$|indexnine|^ocr|^ocra|rflogo|robocon logo|^robocon$|sponsors?|^silver$)' { return 'branding' }
        '(?i)(teslacoils|doors|pandamaru|diverse|decoration|tables|robocorp|robotbarshorter|^screen|^shuttle$|slido|space stuff|^stuff$)' { return 'objects' }
        default { return 'environment' }
    }
}

function Get-UniqueFileName {
    param(
        [Parameter(Mandatory = $true)][string]$PreferredBaseName,
        [Parameter(Mandatory = $true)][string]$Extension,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.HashSet[string]]$UsedNames
    )

    $candidate = "$PreferredBaseName$Extension"
    $suffix = 2
    while (-not $UsedNames.Add($candidate)) {
        $candidate = "$PreferredBaseName-$suffix$Extension"
        $suffix++
    }
    return $candidate
}

$sourcePath = (Resolve-Path -LiteralPath $SourceRoot).Path
$mapsPath = Join-Path $sourcePath 'Maps'
if (-not (Test-Path -LiteralPath $mapsPath -PathType Container)) {
    throw "Maps directory not found: $mapsPath"
}

$destinationPath = [IO.Path]::GetFullPath($DestinationDirectory)
if (Test-Path -LiteralPath $destinationPath) {
    $existingItems = @(Get-ChildItem -LiteralPath $destinationPath -Force)
    if ($existingItems.Count -gt 0) {
        throw "Destination is not empty: $destinationPath"
    }
}
else {
    New-Item -ItemType Directory -Path $destinationPath | Out-Null
}

$fileIndex = @{}
foreach ($file in Get-ChildItem -LiteralPath $sourcePath -Recurse -File) {
    $key = $file.Name.ToLowerInvariant()
    if (-not $fileIndex.ContainsKey($key)) {
        $fileIndex[$key] = [Collections.Generic.List[string]]::new()
    }
    $fileIndex[$key].Add($file.FullName)
}

function Resolve-AvailableFile {
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
        # Fall through to the filename lookup for stale absolute references.
    }

    $leafName = [IO.Path]::GetFileName($Reference).ToLowerInvariant()
    if ($fileIndex.ContainsKey($leafName)) {
        $matches = @($fileIndex[$leafName])
        if ($matches.Count -eq 1) {
            return $matches[0]
        }
    }
    return $null
}

$references = [Collections.Generic.List[object]]::new()
$unresolved = [Collections.Generic.List[object]]::new()
$mapFiles = @(Get-ChildItem -LiteralPath $mapsPath -Recurse -Filter '*.tmx' -File)

foreach ($mapFile in $mapFiles) {
    # Archived maps were moved into a subdirectory without updating their paths.
    # Resolve their references as though the maps were still directly under Maps/.
    $isArchived = $mapFile.FullName.Contains('_Archive_previous_years')
    $mapReferenceBase = if ($isArchived) { $mapsPath } else { $mapFile.DirectoryName }

    $mapDocument = [Xml.XmlDocument]::new()
    $mapDocument.Load($mapFile.FullName)
    foreach ($mapTileset in $mapDocument.DocumentElement.SelectNodes('./tileset')) {
        $externalReference = $mapTileset.GetAttribute('source')
        if (-not [string]::IsNullOrWhiteSpace($externalReference)) {
            $definitionPath = Resolve-AvailableFile -BaseDirectory $mapReferenceBase -Reference $externalReference
            if ($null -eq $definitionPath) {
                $unresolved.Add([pscustomobject]@{
                    map = $mapFile.Name
                    kind = 'definition'
                    tileset = ''
                    reference = $externalReference
                })
                continue
            }

            $definitionDocument = [Xml.XmlDocument]::new()
            $definitionDocument.Load($definitionPath)
            $tilesetRoot = $definitionDocument.DocumentElement
            $imageReferenceBase = Split-Path -Parent $definitionPath
        }
        else {
            $tilesetRoot = $mapTileset
            $imageReferenceBase = $mapReferenceBase
        }

        $tilesetName = $tilesetRoot.GetAttribute('name')
        foreach ($imageNode in $tilesetRoot.SelectNodes('.//image[@source]')) {
            $imageReference = $imageNode.GetAttribute('source')
            $imagePath = Resolve-AvailableFile -BaseDirectory $imageReferenceBase -Reference $imageReference
            if ($null -eq $imagePath) {
                $unresolved.Add([pscustomobject]@{
                    map = $mapFile.Name
                    kind = 'image'
                    tileset = $tilesetName
                    reference = $imageReference
                })
                continue
            }

            $references.Add([pscustomobject]@{
                map = $mapFile.FullName.Substring($sourcePath.Length + 1)
                archived = $isArchived
                tileset = $tilesetName
                image = $imagePath
            })
        }
    }
}

$pathRecords = [Collections.Generic.List[object]]::new()
foreach ($pathGroup in $references | Group-Object image) {
    $pathRecords.Add([pscustomobject]@{
        path = $pathGroup.Name
        hash = (Get-FileHash -LiteralPath $pathGroup.Name -Algorithm SHA256).Hash.ToLowerInvariant()
        maps = @($pathGroup.Group.map | Sort-Object -Unique)
        active = @($pathGroup.Group | Where-Object { -not $_.archived }).Count -gt 0
    })
}

# Deduplicate by content, not just by source path.
$images = [Collections.Generic.List[object]]::new()
foreach ($hashGroup in $pathRecords | Group-Object hash) {
    $orderedSources = @($hashGroup.Group | Sort-Object @{ Expression = 'active'; Descending = $true }, path)
    $representative = $orderedSources[0]
    $images.Add([pscustomobject]@{
        source = $representative.path
        hash = $hashGroup.Name
        sourcePaths = @($orderedSources.path)
        maps = @($orderedSources.maps | ForEach-Object { $_ } | Sort-Object -Unique)
        active = @($orderedSources | Where-Object active).Count -gt 0
    })
}

$usedNamesByCategory = @{}
$categoryCounts = @{}
$copyRecords = [Collections.Generic.List[object]]::new()
foreach ($image in $images | Sort-Object @{ Expression = { [IO.Path]::GetFileName($_.source) } }, @{ Expression = 'active'; Descending = $true }, source) {
    $sourceFileName = [IO.Path]::GetFileName($image.source)
    $category = Get-ImageCategory -FileName $sourceFileName
    if (-not $usedNamesByCategory.ContainsKey($category)) {
        $usedNamesByCategory[$category] = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $categoryCounts[$category] = 0
    }

    $extension = [IO.Path]::GetExtension($sourceFileName).ToLowerInvariant()
    $preferredBaseName = Get-SafeSlug -Value ([IO.Path]::GetFileNameWithoutExtension($sourceFileName))
    if (-not $image.active -and $usedNamesByCategory[$category].Contains("$preferredBaseName$extension")) {
        $preferredBaseName = "$preferredBaseName-archive"
    }
    $destinationFileName = Get-UniqueFileName -PreferredBaseName $preferredBaseName -Extension $extension -UsedNames $usedNamesByCategory[$category]
    $categoryPath = Join-Path $destinationPath $category
    New-Item -ItemType Directory -Path $categoryPath -Force | Out-Null
    $destinationImagePath = Join-Path $categoryPath $destinationFileName

    Copy-Item -LiteralPath $image.source -Destination $destinationImagePath
    $copiedHash = (Get-FileHash -LiteralPath $destinationImagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($copiedHash -ne $image.hash) {
        throw "Copied image failed checksum verification: $destinationImagePath"
    }

    $categoryCounts[$category]++
    $copyRecords.Add([pscustomobject]@{
        category = $category
        file = $destinationFileName
        source = $image.source
        hash = $copiedHash
    })
}

Write-Output "Maps scanned: $($mapFiles.Count)"
Write-Output "Tileset image references resolved: $($references.Count)"
Write-Output "Unique image contents copied: $($copyRecords.Count)"
Write-Output "Destination: $destinationPath"
Write-Output 'Images by category:'
$categoryCounts.GetEnumerator() | Sort-Object Name | ForEach-Object {
    Write-Output "  $($_.Name): $($_.Value)"
}

if ($unresolved.Count -gt 0) {
    Write-Warning "$($unresolved.Count) references could not be resolved:"
    foreach ($missing in $unresolved | Group-Object kind, tileset, reference | Sort-Object Name) {
        $sample = $missing.Group[0]
        Write-Warning "  $($missing.Count)x $($sample.kind): $($sample.reference)"
    }
}
