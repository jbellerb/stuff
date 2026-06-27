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
