import { transpileBytes } from "npm:@bytecodealliance/jco-transpile";

const { input, name, instantiation, map } = JSON.parse(
  await Deno.readTextFile(Deno.args[0]),
);
const outDir = Deno.args[1];

await Deno.mkdir(outDir, { recursive: true });

const component = await Deno.readFile(input);
const { files } = await transpileBytes(component, {
  name: name ?? "component",
  instantiation: instantiation ?? "async",
  map: map,
  nodejsCompat: false,
  minify: false,
  optimize: !!Deno.env.get("WASM_OPT"),
  wasiShim: false,
});

const coreNames = [];
for (const [name, bytes] of Object.entries(files)) {
  const path = `${outDir}/${name}`;
  const slash = path.lastIndexOf("/");
  if (slash > outDir.length) {
    await Deno.mkdir(path.slice(0, slash), { recursive: true });
  }
  await Deno.writeFile(path, bytes);

  if (/\.core\d*\.wasm$/.test(name)) {
    coreNames.push(name);
  }
}
coreNames.sort();

const coresJs = coreNames
  .map((name) => `export { default as "${name}" } from "./${name}";\n`)
  .join("");

await Deno.writeFile(`${outDir}/cores.js`, new TextEncoder().encode(coresJs));
