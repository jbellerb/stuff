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
    An executable\\_file() rule creates an excutable file target with RunInfo.

    Unlike sh\\_binary(), the original file is run without a wrapper. This makes
    it suitable for installation.
    """,
)

def _executable_args_impl(ctx: AnalysisContext) -> list[Provider]:
    return [
        DefaultInfo(),
        RunInfo(args = ctx.attrs.cmd),
    ]

executable_args = rule(
    impl = _executable_args_impl,
    attrs = {
        "cmd": attrs.list(attrs.arg(), doc = "The command args."),
    },
    doc = """
    An executable\\_args() rule creates an excutable target with RunInfo from
    a list of command line args.
    """,
)
