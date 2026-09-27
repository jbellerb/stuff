DenoToolchainInfo = provider(
    fields = {
        "deno": provider_field(RunInfo),
    },
)

def _deno_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    return [
        DefaultInfo(),
        DenoToolchainInfo(deno = ctx.attrs.deno[RunInfo]),
    ]

deno_toolchain = rule(
    impl = _deno_toolchain_impl,
    attrs = {
        "deno": attrs.exec_dep(doc = "The Deno binary.", providers = [RunInfo]),
    },
    is_toolchain_rule = True,
)
