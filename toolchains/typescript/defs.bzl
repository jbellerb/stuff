TypeScriptBundlerInfo = provider(
    fields = {
        "bundle": provider_field(RunInfo),
        "env": provider_field(dict, default = {}),
    },
)

TypeScriptToolchainInfo = provider(
    fields = {
        "tsc_build": provider_field(RunInfo),
        "bundler": provider_field(TypeScriptBundlerInfo),
    },
)

def _typescript_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    return [
        DefaultInfo(),
        TypeScriptToolchainInfo(
            tsc_build = ctx.attrs.tsc_build[RunInfo],
            bundler = ctx.attrs.bundler[TypeScriptBundlerInfo],
        ),
    ]

typescript_toolchain = rule(
    impl = _typescript_toolchain_impl,
    attrs = {
        "tsc_build": attrs.exec_dep(providers = [RunInfo]),
        "bundler": attrs.exec_dep(
            providers = [TypeScriptBundlerInfo],
            doc = "The bundler used by typescript_bundle.",
        ),
    },
    is_toolchain_rule = True,
)
