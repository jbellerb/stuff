import * as esbuild from "npm:esbuild";

const { plugins, ...options } = JSON.parse(
  await Deno.readTextFile(Deno.args[0]),
);
options.outfile = Deno.args[1];

if (plugins && Array.isArray(plugins) && plugins.length > 0) {
  options.plugins = await Promise.all(
    plugins.map(
      async (path) => (await import(`${Deno.cwd()}/${path}`)).default,
    ),
  );
}

console.log(options);

await esbuild.build(options);
