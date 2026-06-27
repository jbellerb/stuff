import * as esbuild from "npm:esbuild";

const cssStyleSheetPlugin = {
  name: "css-stylesheet",
  setup(build) {
    build.onResolve({ filter: /\.css/ }, async (args) => {
      if (
        args.with.type !== "stylesheet" ||
        args.resolveDir === "" ||
        args.pluginData?.resolved
      ) {
        return;
      }

      const result = await build.resolve(args.path, {
        kind: args.kind,
        resolveDir: args.resolveDir,
        pluginData: { resolved: true },
      });
      if (result.errors.length > 0) {
        return { errors: result.errors };
      }

      return {
        path: result.path,
        namespace: "css-stylesheet-stub",
        sideEffects: false,
        warnings: result.warnings,
      };
    });

    build.onLoad(
      { filter: /.*/, namespace: "css-stylesheet-stub" },
      async (args) => {
        const bundle = await esbuild.build({
          entryPoints: [args.path],
          bundle: true,
          minify: true,
          write: false,
        });
        if (bundle.errors.length > 0) {
          return { errors: bundle.errors };
        }

        const output = bundle.outputFiles.find((f) => f.path === "<stdout>");
        if (!output) {
          return { errors: [{ text: "Generated bundle was empty" }] };
        }

        const rules = new TextDecoder().decode(output.contents);
        return {
          contents: `const stylesheet = new CSSStyleSheet();
await stylesheet.replace(${JSON.stringify(rules)});
export default stylesheet;`,
          warnings: bundle.warnings,
        };
      },
    );
  },
} satisfies esbuild.Plugin;

export default cssStyleSheetPlugin;
