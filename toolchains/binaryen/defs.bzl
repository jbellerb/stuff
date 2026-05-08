BinaryenToolchainInfo = provider(
    fields = {
        "wasm_opt": provider_field(RunInfo),
    },
)

def _binaryen_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    return [
        DefaultInfo(),
        BinaryenToolchainInfo(wasm_opt = ctx.attrs.wasm_opt[RunInfo]),
    ]

binaryen_toolchain = rule(
    impl = _binaryen_toolchain_impl,
    attrs = {
        "wasm_opt": attrs.exec_dep(
            providers = [RunInfo],
            doc = "The wasm-opt binary.",
        ),
    },
    is_toolchain_rule = True,
)
