import * as esbuild from "npm:esbuild";

import { abs, resolveLabel } from "./lib/util.ts";

import type { BundlerConfig } from "./lib/types.ts";

const [configPath, outfile] = Deno.args;
const {
  cell,
  package: pkg,
  deps,
  ...config
} = JSON.parse(await Deno.readTextFile(configPath)) as BundlerConfig;

const options: esbuild.BuildOptions = {
  ...config,
  bundle: true,
  outfile: outfile,
  nodePaths: config.nodePaths != null ? config.nodePaths.map(abs) : undefined,
};

if (deps.length > 0) {
  options.plugins = [
    {
      name: "buck-paths",
      setup(build: esbuild.PluginBuild) {
        build.onResolve({ filter: /.*/ }, async (args) => {
          const resolved = await resolveLabel(args.path, cell, pkg, deps);
          if (resolved === undefined || "path" in resolved) {
            return resolved;
          }
          return { errors: [{ text: resolved.error }] };
        });
      },
    },
  ];
}

await esbuild.build(options);
