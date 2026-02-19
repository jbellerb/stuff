def _executable_file_impl(ctx: AnalysisContext) -> list[Provider]:
    output = ctx.actions.copy_file(
        ctx.label.name,
        ctx.attrs.src,
        executable_bit_override = True,
    )

    return [
        DefaultInfo(default_output = output),
        RunInfo(args = [output]),
    ]

executable_file = rule(
    impl = _executable_file_impl,
    attrs = {
        "src": attrs.source(doc = "The executable script file"),
    },
    doc = """
    An executable\\_file() rule creates an xecutable file target with RunInfo.

    Unlike sh\\_binary(), the original file is run without a wrapper. This makes
    it suitable for installation.
    """,
)
