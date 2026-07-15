load("//deno:node.bzl", "NodePackageTSet")
load(
    "//typescript:rules.bzl",
    "TypeScriptLibTSet",
    "TypeScriptLibraryInfo",
    "TypeScriptModule",
    "TypeScriptModuleTSet",
)
load(":defs.bzl", "WasmToolchainInfo")

def _jco_transpile_impl(ctx: AnalysisContext) -> list[Provider]:
    component = ctx.attrs.component[DefaultInfo]
    if len(component.default_outputs) != 1:
        fail("Expected single component artifact.")

    out = ctx.actions.declare_output("out", dir = True)

    config = ctx.actions.write_json(
        ctx.actions.declare_output("jco.json").as_output(),
        {
            "input": component.default_outputs[0],
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
        DefaultInfo(default_output = out),
        TypeScriptLibraryInfo(
            transpiled = ctx.actions.tset(
                TypeScriptModuleTSet,
                value = TypeScriptModule(
                    specifier = "{}//{}:{}".format(
                        ctx.label.cell,
                        ctx.label.package,
                        ctx.label.name,
                    ),
                    main = ctx.attrs.module_name,
                    transpiled = out,
                ),
            ),
            lib = ctx.actions.tset(TypeScriptLibTSet, value = []),
            packages = ctx.actions.tset(NodePackageTSet),
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
