NodePackage = record(
    package = str,
    contents = Artifact,
)

def _project_as_package_json(entry: NodePackage) -> dict:
    return {
        "pkg": entry.package,
        "path": entry.contents,
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
    ctx.actions.symlinked_dir(contents.as_output(), srcs)

    return [
        DefaultInfo(default_output = contents),
        NodePackageInfo(
            lib = ctx.actions.tset(
                NodePackageTSet,
                value = NodePackage(package = package, contents = contents),
                children = [dep[NodePackageInfo].lib for dep in ctx.attrs.deps],
            ),
        ),
    ]

node_package = rule(
    impl = _node_package_impl,
    attrs = {
        "package": attrs.option(
            attrs.string(),
            default = None,
            doc = "The package name.",
        ),
        "version": attrs.string(
            default = "0.0.0",
            doc = "The package version.",
        ),
        "main": attrs.option(
            attrs.source(),
            default = None,
            doc = "The JS entrypoint.",
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
        "package_json": attrs.option(
            attrs.source(),
            default = None,
            doc = "A package.json to use instead of the generated one.",
        ),
        "deps": attrs.list(
            attrs.dep(providers = [NodePackageInfo]),
            default = [],
            doc = "The package dependencies.",
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
    attrs = {
        "package": attrs.string(
            doc = "The npm package name, used as the entry inside node_modules.",
        ),
        "contents": attrs.source(
            doc = "The unpacked package contents to symlink into node_modules.",
        ),
    },
    artifact_promise_mappings = {
        "node_modules": lambda x: x[DefaultInfo].default_outputs[0],
    },
)
