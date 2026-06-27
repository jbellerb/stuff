const wasmOpt = Deno.env.get("WASM_OPT");

if (!wasmOpt) {
  throw new Error("binaryen stub: WASM_OPT environment variable not set");
}

const { code } = await new Deno.spawnAndWait(wasmOpt, { args: Deno.args });
Deno.exit(code);
