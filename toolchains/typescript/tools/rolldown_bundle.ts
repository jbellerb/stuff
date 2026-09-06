import * as rolldown from "npm:rolldown";

import { abs, resolveLabel } from "./lib/util.ts";

import type { BundlerConfig } from "./lib/types.ts";

const SOURCEMAP_MODES: Record<string, rolldown.OutputOptions["sourcemap"]> = {
  inline: "inline",
  linked: true,
  external: "hidden",
  both: "inline",
};

const [configPath, outdir, urlsPath] = Deno.args;
const {
  cell,
  package: pkg,
  deps,
  ...config
} = JSON.parse(await Deno.readTextFile(configPath)) as BundlerConfig;

const options: rolldown.BuildOptions = {
  input: Object.fromEntries(
    Object.entries(config.entryPoints).map(([name, path]) => [
      name.slice(0, -3),
      path,
    ]),
  ),
  resolve: {
    alias: config.alias,
    modules: config.nodePaths != null ? config.nodePaths.map(abs) : undefined,
  },
  output: {
    dir: outdir,
    entryFileNames: config.hashNames ? "[name].[hash].js" : "[name].js",
    chunkFileNames: config.hashNames
      ? "chunks/[name].[hash].js"
      : "chunks/[name].js",
    assetFileNames: config.hashNames
      ? "[name].[hash][extname]"
      : "[name][extname]",
    codeSplitting: config.splitting,
    format: config.format,
    minify: config.minify,
    sourcemap:
      config.sourcemap != null ? SOURCEMAP_MODES[config.sourcemap] : undefined,
  },
  transform: {
    target: config.target,
    define: config.define,
  },
};
if (config.platform != null) {
  options.platform = config.platform;
}
if (config.external != null) {
  options.external = config.external;
}

if (deps.length > 0) {
  const plugins: rolldown.Plugin[] = [
    {
      name: "buck-paths",
      resolveId: async (source: string, importer) => {
        const resolved = await resolveLabel(source, cell, pkg, deps, importer);
        if (resolved === undefined) {
          return null;
        }
        if ("path" in resolved) {
          return resolved.path;
        } else {
          throw new Error(resolved.error);
        }
      },
    },
  ];
  options.plugins = plugins;
}

const urls: Record<string, string> = {};
const references = new Map<string, string>();
options.plugins = [
  options.plugins,
  {
    name: "buck-assets",
    async buildStart() {
      for (const [name, source] of Object.entries(config.assets ?? {})) {
        references.set(
          name,
          this.emitFile({
            type: "asset",
            name,
            ...(config.hashNames ? {} : { fileName: name }),
            source: await Deno.readFile(source),
          }),
        );
      }
    },
    generateBundle(_options, bundle) {
      const reservedNames = new Set([
        ...Object.keys(config.entryPoints),
        ...references.keys(),
      ]);
      for (const [name, reference] of references) {
        urls[name] = `/${this.getFileName(reference)}`;
      }
      for (const output of Object.values(bundle)) {
        if (output.type === "chunk") {
          let name = `${output.name}.js`;
          if (!output.isEntry) {
            if (reservedNames.has(name)) {
              name = `chunks/${output.name}.js`;
              let suffix = 2;
              while (reservedNames.has(name)) {
                name = `chunks/${output.name}.${suffix++}.js`;
              }
            }
            reservedNames.add(name);
          }
          urls[name] = `/${output.fileName}`;
        }
      }
    },
  },
];

await rolldown.build(options);
await Deno.writeTextFile(urlsPath, JSON.stringify(urls));
