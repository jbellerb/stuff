load(":defs.bzl", "TypeScriptBundlerInfo")

def _esbuild_bundler_impl(ctx: AnalysisContext) -> list[Provider]:
    return [
        DefaultInfo(),
        TypeScriptBundlerInfo(
            bundle = ctx.attrs.bundle[RunInfo],
            env = {
                "ESBUILD_BINARY_PATH": ctx.attrs.esbuild[DefaultInfo].default_outputs[0],
            },
        ),
    ]

esbuild_bundler = rule(
    impl = _esbuild_bundler_impl,
    attrs = {
        "esbuild": attrs.exec_dep(
            providers = [RunInfo],
            doc = "The esbuild binary.",
        ),
        "bundle": attrs.exec_dep(providers = [RunInfo]),
    },
)
