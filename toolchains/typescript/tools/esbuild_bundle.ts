import * as esbuild from "npm:esbuild";

import { canonicalize, matchDep } from "./lib/util.ts";

import type { Dep } from "./lib/types.ts";

interface Config extends esbuild.BuildOptions {
  cell: string;
  package: string;
  deps: Dep[];
}

const [configPath, outfile] = Deno.args;
const { cell, package: pkg, deps, ...options } = JSON.parse(
  await Deno.readTextFile(configPath),
) as Config;
options.bundle = true;
options.outfile = outfile;

const cwd = Deno.cwd();
const abs = (path: string): string =>
  path.startsWith("/") ? path : `${cwd}/${path}`;

if (options.nodePaths) {
  options.nodePaths = options.nodePaths.map(abs);
}

const exists = async (path: string): Promise<boolean> => {
  try {
    return (await Deno.stat(path)).isFile;
  } catch {
    return false;
  }
};

const resolveLabel = async (
  importPath: string,
): Promise<esbuild.OnResolveResult | undefined> => {
  const label = canonicalize(importPath, cell, pkg);
  const matched = matchDep(label, deps);
  if (matched === undefined) {
    return undefined;
  }
  const subpath = label.slice(matched.specifier.length + 1);

  const root = abs(matched.transpiled);
  const candidates = !subpath
    ? matched.main != null ? [`${root}/${matched.main}.js`] : []
    : [`${root}/${subpath}`, `${root}/${subpath}.js`];
  for (const candidate of candidates) {
    if (await exists(candidate)) {
      return { path: candidate };
    }
  }

  return {
    errors: [
      {
        text: candidates.length === 0
          ? `"${importPath}" has no main module`
          : `"${importPath}" not found in ${matched.transpiled}`,
      },
    ],
  };
};

if (deps.length > 0) {
  options.plugins = [
    {
      name: "buck-paths",
      setup(build: esbuild.PluginBuild) {
        build.onResolve({ filter: /.*/ }, (args) => resolveLabel(args.path));
      },
    },
  ];
}

await esbuild.build(options);
