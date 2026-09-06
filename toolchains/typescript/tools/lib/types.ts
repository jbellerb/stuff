export interface Dep {
  specifier: string;
  transpiled: string;
  main?: string | null;
}

export interface BundlerConfig {
  splitting: boolean;
  hashNames: boolean;
  assets?: Record<string, string>;
  cell: string;
  package: string;
  deps: Dep[];
  entryPoints: Record<string, string>;
  format?: "iife" | "cjs" | "esm";
  platform?: "browser" | "node" | "neutral";
  target?: string[];
  minify?: boolean;
  sourcemap?: "inline" | "linked" | "external" | "both";
  external?: string[];
  define?: Record<string, string>;
  alias?: Record<string, string>;
  nodePaths?: string[];
}
