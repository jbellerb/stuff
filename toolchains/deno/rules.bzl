load(":defs.bzl", "DenoToolchainInfo")

def _deno_binary_impl(ctx: AnalysisContext) -> list[Provider]:
    deno_toolchain = ctx.attrs._deno_toolchain[DenoToolchainInfo]

    output = ctx.actions.declare_output(ctx.label.name)
    config = cmd_args(["--config", config] if ctx.attrs.config else [])
    permissions = cmd_args(ctx.attrs.permissions, format = "--allow-{}")
    unstable_features = cmd_args(ctx.attrs.unstable_features, format = "--unstable-{}")
    includes = cmd_args(
        [x for x in ctx.attrs.srcs if x != ctx.attrs.main],
        format = "--include={}",
    )

    cmd = cmd_args([
        deno_toolchain.deno,
        "compile",
        config,
        permissions,
        unstable_features,
        includes,
        cmd_args(["--no-check"] if ctx.attrs.skip_check else []),
        "--output",
        output.as_output(),
        ctx.attrs.main,
    ])

    ctx.actions.run(cmd, category = "deno_compile", identifier = ctx.label.name)

    return [
        DefaultInfo(default_output = output),
        RunInfo(
            args = cmd_args([
                deno_toolchain.deno,
                "run",
                config,
                permissions,
                unstable_features,
                cmd_args(["--check"] if not ctx.attrs.skip_check else []),
                ctx.attrs.main,
            ], hidden = ctx.attrs.srcs),
        ),
    ]

deno_binary = rule(
    impl = _deno_binary_impl,
    attrs = {
        "main": attrs.source(doc = "The JS/TS entrypoint."),
        "srcs": attrs.list(
            attrs.source(),
            default = [],
            doc = "Additional JS/TS files to reference.",
        ),
        "config": attrs.option(
            attrs.source(),
            default = None,
            doc = "The deno.json config file.",
        ),
        "skip_check": attrs.bool(default = False, doc = "Disable type checking."),
        "permissions": attrs.list(
            attrs.string(),
            default = [],
            doc = "Permissions to enable.",
        ),
        "unstable_features": attrs.list(
            attrs.string(),
            default = [],
            doc = "Unsable features to enable.",
        ),
        # TODO: dependencies
        "_deno_toolchain": attrs.default_only(
            attrs.toolchain_dep(
                default = "toolchains//:deno",
                providers = [DenoToolchainInfo],
            ),
        ),
    },
)
