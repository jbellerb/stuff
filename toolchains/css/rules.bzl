load(":defs.bzl", "CssToolchainInfo")

def _css_bundle_impl(ctx: AnalysisContext) -> list[Provider]:
    css_toolchain = ctx.attrs._css_toolchain[CssToolchainInfo]

    if ctx.attrs.outfile:
        outfile = ctx.attrs.outfile
    else:
        outfile = ctx.label.name
        if not outfile.endswith(".css"):
            outfile += ".css"
    output = ctx.actions.declare_output(outfile)

    bundle = cmd_args(
        [css_toolchain.lightningcss, "--bundle"],
        hidden = ctx.attrs.srcs,
    )
    if ctx.attrs.minify:
        bundle.add("--minify")
    if ctx.attrs.targets != []:
        bundle.add("--targets", ", ".join(ctx.attrs.targets))
    if ctx.attrs.sourcemap:
        bundle.add("--sourcemap")
    bundle.add("--output-file", output.as_output(), ctx.attrs.entrypoint)

    ctx.actions.run(
        bundle,
        category = "css_bundle",
        identifier = ctx.label.name,
    )

    return [DefaultInfo(default_output = output)]

css_bundle = rule(
    impl = _css_bundle_impl,
    attrs = {
        "entrypoint": attrs.source(
            doc = "The CSS entrypoint.",
        ),
        "srcs": attrs.list(
            attrs.source(),
            default = [],
            doc = "Additional source files available to the bundler.",
        ),
        "outfile": attrs.option(
            attrs.string(),
            default = None,
            doc = "The output filename. Defaults to the rule name with a .css extension.",
        ),
        "minify": attrs.bool(
            default = False,
            doc = "Minify the output.",
        ),
        "targets": attrs.list(
            attrs.string(),
            default = [],
            doc = "Browser targets as browserslist queries.",
        ),
        "sourcemap": attrs.bool(
            default = False,
            doc = "Emit a sourcemap next to the output.",
        ),
        "_css_toolchain": attrs.default_only(
            attrs.toolchain_dep(
                default = "toolchains//:css",
                providers = [CssToolchainInfo],
            ),
        ),
    },
)
