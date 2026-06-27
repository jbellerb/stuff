import * as esbuild from "npm:esbuild";

const { plugins, pluginConfig, ...options } = JSON.parse(
  await Deno.readTextFile(Deno.args[0]),
);
options.outfile = Deno.args[1];

if (plugins && Array.isArray(plugins) && plugins.length > 0) {
  const pluginNames = new Set(plugins.map(([name, _path]) => name));

  const config =
    pluginConfig && typeof pluginConfig === "object" ? pluginConfig : {};
  for (const key of Object.keys(config)) {
    if (!pluginNames.has(key)) {
      throw new Error(
        `plugin_config has options for "${key}", but no plugin with that name is declared`,
      );
    }
  }

  options.plugins = await Promise.all(
    plugins.map(async ([name, path]) => {
      const exported = (await import(`${Deno.cwd()}/${path}`)).default;
      const opts = config[name];
      if (typeof exported === "function") {
        return exported(opts);
      }
      if (opts !== undefined) {
        throw new Error(`plugin "${name}" does not support config options`);
      }
      return exported;
    }),
  );
}

await esbuild.build(options);
