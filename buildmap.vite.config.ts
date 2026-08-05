import 'dotenv/config';
import { defineConfig } from "vite";
import { getMaps, getMapsOptimizers, getMapsScripts, LogLevel, OptimizeOptions } from "wa-map-optimizer-vite";

const maps = getMaps();

let optimizerOptions: OptimizeOptions = {
    logs: process.env.LOG_LEVEL && process.env.LOG_LEVEL in LogLevel ? LogLevel[process.env.LOG_LEVEL] : LogLevel.NORMAL,
};

if (process.env.TILESET_OPTIMIZATION && process.env.TILESET_OPTIMIZATION === "true") {
    const qualityMin = process.env.TILESET_OPTIMIZATION_QUALITY_MIN ? parseInt(process.env.TILESET_OPTIMIZATION_QUALITY_MIN) : 0.9;
    const qualityMax = process.env.TILESET_OPTIMIZATION_QUALITY_MAX ? parseInt(process.env.TILESET_OPTIMIZATION_QUALITY_MAX) : 1;

    optimizerOptions.output = {
        tileset: {
            compress: {
                quality: [qualityMin, qualityMax],
            }
        }
    }
}

function getOptimizersByTileSize() {
    const mapsByTileSize = new Map<number, Map<string, (typeof maps extends Map<string, infer T> ? T : never)>>();

    for (const [path, map] of maps) {
        if (map.tilewidth !== map.tileheight) {
            throw new Error(`Map ${path} uses non-square tiles.`);
        }

        let matchingMaps = mapsByTileSize.get(map.tilewidth);
        if (!matchingMaps) {
            matchingMaps = new Map();
            mapsByTileSize.set(map.tilewidth, matchingMaps);
        }
        matchingMaps.set(path, map);
    }

    return [...mapsByTileSize.entries()].flatMap(([tileSize, matchingMaps]) =>
        getMapsOptimizers(matchingMaps, {
            ...optimizerOptions,
            tile: { size: tileSize },
        }),
    );
}

export default defineConfig({
    base: "./",
    build: {
        sourcemap: true,
        rollupOptions: {
            input: {
                ...getMapsScripts(maps),
            },
        },
    },
    preview: {
        cors: true,
    },
    plugins: [
        ...getOptimizersByTileSize(),
    ],
});
