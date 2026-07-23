import type { Dep } from "./types.ts";

let cwd: string | undefined;

// abs converts a relative path to an absolute one. If the path is already
// absolute, the path is returned unchanged.
export function abs(path: string): string {
  cwd ??= Deno.cwd();
  return path.startsWith("/") ? path : `${cwd}/${path}`;
}

// exists returns if a file exists at a given path.
export async function exists(path: string): Promise<boolean> {
  try {
    return (await Deno.stat(path)).isFile;
  } catch {
    return false;
  }
}

// canonicalize expands "//package:name" and ":name" label shorthand to full
// labels in the given cell and package.
export function canonicalize(
  target: string,
  cell: string,
  pkg: string,
): string {
  if (target.startsWith(":")) {
    target = `//${pkg}${target}`;
  }
  if (target.startsWith("//")) {
    target = `${cell}${target}`;
  }
  return target;
}

// matchDep checks a target label against a list of Deps and returns the most
// specific Dep it belongs to.
export function matchDep(label: string, deps: Dep[]): Dep | undefined {
  let matched: Dep | undefined;
  for (const module of deps) {
    if (label === module.specifier) {
      matched = module;
      break;
    }

    if (
      label.length > module.specifier.length &&
      label.startsWith(module.specifier) &&
      label[module.specifier.length] === "/" &&
      (matched === undefined ||
        module.specifier.length > matched.specifier.length)
    ) {
      matched = module;
    }
  }
  return matched;
}

// resolveLabel resolves a buck2 target label to a subpath in a dependency if
// a it exists. If no dependencies match, the result is an undefined value.
export async function resolveLabel(
  importPath: string,
  cell: string,
  pkg: string,
  deps: Dep[],
): Promise<{ path: string } | { error: string } | undefined> {
  // return early if this can't possibly be a buck2 target
  if (!importPath.startsWith(":") && !importPath.includes("//")) {
    return undefined;
  }

  const label = canonicalize(importPath, cell, pkg);
  const matched = matchDep(label, deps);
  if (matched === undefined) {
    return undefined;
  }
  const subpath = label.slice(matched.specifier.length + 1);

  const root = abs(matched.transpiled);
  const candidates = !subpath
    ? matched.main != null
      ? [`${root}/${matched.main}.js`]
      : []
    : [`${root}/${subpath}`, `${root}/${subpath}.js`];
  for (const candidate of candidates) {
    if (await exists(candidate)) {
      return { path: candidate };
    }
  }

  return {
    error:
      candidates.length === 0
        ? `"${importPath}" has no main module`
        : `"${importPath}" not found in ${matched.transpiled}`,
  };
}
