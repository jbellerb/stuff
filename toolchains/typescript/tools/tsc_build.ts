import ts from "npm:typescript";

import { canonicalize, matchDep } from "./lib/util.ts";

import type { Dep } from "./lib/types.ts";

interface Config {
  cell: string;
  package: string;
  srcs: Record<string, string>;
  deps: Dep[];
  packages: { pkg: string; path: string }[];
  lib?: string[];
  alias?: Record<string, string>;
}

const [configPath, outDir] = Deno.args;
const config = JSON.parse(await Deno.readTextFile(configPath)) as Config;

const cwd = Deno.cwd();
const abs = (path: string): string =>
  path.startsWith("/") ? path : `${cwd}/${path}`;

// ROOT is the virtual project directory
const ROOT = "/__project__";
const mounts = new Map<string, string>(
  Object.entries(config.srcs).map(([name, target]) => [name, abs(target)]),
);
for (const { pkg, path } of config.packages) {
  mounts.set(`node_modules/${pkg}`, abs(path));
}

// ROOT and every ancestor directory of a mount exist as virtual directories
const dirs = new Set<string>([ROOT]);
for (const name of mounts.keys()) {
  for (let i = name.indexOf("/"); i !== -1; i = name.indexOf("/", i + 1)) {
    dirs.add(`${ROOT}/${name.slice(0, i)}`);
  }
}

const real = (path: string): string | undefined => {
  if (path !== ROOT && !path.startsWith(`${ROOT}/`)) {
    return path;
  }

  let name = path.slice(ROOT.length + 1);
  let suffix = "";
  while (name !== "") {
    if (mounts.has(name)) {
      return mounts.get(name) + suffix;
    }

    const slash = name.lastIndexOf("/");
    if (slash === -1) {
      break;
    }

    suffix = name.slice(slash) + suffix;
    name = name.slice(0, slash);
  }

  return undefined;
};

// this is incompatible with resolveLabel from util.ts because TypeScript
// requires this function to be synchronous
const resolveLabel = (
  target: string,
): ts.ResolvedModuleWithFailedLookupLocations | undefined => {
  // return early if this can't possibly be a buck2 target
  if (!target.startsWith(":") && !target.includes("//")) {
    return undefined;
  }

  const label = canonicalize(target, config.cell, config.package);
  const matched = matchDep(label, config.deps);
  if (matched === undefined) {
    return undefined;
  }
  const subpath = label.slice(matched.specifier.length + 1);

  const root = abs(matched.transpiled);
  const candidates = !subpath
    ? matched.main != null ? [`${root}/${matched.main}.d.ts`] : []
    // remap .js to .d.ts since we only care about types
    : [`${root}/${subpath.replace(/\.js$/, "")}.d.ts`, `${root}/${subpath}`];
  const found = candidates.find((path) => ts.sys.fileExists(path));

  return {
    resolvedModule: found
      ? {
        resolvedFileName: found,
        extension: ts.Extension.Dts,
        isExternalLibraryImport: true,
      }
      : undefined,
  };
};

const { options, errors } = ts.convertCompilerOptionsFromJson(
  {
    outDir: abs(outDir),
    rootDir: ROOT,
    module: "esnext",
    moduleResolution: "bundler",
    // always emit esnext. the bundler downlevels to the final target
    target: "esnext",
    declaration: true,
    strict: true,
    isolatedModules: true,
    noEmitOnError: true,
    // rewrite imports so the bundler consumes the .js files directly
    rewriteRelativeImportExtensions: true,
    // deps were already checked when their own library target built
    skipLibCheck: true,
    types: [],
    lib: config.lib,
  },
  ROOT,
);

const system: ts.System = {
  ...ts.sys,
  fileExists(path) {
    const r = real(path);
    return r !== undefined && ts.sys.fileExists(r);
  },
  readFile(path) {
    const r = real(path);
    return r === undefined ? undefined : ts.sys.readFile(r);
  },
  directoryExists(path) {
    if (dirs.has(path)) return true;
    const r = real(path);
    return r !== undefined && ts.sys.directoryExists(r);
  },
  // automatic @types inclusion is disabled, so nothing actually enumerates
  // directories. Mounts would be invisible here.
  getDirectories: () => [],
  realpath(path) {
    return path === ROOT || path.startsWith(`${ROOT}/`)
      ? path
      : ts.sys.realpath?.(path) ?? "";
  },
};

const alias = config.alias ?? {};
const host = ts.createIncrementalCompilerHost(options, system);
host.resolveModuleNameLiterals = (literals, containingFile, redirected, opts) =>
  literals.map((literal) => {
    const target = alias[literal.text] ?? literal.text;
    return resolveLabel(target) ??
      ts.resolveModuleName(
        target,
        containingFile,
        opts,
        system,
        undefined,
        redirected,
      );
  });

const program = ts.createProgram({
  rootNames: Object.keys(config.srcs).map((file) => `${ROOT}/${file}`),
  options,
  host,
});

const emitResult = program.emit();
const diagnostics = ts.sortAndDeduplicateDiagnostics([
  ...errors,
  ...ts.getPreEmitDiagnostics(program),
  ...emitResult.diagnostics,
]);

if (diagnostics.length > 0) {
  const format = Deno.noColor
    ? ts.formatDiagnostics
    : ts.formatDiagnosticsWithColorAndContext;
  console.error(format(diagnostics, host));
}
const failed = diagnostics.some(
  (d) => d.category === ts.DiagnosticCategory.Error,
);
Deno.exit(failed ? 1 : 0);
