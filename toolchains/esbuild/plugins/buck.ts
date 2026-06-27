import * as esbuild from "npm:esbuild";

export type BuckPluginOpts = {
  cell?: string;
  package?: string;
  imports?: Record<string, string>;
};

const buckPlugin = (opts?: BuckPluginOpts): esbuild.Plugin => {
  return {
    name: "buck",
    setup(build) {
      const imports = opts?.imports ?? {};

      const canonicalize = (target: string): string => {
        if (target.startsWith(":")) {
          target = `//${opts?.package ?? ""}${target}`;
        }
        if (target.startsWith("//")) {
          target = `${opts?.cell ?? ""}${target}`;
        }
        return target;
      };

      build.onResolve({ filter: /^buck:/ }, (args) => {
        const target = canonicalize(args.path.slice("buck:".length));
        const output = imports[target];
        if (output === undefined) {
          return {
            errors: [
              { text: `"${target}" is not listed in the bundle's imports` },
            ],
          };
        }

        return {
          path: output.startsWith("/") ? output : `${Deno.cwd()}/${output}`,
        };
      });
    },
  };
};

export default buckPlugin;
