import * as esbuild from "npm:esbuild";

export type GzipBinaryPluginOpts = {
  extensions?: string[];
  zopfli?: string;
};

const gzipBinaryPlugin = (opts?: GzipBinaryPluginOpts): esbuild.Plugin => {
  return {
    name: "gzip-binary",
    setup(build) {
      const filter = new RegExp(
        (opts?.extensions ?? []).map((e) => `${e}$`).join("|"),
      );
      build.onResolve({ filter }, async (args) => {
        if (args.resolveDir === "" || args.pluginData?.resolved) {
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
          namespace: "gzip-binary-stub",
          sideEffects: false,
          warnings: result.warnings,
        };
      });

      build.onResolve(
        { filter: /^virtual:/, namespace: "gzip-binary-stub" },
        (args) => {
          if (args.path === "virtual:decompress") {
            return {
              path: args.path,
              namespace: "gzip-binary-virtual",
              sideEffects: false,
            };
          }
        },
      );

      build.onLoad(
        { filter: /./, namespace: "gzip-binary-stub" },
        async (args) => {
          let compressed: Uint8Array<ArrayBuffer>;
          if (opts?.zopfli) {
            const output = await Deno.spawnAndWait(opts.zopfli, {
              args: ["-c", "--gzip", args.path],
            });
            if (!output.success) {
              return {
                errors: [
                  {
                    text:
                      `gzip-binary: zopfli returned non-zero exit code: ${output.code}`,
                  },
                ],
              };
            }
            compressed = output.stdout;
          } else {
            try {
              using file = await Deno.open(args.path, { read: true });
              const stream = file.readable.pipeThrough(
                new CompressionStream("gzip"),
              );
              const buffer = await new Response(stream).arrayBuffer();
              compressed = new Uint8Array(buffer);
            } catch (err) {
              return {
                errors: [
                  {
                    text:
                      `gzip-binary: failed to compress ${args.path}: ${err}`,
                  },
                ],
              };
            }
          }

          return {
            contents: `import decompress from "virtual:decompress";
const buffer = decompress("${compressed.toBase64()}");
export default buffer;`,
            loader: "js",
          };
        },
      );

      build.onLoad(
        { filter: /virtual:decompress/, namespace: "gzip-binary-virtual" },
        (_args) => {
          return {
            contents: `export default function decompress(base64) {
  let promise = null;
  return {
    then(resolve, reject) {
      if (!promise) {
        const stream = new ReadableStream({
          start(c) {
            c.enqueue(Uint8Array.fromBase64(base64));
            c.close();
          },
        }).pipeThrough(new DecompressionStream("gzip"));
        promise = new Response(stream)
          .arrayBuffer()
          .then((buffer) => new Uint8Array(buffer));
      }
      return promise.then(resolve, reject);
    },
  };
}`,
            loader: "js",
          };
        },
      );
    },
  };
};

export default gzipBinaryPlugin;
