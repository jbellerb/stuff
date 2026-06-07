load("//deno:defs.bzl", "DenoToolchainInfo")
load("//deno:npm.bzl", "NodePackageInfo")

EsbuildToolchainInfo = provider(
    fields = {
        "esbuild": provider_field(Artifact),
        "deno": provider_field(RunInfo),
        "esbuild_build": provider_field(RunInfo),
    },
)

def _esbuild_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    return [
        DefaultInfo(),
        EsbuildToolchainInfo(
            esbuild = ctx.attrs.esbuild[DefaultInfo].default_outputs[0],
            deno = ctx.attrs.deno[DenoToolchainInfo].deno,
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
        "deno": attrs.toolchain_dep(
            default = "toolchains//:deno",
            providers = [DenoToolchainInfo],
            doc = "The Deno toolchain.",
        ),
        "esbuild_build": attrs.exec_dep(providers = [RunInfo]),
    },
    is_toolchain_rule = True,
)
