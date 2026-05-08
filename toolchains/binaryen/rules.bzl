load(":defs.bzl", "BinaryenToolchainInfo")
load(":wasm_transition.bzl", "wasm_transition")

def _wasm_optimize_impl(ctx: AnalysisContext) -> list[Provider]:
    binaryen_toolchain = ctx.attrs._binaryen_toolchain[BinaryenToolchainInfo]

    output = ctx.actions.declare_output(ctx.label.name + ".wasm")

    bin = ctx.attrs.bin[DefaultInfo]
    if len(bin.default_outputs) != 1:
        fail("Expected single output artifact.")

    cmd = cmd_args([
        binaryen_toolchain.wasm_opt,
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
        "_binaryen_toolchain": attrs.default_only(
            attrs.toolchain_dep(
                default = "toolchains//:binaryen",
                providers = [BinaryenToolchainInfo],
            ),
        ),
    },
)
