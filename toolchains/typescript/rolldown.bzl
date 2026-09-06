load(":defs.bzl", "TypeScriptBundlerInfo")

def _rolldown_bundler_impl(ctx: AnalysisContext) -> list[Provider]:
    return [
        DefaultInfo(),
        TypeScriptBundlerInfo(
            bundle = ctx.attrs.bundle[RunInfo],
            supports_splitting = True,
        ),
    ]

rolldown_bundler = rule(
    impl = _rolldown_bundler_impl,
    attrs = {
        "bundle": attrs.exec_dep(providers = [RunInfo]),
    },
)
