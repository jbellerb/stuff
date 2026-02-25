def _reflink_project_impl(ctx: AnalysisContext) -> list[Provider]:
    if not ctx.attrs.default_output and not ctx.attrs.sub_targets:
        fail("reflink_project requires at least one of default_output and sub_targets")

    info = DefaultInfo()

    # collect all paths to process
    all_paths = []
    if ctx.attrs.default_output:
        all_paths.append((ctx.attrs.default_output, ctx.attrs.default_output))
    if ctx.attrs.sub_targets:
        if type(ctx.attrs.sub_targets) == type({}):
            sub_target_map = ctx.attrs.sub_targets
        else:
            sub_target_map = [(f, f) for f in ctx.attrs.sub_targets]
        all_paths.extend(sub_target_map)

    # sort lexicographically so directories come before their contents
    sorted_paths = sorted(all_paths, key = lambda x: x[1])

    outputs = {}
    default_output = None
    sub_targets = {}

    parent = None
    parent_artifact = None
    for dst, src in sorted_paths:
        if dst in outputs:
            fail("multiple definitions for destination '{}'".format(dst))

        # check if this path is nested within a previously seen directory
        if parent and src.startswith(parent + "/"):
            # project from the directory artifact
            relative_path = src[len(parent) + 1:]
            outputs[dst] = parent_artifact.project(relative_path)
        else:
            # create new reflink
            outputs[dst] = ctx.actions.declare_output(dst)
            ctx.actions.run(
                cmd_args(
                    ctx.attrs._reflinker[RunInfo],
                    "--auto",
                    ctx.attrs.dir.project(src),
                    outputs[dst].as_output(),
                ),
                category = "reflink",
                identifier = dst,
            )
            parent, parent_artifact = src, outputs[dst]

        if ctx.attrs.default_output and src == ctx.attrs.default_output:
            default_output = outputs[dst]
        else:
            sub_targets[dst] = [DefaultInfo(default_output = outputs[dst])]

    return [
        DefaultInfo(default_output = default_output, sub_targets = sub_targets),
    ]

reflink_project = rule(
    impl = _reflink_project_impl,
    attrs = {
        "dir": attrs.source(allow_directory = True),
        "default_output": attrs.option(attrs.string(), default = None),
        "sub_targets": attrs.option(attrs.named_set(attrs.string()), default = None),
        "_reflinker": attrs.default_only(
            attrs.exec_dep(
                providers = [RunInfo],
                default = "//tools/reflink:reflink",
            ),
        ),
    },
    doc = "Project files from a source directory.",
)
