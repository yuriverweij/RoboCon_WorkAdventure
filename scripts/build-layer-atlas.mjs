import { readFileSync, writeFileSync } from "node:fs";
import { PNG } from "pngjs";

const [sourcePath, outputPath, occupiedCellsPath, tileSizeText, mapColumnsText, maximumColumnsText] = process.argv.slice(2);
if (!maximumColumnsText) {
    throw new Error("Usage: node build-layer-atlas.mjs SOURCE OUTPUT CELLS TILE_SIZE MAP_COLUMNS MAXIMUM_COLUMNS");
}

const tileSize = Number.parseInt(tileSizeText, 10);
const mapColumns = Number.parseInt(mapColumnsText, 10);
const maximumColumns = Number.parseInt(maximumColumnsText, 10);
const occupiedCells = JSON.parse(readFileSync(occupiedCellsPath, "utf8"));

if (!Array.isArray(occupiedCells) || occupiedCells.length === 0) {
    throw new Error("The occupied-cell list must contain at least one map cell.");
}

const source = PNG.sync.read(readFileSync(sourcePath));
const atlasColumns = Math.min(maximumColumns, occupiedCells.length);
const atlasRows = Math.ceil(occupiedCells.length / atlasColumns);
const atlas = new PNG({
    width: atlasColumns * tileSize,
    height: atlasRows * tileSize,
    colorType: 6,
});

for (let tileIndex = 0; tileIndex < occupiedCells.length; tileIndex += 1) {
    const sourceCell = occupiedCells[tileIndex];
    const sourceX = (sourceCell % mapColumns) * tileSize;
    const sourceY = Math.floor(sourceCell / mapColumns) * tileSize;
    const destinationX = (tileIndex % atlasColumns) * tileSize;
    const destinationY = Math.floor(tileIndex / atlasColumns) * tileSize;

    for (let y = 0; y < tileSize; y += 1) {
        const currentSourceY = sourceY + y;
        if (currentSourceY >= source.height) {
            continue;
        }
        for (let x = 0; x < tileSize; x += 1) {
            const currentSourceX = sourceX + x;
            if (currentSourceX >= source.width) {
                continue;
            }

            const sourceOffset = ((currentSourceY * source.width) + currentSourceX) * 4;
            const destinationOffset = (((destinationY + y) * atlas.width) + destinationX + x) * 4;
            source.data.copy(atlas.data, destinationOffset, sourceOffset, sourceOffset + 4);
        }
    }
}

writeFileSync(outputPath, PNG.sync.write(atlas));
