import { transpileBytes } from "npm:@bytecodealliance/jco-transpile";

const { input, name, compress, compressor } = JSON.parse(
  await Deno.readTextFile(Deno.args[0]),
);
const outDir = Deno.args[1];

await Deno.mkdir(outDir, { recursive: true });

const component = await Deno.readFile(input);
const { files } = await transpileBytes(component, {
  name: name ?? "component",
  instantiation: "async",
  nodejsCompat: false,
  minify: false,
  optimize: !!Deno.env.get("WASM_OPT"),
  wasiShim: false,
  // jco silently maps versioned imports to their unversioned names when no
  // map is provided. At least we'll make that behavior explicit with a no-op
  // map.
  map: { "wasi:*": "wasi:*" },
});

const cores = [];
for (const [name, bytes] of Object.entries(files)) {
  const path = `${outDir}/${name}`;
  const slash = path.lastIndexOf("/");
  if (slash > outDir.length) {
    await Deno.mkdir(path.slice(0, slash), { recursive: true });
  }
  await Deno.writeFile(path, bytes);

  if (/\.core\d*\.wasm$/.test(name)) {
    cores[name] = bytes;
  }
}

const compressBinary = async (bytes) => {
  if (compressor != null) {
    const child = Deno.spawn(compressor[0], {
      args: compressor.slice(1),
      stdin: "piped",
      stdout: "piped",
      stderr: "inherit",
    });
    const writer = child.stdin.getWriter();
    try {
      writer.write(bytes);
      await writer.close();
    } catch (e) {
      throw new Error(`failed to write to compressor: ${e.message}`);
    }

    let output;
    try {
      output = await child.stdout.bytes();
    } catch (e) {
      throw new Error(`failed to read from compressor: ${e.message}`);
    }

    const status = await child.status;
    if (!status.success) {
      throw new Error(
        `compressor returned non-zero exit code: ${status.code}`,
      );
    }
    return new Uint8Array(output.stdout);
  } else {
    using file = await Deno.open(path, { read: true });
    const stream = file.readable.pipeThrough(new CompressionStream("gzip"));
    return new Uint8Array(await new Response(stream).arrayBuffer());
  }
};

if (compress) {
  await Deno.writeTextFile(
    `${outDir}/compile.js`,
    `export default function compile(base64) {
  const stream = new ReadableStream({
    start(c) {
      c.enqueue(Uint8Array.fromBase64(base64));
      c.close();
    },
  }).pipeThrough(new DecompressionStream("gzip"));
  return WebAssembly.compileStreaming(new Response(stream));
}
`,
  );
} else {
  await Deno.writeTextFile(
    `${outDir}/compile.js`,
    `export default function compile(base64) {
  return WebAssembly.compile(Uint8Array.fromBase64(base64));
}
`,
  );
}

await Deno.writeTextFile(
  `${outDir}/cores.js`,
  `import compile from "./compile.js";

const cores = {
${await Promise.all(
    Object.entries(cores).map(
      async ([name, bytes]) =>
        `  "${name}": "${
          (compress ? await compressBinary(bytes) : bytes).toBase64()
        }",`,
    ),
  ).then((cores) => cores.join("\n"))}
};

export const getCoreModule = (name) => {
  const bytes = cores[name];
  if (!bytes) throw new Error(\`missing core module: \${name}\`);
  return compile(bytes);
};
`,
);
await Deno.writeTextFile(
  `${outDir}/cores.d.ts`,
  "export const getCoreModule: (path: string) => Promise<WebAssembly.Module>;\n",
);
