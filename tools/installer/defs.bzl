def _install_impl(ctx: AnalysisContext) -> list[Provider]:
    files = {}
    for dest, src in ctx.attrs.srcs.items():
        artifacts = src[DefaultInfo].default_outputs
        if len(artifacts) == 0:
            fail("Source target {} has no outputs".format(src.label))
        files[dest] = artifacts[0]

    return [
        DefaultInfo(),
        InstallInfo(
            installer = ctx.attrs._installer.label,
            files = files,
        ),
    ]

install = rule(
    impl = _install_impl,
    attrs = {
        "srcs": attrs.dict(
            key = attrs.string(),
            value = attrs.dep(),
            doc = "Mapping from destination paths to source targets.",
        ),
        "_installer": attrs.default_only(
            attrs.exec_dep(default = "//tools/installer:installer"),
        ),
    },
    doc = """
    Create an installable target that symlinks files to destinations.

    The install rule creates a target that can be installed with `buck2 install`. When
    installed, it creates a symbolic link from the destination to the build artifacts.
    """,
)
