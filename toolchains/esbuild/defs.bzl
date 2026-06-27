EsbuildPluginInfo = provider(
    fields = {
        "name": provider_field(str),
        "source": provider_field(Artifact),
    },
)

EsbuildToolchainInfo = provider(
    fields = {
        "esbuild": provider_field(Artifact),
        "esbuild_build": provider_field(RunInfo),
    },
)

def _esbuild_plugin_impl(ctx: AnalysisContext) -> list[Provider]:
    return [
        DefaultInfo(),
        EsbuildPluginInfo(
            name = ctx.label.name,
            source = ctx.attrs.source,
        ),
    ]

esbuild_plugin = rule(
    impl = _esbuild_plugin_impl,
    attrs = {
        "source": attrs.source(
            doc = "The plugin module. Its default export is either an esbuild.Plugin or an " +
                  "(opts) => esbuild.Plugin factory.",
        ),
    },
)

def _esbuild_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    return [
        DefaultInfo(),
        EsbuildToolchainInfo(
            esbuild = ctx.attrs.esbuild[DefaultInfo].default_outputs[0],
            esbuild_build = ctx.attrs.esbuild_build[RunInfo],
        ),
    ]

esbuild_toolchain = rule(
    impl = _esbuild_toolchain_impl,
    attrs = {
        "esbuild": attrs.exec_dep(
            providers = [RunInfo],
            doc = "The esbuild binary.",
        ),
        "esbuild_build": attrs.exec_dep(providers = [RunInfo]),
    },
    is_toolchain_rule = True,
)
