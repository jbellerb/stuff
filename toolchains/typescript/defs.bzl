TypeScriptBundlerInfo = provider(
    fields = {
        "bundle": provider_field(RunInfo),
        "env": provider_field(dict, default = {}),
        "supports_splitting": provider_field(bool, default = False),
    },
)

TypeScriptBundleInfo = provider(fields = ["directory", "urls"])

TypeScriptToolchainInfo = provider(
    fields = {
        "bundler": provider_field(TypeScriptBundlerInfo),
        "tsc_build": provider_field(WorkerInfo),
    },
)

def _typescript_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    return [
        DefaultInfo(),
        TypeScriptToolchainInfo(
            bundler = ctx.attrs.bundler[TypeScriptBundlerInfo],
            tsc_build = WorkerInfo(exe = ctx.attrs.tsc_build[RunInfo].args),
        ),
    ]

typescript_toolchain = rule(
    impl = _typescript_toolchain_impl,
    attrs = {
        "bundler": attrs.exec_dep(
            doc = "The bundler used by typescript_bundle.",
            providers = [TypeScriptBundlerInfo],
        ),
        "tsc_build": attrs.exec_dep(providers = [RunInfo]),
    },
    is_toolchain_rule = True,
)
