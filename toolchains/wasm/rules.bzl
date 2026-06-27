load(":defs.bzl", "WasmToolchainInfo")
load(":wasm_transition.bzl", "wasm_transition")

def _wasm_optimize_impl(ctx: AnalysisContext) -> list[Provider]:
    wasm_toolchain = ctx.attrs._wasm_toolchain[WasmToolchainInfo]

    outfile = ctx.label.name
    if not ctx.label.name.endswith(".wasm"):
        outfile += ".wasm"
    output = ctx.actions.declare_output(outfile)

    bin = ctx.attrs.bin[DefaultInfo]
    if len(bin.default_outputs) != 1:
        fail("Expected single output artifact.")

    cmd = cmd_args([
        wasm_toolchain.wasm_opt,
        ctx.attrs.options,
        bin.default_outputs[0],
        "-o",
        output.as_output(),
    ])

    ctx.actions.run(cmd, category = "wasm_optimize", identifier = ctx.label.name)

    return [DefaultInfo(default_output = output)]

wasm_optimize = rule(
    impl = _wasm_optimize_impl,
    attrs = {
        "bin": attrs.transition_dep(
            cfg = wasm_transition,
            providers = [DefaultInfo],
            doc = "The WebAssembly binary to optimize.",
        ),
        "options": attrs.list(
            attrs.arg(),
            default = [],
            doc = "Additional arguments to pass to wasm-opt.",
        ),
        "_wasm_toolchain": attrs.default_only(
            attrs.toolchain_dep(
                default = "toolchains//:wasm",
                providers = [WasmToolchainInfo],
            ),
        ),
    },
)

def _wasm_component_impl(ctx: AnalysisContext) -> list[Provider]:
    wasm_toolchain = ctx.attrs._wasm_toolchain[WasmToolchainInfo]

    outfile = ctx.label.name
    if not ctx.label.name.endswith(".wasm"):
        outfile += ".wasm"
    output = ctx.actions.declare_output(outfile)

    bin = ctx.attrs.bin[DefaultInfo]
    if len(bin.default_outputs) != 1:
        fail("Expected single output artifact.")

    cmd = cmd_args([
        wasm_toolchain.wasm_tools,
        "component",
        "new",
        bin.default_outputs[0],
        "-o",
        output.as_output(),
    ])
    if ctx.attrs.adapter != None:
        cmd.add("--adapt", ctx.attrs.adapter[DefaultInfo].default_outputs[0])

    ctx.actions.run(cmd, category = "wasm_component", identifier = ctx.label.name)

    return [DefaultInfo(default_output = output)]

wasm_component = rule(
    impl = _wasm_component_impl,
    attrs = {
        "adapter": attrs.option(
            attrs.transition_dep(
                cfg = wasm_transition,
                providers = [DefaultInfo],
            ),
            default = None,
            doc = "An optional WASI Preview 1 adapter module to link in.",
        ),
        "bin": attrs.transition_dep(
            cfg = wasm_transition,
            providers = [DefaultInfo],
            doc = "The WebAssembly reactor binary to turn into a component.",
        ),
        "_wasm_toolchain": attrs.default_only(
            attrs.toolchain_dep(
                default = "toolchains//:wasm",
                providers = [WasmToolchainInfo],
            ),
        ),
    },
)
