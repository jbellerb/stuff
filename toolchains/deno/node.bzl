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
