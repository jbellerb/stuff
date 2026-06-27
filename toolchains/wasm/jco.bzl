load("//deno:node.bzl", "NodePackageTSet")
load(
    "//typescript:rules.bzl",
    "TypeScriptLibTSet",
    "TypeScriptLibraryInfo",
    "TypeScriptModule",
    "TypeScriptModuleTSet",
)
load(":defs.bzl", "WasmToolchainInfo")

_PREVIEW2_SHIM_MAP = {
    "wasi:cli/*": "@bytecodealliance/preview2-shim/cli#*",
    "wasi:clocks/*": "@bytecodealliance/preview2-shim/clocks#*",
    "wasi:filesystem/*": "@bytecodealliance/preview2-shim/filesystem#*",
    "wasi:http/*": "@bytecodealliance/preview2-shim/http#*",
    "wasi:io/*": "@bytecodealliance/preview2-shim/io#*",
    "wasi:random/*": "@bytecodealliance/preview2-shim/random#*",
    "wasi:sockets/*": "@bytecodealliance/preview2-shim/sockets#*",
}

def _jco_transpile_impl(ctx: AnalysisContext) -> list[Provider]:
    component = ctx.attrs.component[DefaultInfo]
    if len(component.default_outputs) != 1:
        fail("Expected single component artifact.")

    out = ctx.actions.declare_output("out", dir = True)

    config = ctx.actions.write_json(
        ctx.actions.declare_output("jco.json").as_output(),
        {
            "input": component.default_outputs[0],
            "instantiation": "async",
            "map": ctx.attrs.shim_map,
            "name": ctx.attrs.module_name,
            "compress": ctx.attrs.compress,
            "compressor": ctx.attrs.compressor[RunInfo] if ctx.attrs.compressor else None,
        },
        with_inputs = True,
    )

    env = {}
    if ctx.attrs.optimize:
        wasm_toolchain = ctx.attrs._wasm_toolchain[WasmToolchainInfo]
        env["WASM_OPT"] = cmd_args(wasm_toolchain.wasm_opt)

    ctx.actions.run(
        cmd_args([ctx.attrs._jco_transpile[RunInfo], config, out.as_output()]),
        category = "jco_transpile",
        identifier = ctx.label.name,
        env = env,
    )

    return [
        DefaultInfo(
            default_output = out,
            sub_targets = {
                # the .js outputs load their sibling core modules by relative
                # path, so consumers of a projection should also depend on the
                # whole out dir
                name: [DefaultInfo(
                    default_output = out.project(name),
                    other_outputs = [out],
                )]
                for name in [
                    ctx.attrs.module_name + ".js",
                    ctx.attrs.module_name + ".d.ts",
                    "cores.js",
                    "cores.d.ts",
                ]
            },
        ),
    ]

jco_transpile = rule(
    impl = _jco_transpile_impl,
    attrs = {
        "component": attrs.dep(
            providers = [DefaultInfo],
            doc = "The WebAssembly component to transpile to an ES module.",
        ),
        "module_name": attrs.string(
            default = "component",
            doc = "Base name for the emitted module.",
        ),
        "shim_map": attrs.dict(
            key = attrs.string(),
            value = attrs.string(),
            default = _PREVIEW2_SHIM_MAP,
            doc = "Mapping of WASI interfaces to shim packages.",
        ),
        "optimize": attrs.bool(
            default = False,
            doc = "Run wasm-opt on core modules after splitting.",
        ),
        "compress": attrs.bool(
            default = False,
            doc = """
            Bake core modules into .js modules of gzipped base64 so the output
            is a self-contained ES module graph.
            """,
        ),
        "compressor": attrs.option(
            attrs.exec_dep(providers = [RunInfo]),
            default = None,
            doc = """
            A compressor command that takes a binary as stdin and produces a
            gzip binary as stdout. Implies `compress = True`.
            """,
        ),
        "_jco_transpile": attrs.default_only(
            attrs.exec_dep(
                default = "//wasm/tools:jco-transpile",
                providers = [RunInfo],
            ),
        ),
        "_wasm_toolchain": attrs.default_only(
            attrs.toolchain_dep(
                default = "toolchains//:wasm",
                providers = [WasmToolchainInfo],
            ),
        ),
    },
)
