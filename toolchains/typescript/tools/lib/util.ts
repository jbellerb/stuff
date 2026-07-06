import type { Dep } from "./types.ts";

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
