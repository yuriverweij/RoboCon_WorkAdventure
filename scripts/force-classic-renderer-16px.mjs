import { promises as fs } from "node:fs";
import path from "node:path";
import process from "node:process";
import sharp from "sharp";

const TILE_SIZE = 16;
const GID_MASK = 0x1fffffff;
const FLIP_MASK = 0xe0000000;
const FALLBACK_TILESET_NAME = "16px classic renderer compatibility";

async function findMaps(directory) {
    const maps = [];
    for (const entry of await fs.readdir(directory, { withFileTypes: true })) {
        const entryPath = path.join(directory, entry.name);
        if (entry.isDirectory()) {
            maps.push(...(await findMaps(entryPath)));
        } else if (entry.isFile() && entry.name.toLowerCase().endsWith(".tmj")) {
            maps.push(entryPath);
        }
    }
    return maps;
}

function* walkTileLayers(layers) {
    for (const layer of layers ?? []) {
        if (layer.type === "tilelayer") {
            yield layer;
        } else if (layer.type === "group") {
            yield* walkTileLayers(layer.layers);
        }
    }
}

function getLayerCells(layer) {
    const arrays = Array.isArray(layer.chunks) ? layer.chunks.map((chunk) => chunk.data) : [layer.data];
    const cells = [];

    for (const data of arrays) {
        if (!Array.isArray(data)) {
            continue;
        }
        for (let index = 0; index < data.length; index += 1) {
            const rawGid = Number(data[index]) >>> 0;
            const gid = rawGid & GID_MASK;
            if (gid !== 0) {
                cells.push({ data, index, rawGid, gid });
            }
        }
    }
    return cells;
}

function findTileset(tilesets, gid) {
    for (let index = tilesets.length - 1; index >= 0; index -= 1) {
        const tileset = tilesets[index];
        const firstGid = Number(tileset.firstgid);
        const tileCount = Number(tileset.tilecount);
        if (gid >= firstGid && gid < firstGid + tileCount) {
            return tileset;
        }
    }
    return undefined;
}

function getUsedTilesets(tilesets, cells) {
    return new Set(cells.map((cell) => findTileset(tilesets, cell.gid)).filter(Boolean));
}

function nextPowerOfTwo(value) {
    let result = 1;
    while (result < value) {
        result *= 2;
    }
    return result;
}

function copyTilePixels(source, tileset, gid) {
    const localId = gid - Number(tileset.firstgid);
    const columns = Number(tileset.columns);
    const margin = Number(tileset.margin ?? 0);
    const spacing = Number(tileset.spacing ?? 0);
    const left = margin + (localId % columns) * (TILE_SIZE + spacing);
    const top = margin + Math.floor(localId / columns) * (TILE_SIZE + spacing);

    if (left < 0 || top < 0 || left + TILE_SIZE > source.width || top + TILE_SIZE > source.height) {
        throw new Error(`Tile GID ${gid} falls outside ${tileset.image}.`);
    }

    const tile = Buffer.alloc(TILE_SIZE * TILE_SIZE * 4);
    for (let row = 0; row < TILE_SIZE; row += 1) {
        const sourceStart = ((top + row) * source.width + left) * 4;
        const destinationStart = row * TILE_SIZE * 4;
        source.data.copy(tile, destinationStart, sourceStart, sourceStart + TILE_SIZE * 4);
    }
    return tile;
}

async function loadTilesetImage(mapDirectory, tileset, cache) {
    const imagePath = path.resolve(mapDirectory, tileset.image);
    let source = cache.get(imagePath);
    if (!source) {
        const decoded = await sharp(imagePath).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
        source = { data: decoded.data, width: decoded.info.width, height: decoded.info.height };
        cache.set(imagePath, source);
    }
    return source;
}

function cloneTileMetadata(tileset, gid, newLocalId) {
    const localId = gid - Number(tileset.firstgid);
    const metadata = tileset.tiles?.find((tile) => Number(tile.id) === localId);
    if (!metadata) {
        return undefined;
    }
    if (Array.isArray(metadata.animation) && metadata.animation.length > 0) {
        return undefined;
    }
    return { ...structuredClone(metadata), id: newLocalId };
}

function chooseCandidate(tileset, cells) {
    for (const cell of cells) {
        const localId = cell.gid - Number(tileset.firstgid);
        const metadata = tileset.tiles?.find((tile) => Number(tile.id) === localId);
        if (!Array.isArray(metadata?.animation) || metadata.animation.length === 0) {
            return cell;
        }
    }
    return undefined;
}

async function processMap(mapPath) {
    const mapDirectory = path.dirname(mapPath);
    const map = JSON.parse(await fs.readFile(mapPath, "utf8"));

    if (map.tilewidth !== TILE_SIZE || map.tileheight !== TILE_SIZE) {
        return { status: "skipped", layers: 0, reason: `${map.tilewidth}x${map.tileheight} tiles` };
    }
    if (map.tilesets?.some((tileset) => tileset.name === FALLBACK_TILESET_NAME)) {
        return { status: "skipped", layers: 0, reason: "already processed" };
    }

    const sourceTilesets = [...(map.tilesets ?? [])].sort((left, right) => left.firstgid - right.firstgid);
    const pending = [];

    for (const layer of walkTileLayers(map.layers)) {
        const cells = getLayerCells(layer);
        if (cells.length < 2) {
            continue;
        }

        const usedTilesets = getUsedTilesets(sourceTilesets, cells);
        if (usedTilesets.size !== 1) {
            continue;
        }

        const [tileset] = usedTilesets;
        const candidate = chooseCandidate(tileset, cells);
        if (candidate) {
            pending.push({ layer, cells, tileset, candidate });
        }
    }

    if (pending.length === 0) {
        return { status: "skipped", layers: 0, reason: "no eligible single-tileset layers" };
    }

    const imageCache = new Map();
    const atlasColumns = nextPowerOfTwo(Math.ceil(Math.sqrt(pending.length)));
    const atlasRows = nextPowerOfTwo(Math.ceil(pending.length / atlasColumns));
    const atlasWidth = atlasColumns * TILE_SIZE;
    const atlasHeight = atlasRows * TILE_SIZE;
    const atlas = Buffer.alloc(atlasWidth * atlasHeight * 4);
    const fallbackTiles = [];

    for (let localId = 0; localId < pending.length; localId += 1) {
        const item = pending[localId];
        const source = await loadTilesetImage(mapDirectory, item.tileset, imageCache);
        const tile = copyTilePixels(source, item.tileset, item.candidate.gid);
        const destinationX = (localId % atlasColumns) * TILE_SIZE;
        const destinationY = Math.floor(localId / atlasColumns) * TILE_SIZE;

        for (let row = 0; row < TILE_SIZE; row += 1) {
            const sourceStart = row * TILE_SIZE * 4;
            const destinationStart = ((destinationY + row) * atlasWidth + destinationX) * 4;
            tile.copy(atlas, destinationStart, sourceStart, sourceStart + TILE_SIZE * 4);
        }

        const metadata = cloneTileMetadata(item.tileset, item.candidate.gid, localId);
        if (metadata) {
            fallbackTiles.push(metadata);
        }
        item.fallbackLocalId = localId;
    }

    const highestGid = sourceTilesets.reduce(
        (highest, tileset) => Math.max(highest, Number(tileset.firstgid) + Number(tileset.tilecount)),
        1,
    );
    const mapStem = path.basename(mapPath, path.extname(mapPath));
    const fallbackImageName = `${mapStem}-classic-fallback.png`;
    const fallbackImagePath = path.join(mapDirectory, fallbackImageName);

    await sharp(atlas, { raw: { width: atlasWidth, height: atlasHeight, channels: 4 } })
        .png()
        .toFile(fallbackImagePath);

    const fallbackTileset = {
        columns: atlasColumns,
        firstgid: highestGid,
        image: fallbackImageName,
        imageheight: atlasHeight,
        imagewidth: atlasWidth,
        margin: 0,
        name: FALLBACK_TILESET_NAME,
        spacing: 0,
        tilecount: atlasColumns * atlasRows,
        tileheight: TILE_SIZE,
        tilewidth: TILE_SIZE,
    };
    if (fallbackTiles.length > 0) {
        fallbackTileset.tiles = fallbackTiles;
    }
    map.tilesets.push(fallbackTileset);

    for (const item of pending) {
        const flags = (item.candidate.rawGid & FLIP_MASK) >>> 0;
        const fallbackGid = highestGid + item.fallbackLocalId;
        item.candidate.data[item.candidate.index] = (flags | fallbackGid) >>> 0;

        const usedAfter = getUsedTilesets(map.tilesets, getLayerCells(item.layer));
        if (usedAfter.size < 2) {
            throw new Error(`Layer "${item.layer.name}" did not retain two used tilesets.`);
        }
    }

    await fs.writeFile(mapPath, `${JSON.stringify(map, null, 2)}\n`, "utf8");
    return { status: "processed", layers: pending.length, reason: "" };
}

async function main() {
    const outputDirectory = path.resolve(process.argv[2] ?? "dist");
    const maps = await findMaps(outputDirectory);
    let processedMaps = 0;
    let processedLayers = 0;

    for (const mapPath of maps.sort()) {
        const result = await processMap(mapPath);
        const relativePath = path.relative(outputDirectory, mapPath);
        if (result.status === "processed") {
            processedMaps += 1;
            processedLayers += result.layers;
            console.log(`Classic renderer compatibility: ${relativePath} (${result.layers} layers)`);
        } else {
            console.log(`Classic renderer compatibility: skipped ${relativePath} (${result.reason})`);
        }
    }

    console.log(`Classic renderer compatibility complete: ${processedMaps} maps, ${processedLayers} layers.`);
}

main().catch((error) => {
    console.error(error instanceof Error ? error.stack : error);
    process.exitCode = 1;
});
