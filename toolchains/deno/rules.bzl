load(":defs.bzl", "DenoToolchainInfo")
load(":node.bzl", "NodePackageInfo")

def _deno_binary_impl(ctx: AnalysisContext) -> list[Provider]:
    deno_toolchain = ctx.attrs._deno_toolchain[DenoToolchainInfo]

    cfg = {"lock": False}
    hidden = []
    if ctx.attrs.npm_deps != []:
        # workspace members must be nested under the workspace root, so we
        # symlink each package into a `workspace/` dir beside deno.json.
        # Traverse each dependency's own transitive set rather than merging them
        # into a fresh TSet. TSets can't cross cell boundaries, so this is
        # required for toolchain rules to call third-party dependencies.
        #
        # TODO: should toolchains have a separate set of third-party packages?
        members = {
            package.package: package.contents
            for dep in ctx.attrs.npm_deps
            for package in dep[NodePackageInfo].lib.traverse()
        }
        workspace = ctx.actions.symlinked_dir("workspace", members)
        cfg["workspace"] = ["./workspace/" + package for package in members]
        hidden.append(workspace)

    deno_cfg = ctx.actions.write_json(
        ctx.actions.declare_output("deno.json").as_output(),
        cfg,
        with_inputs = True,
    )

    permissions = cmd_args(ctx.attrs.permissions, format = "--allow-{}")
    unstable_features = cmd_args(ctx.attrs.unstable_features, format = "--unstable-{}")
    includes = cmd_args(
        [x for x in ctx.attrs.srcs if x != ctx.attrs.main],
        format = "--include={}",
    )

    output = ctx.actions.declare_output(ctx.label.name)

    cmd = cmd_args([
        deno_toolchain.deno,
        "compile",
        "--config",
        deno_cfg,
        "--no-remote",
        permissions,
        unstable_features,
        includes,
        cmd_args(["--no-check"] if ctx.attrs.skip_check else []),
        "--output",
        output.as_output(),
        ctx.attrs.main,
    ], hidden = hidden)

    ctx.actions.run(cmd, category = "deno_compile", identifier = ctx.label.name)

    return [
        DefaultInfo(default_output = output),
        RunInfo(
            args = cmd_args([
                deno_toolchain.deno,
                "run",
                "--config",
                deno_cfg,
                "--no-remote",
                permissions,
                unstable_features,
                cmd_args(["--check"] if not ctx.attrs.skip_check else []),
                ctx.attrs.main,
            ], hidden = hidden + [ctx.attrs.srcs]),
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
        # TODO: this shouldn't be an option because we need to set these values
        # from Buck, but the json file is still needed for the Deno CLI. How
        # should these by synced?
        # "config": attrs.option(
        #     attrs.source(),
        #     default = None,
        #     doc = "The deno.json config file.",
        # ),
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
        "npm_deps": attrs.list(
            attrs.dep(providers = [NodePackageInfo]),
            default = [],
            doc = "A list of npm dependencies to provide during execution.",
        ),
        # TODO: Deno dependencies
        "_deno_toolchain": attrs.default_only(
            attrs.toolchain_dep(
                default = "toolchains//:deno",
                providers = [DenoToolchainInfo],
            ),
        ),
    },
)
