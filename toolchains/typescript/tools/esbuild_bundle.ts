import { relative, resolve } from "node:path";
import * as esbuild from "npm:esbuild";

import { abs, resolveLabel } from "./lib/util.ts";

import type { BundlerConfig } from "./lib/types.ts";

const [configPath, outdir, urlsPath] = Deno.args;
const {
  cell,
  package: pkg,
  deps,
  assets,
  hashNames,
  entryPoints,
  ...config
} = JSON.parse(await Deno.readTextFile(configPath)) as BundlerConfig;

const options: esbuild.BuildOptions = {
  ...config,
  bundle: true,
  outdir,
  entryPoints: Object.fromEntries(
    Object.entries(entryPoints).map(([name, path]) => [
      name.slice(0, -3),
      path,
    ]),
  ),
  entryNames: hashNames ? "[dir]/[name].[hash]" : "[dir]/[name]",
  chunkNames: hashNames ? "chunks/[name].[hash]" : "chunks/[name]",
  metafile: true,
  nodePaths: config.nodePaths != null ? config.nodePaths.map(abs) : undefined,
};

if (deps.length > 0) {
  options.plugins = [
    {
      name: "buck-paths",
      setup(build: esbuild.PluginBuild) {
        build.onResolve({ filter: /.*/ }, async (args) => {
          const resolved = await resolveLabel(
            args.path,
            cell,
            pkg,
            deps,
            args.importer,
          );
          if (resolved === undefined || "path" in resolved) {
            return resolved;
          }
          return { errors: [{ text: resolved.error }] };
        });
      },
    },
  ];
}

if (Object.keys(assets ?? {}).length)
  throw new Error("Static asset emission requires Rolldown");
const result = await esbuild.build(options);
const urls: Record<string, string> = {};
for (const [path, output] of Object.entries(result.metafile!.outputs)) {
  if (!output.entryPoint) continue;
  for (const [name, entry] of Object.entries(entryPoints)) {
    if (resolve(output.entryPoint) === resolve(entry)) {
      urls[name] = `/${relative(outdir, path)}`;
    }
  }
}
await Deno.writeTextFile(urlsPath, JSON.stringify(urls));
