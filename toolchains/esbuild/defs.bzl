EsbuildToolchainInfo = provider(
    fields = {
        "esbuild": provider_field(RunInfo),
    },
)

def _esbuild_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    return [
        DefaultInfo(),
        EsbuildToolchainInfo(esbuild = ctx.attrs.esbuild[RunInfo]),
    ]

esbuild_toolchain = rule(
    impl = _esbuild_toolchain_impl,
    attrs = {
        "esbuild": attrs.exec_dep(
            providers = [RunInfo],
            doc = "The esbuild binary.",
        ),
    },
    is_toolchain_rule = True,
)
