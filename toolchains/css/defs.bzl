CssToolchainInfo = provider(
    fields = {
        "lightningcss": provider_field(Artifact),
    },
)

def _css_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    return [
        DefaultInfo(),
        CssToolchainInfo(
            lightningcss = ctx.attrs.lightningcss[DefaultInfo].default_outputs[0],
        ),
    ]

css_toolchain = rule(
    impl = _css_toolchain_impl,
    attrs = {
        "lightningcss": attrs.exec_dep(
            doc = "The Lightning CSS CLI binary.",
            providers = [RunInfo],
        ),
    },
    is_toolchain_rule = True,
)
