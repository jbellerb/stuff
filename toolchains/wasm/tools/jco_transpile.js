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

const coresJs = `${coreNames
  .map(
    (name, i) =>
      `import core${i} from "./${name}" with { type: "bytes-gzip" };`,
  )
  .join("\n")}

export const cores = Promise.all([
${coreNames.map((_, i) => `  core${i},`).join("\n")}
]).then(
  ([
${coreNames.map((_, i) => `    core${i},`).join("\n")}
  ]) => ({
${coreNames.map((name, i) => `    "${name}": core${i},`).join("\n")}
  }),
);
`;

await Deno.writeFile(`${outDir}/cores.js`, new TextEncoder().encode(coresJs));
