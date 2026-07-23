import * as rolldown from "npm:rolldown";

import { abs, resolveLabel } from "./lib/util.ts";

import type { BundlerConfig } from "./lib/types.ts";

const SOURCEMAP_MODES: Record<string, rolldown.OutputOptions["sourcemap"]> = {
  inline: "inline",
  linked: true,
  external: "hidden",
  both: "inline",
};

const [configPath, outfile] = Deno.args;
const {
  cell,
  package: pkg,
  deps,
  ...config
} = JSON.parse(await Deno.readTextFile(configPath)) as BundlerConfig;

const options: rolldown.BuildOptions = {
  input: config.entryPoints,
  resolve: {
    alias: config.alias,
    modules: config.nodePaths != null ? config.nodePaths.map(abs) : undefined,
  },
  output: {
    file: outfile,
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
      resolveId: async (source: string) => {
        const resolved = await resolveLabel(source, cell, pkg, deps);
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

await rolldown.build(options);
