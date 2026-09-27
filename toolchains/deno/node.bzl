load("@root//tools/reflink/defs.bzl", "reflink_dir")

NodePackage = record(
    contents = Artifact,
    package = str,
)

def _project_as_package_json(entry: NodePackage) -> dict:
    return {
        "path": entry.contents,
        "pkg": entry.package,
    }

NodePackageTSet = transitive_set(
    json_projections = {"package": _project_as_package_json},
)

NodePackageInfo = provider(
    fields = {"lib": provider_field(NodePackageTSet)},
)

def _node_package_impl(ctx: AnalysisContext) -> list[Provider]:
    package = ctx.attrs.package if ctx.attrs.package != None else ctx.label.name

    # named_set is sometimes a list, sometimes a dict.
    if type(ctx.attrs.srcs) == type({}):
        srcs = dict(ctx.attrs.srcs)
    else:
        srcs = {src.short_path: src for src in ctx.attrs.srcs}
    if ctx.attrs.main != None:
        srcs[ctx.attrs.main.short_path] = ctx.attrs.main

    if ctx.attrs.package_json != None:
        package_json = ctx.attrs.package_json
    else:
        manifest = {"name": package, "version": ctx.attrs.version}
        if ctx.attrs.type != None:
            manifest["type"] = ctx.attrs.type
        if ctx.attrs.main != None:
            manifest["main"] = ctx.attrs.main.short_path
        package_json = ctx.actions.write_json("package.json", manifest)
    srcs["package.json"] = package_json

    contents = ctx.actions.declare_output(ctx.label.name, dir = True)
    reflink_dir(
        ctx.actions,
        ctx.attrs._reflinker[RunInfo],
        contents.as_output(),
        [(src, path) for path, src in srcs.items()],
    )

    return [
        DefaultInfo(default_output = contents),
        NodePackageInfo(
            lib = ctx.actions.tset(
                NodePackageTSet,
                children = [dep[NodePackageInfo].lib for dep in ctx.attrs.deps],
                value = NodePackage(contents = contents, package = package),
            ),
        ),
    ]

node_package = rule(
    impl = _node_package_impl,
    attrs = {
        "deps": attrs.list(
            attrs.dep(providers = [NodePackageInfo]),
            default = [],
            doc = "The package dependencies.",
        ),
        "main": attrs.option(
            attrs.source(),
            default = None,
            doc = "The JS entrypoint.",
        ),
        "package": attrs.option(
            attrs.string(),
            default = None,
            doc = "The package name.",
        ),
        "package_json": attrs.option(
            attrs.source(),
            default = None,
            doc = "A package.json to use instead of the generated one.",
        ),
        "srcs": attrs.named_set(
            attrs.source(),
            default = [],
            doc = "Additional JS files to reference.",
        ),
        "type": attrs.option(
            attrs.string(),
            default = None,
            doc = "The package type.",
        ),
        "version": attrs.string(
            default = "0.0.0",
            doc = "The package version.",
        ),
        "_reflinker": attrs.default_only(
            attrs.exec_dep(
                default = "root//tools/reflink:reflink",
                providers = [RunInfo],
            )
        ),
    },
)

def _node_module_impl(ctx: AnalysisContext) -> list[Provider]:
    node_modules = ctx.actions.declare_output("node_modules", dir = True)
    ctx.actions.symlinked_dir(
        node_modules.as_output(),
        {ctx.attrs.package: ctx.attrs.contents},
    )
    return [DefaultInfo(default_output = node_modules)]

node_module = anon_rule(
    impl = _node_module_impl,
    artifact_promise_mappings = {
        "node_modules": lambda x: x[DefaultInfo].default_outputs[0],
    },
    attrs = {
        "contents": attrs.source(
            doc = "The unpacked package contents to symlink into node_modules.",
        ),
        "package": attrs.string(
            doc = "The npm package name, used as the entry inside node_modules.",
        ),
    },
)
