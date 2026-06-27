WasmToolchainInfo = provider(
    fields = {
        "wasm_opt": provider_field(RunInfo),
        "wasm_tools": provider_field(RunInfo),
    },
)

def _wasm_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    return [
        DefaultInfo(),
        WasmToolchainInfo(
            wasm_opt = ctx.attrs.wasm_opt[RunInfo],
            wasm_tools = ctx.attrs.wasm_tools[RunInfo],
        ),
    ]

wasm_toolchain = rule(
    impl = _wasm_toolchain_impl,
    attrs = {
        "wasm_opt": attrs.exec_dep(
            providers = [RunInfo],
            doc = "The wasm-opt binary.",
        ),
        "wasm_tools": attrs.exec_dep(
            providers = [RunInfo],
            doc = "The wasm-tools binary.",
        ),
    },
    is_toolchain_rule = True,
)
