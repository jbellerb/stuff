load("@prelude//http_archive:exec_deps.bzl", "HttpArchiveExecDeps")
load("@prelude//http_archive:unarchive.bzl", "unarchive")
load(":node.bzl", "NodePackage", "NodePackageInfo", "NodePackageTSet")

def _parse_npm_name(name: str) -> typing.Any:
    scope, package = "", name
    if name.startswith("@"):
        scope, _, package = name.partition("/")
    if package == "" or "/" in package:
        fail("Failed to parse npm package name: {}".format(name))
    return scope, package

def _npm_package_impl(ctx: AnalysisContext) -> list[Provider]:
    scope, package = _parse_npm_name(
        ctx.attrs.package if ctx.attrs.package != None else ctx.label.name,
    )
    full_package = "{}/{}".format(scope, package) if scope else package

    url = "https://registry.npmjs.org/{}/-/{}-{}.tgz".format(
        full_package,
        package,
        ctx.attrs.version,
    )

    archive = ctx.actions.declare_output("archive.tar.gz")
    ctx.actions.download_file(
        archive.as_output(),
        url,
        sha256 = ctx.attrs.sha256,
    )

    output, _ = unarchive(
        ctx,
        archive = archive,
        excludes = [],
        exec_deps = ctx.attrs._archive_exec_deps[HttpArchiveExecDeps],
        ext_type = "tar.gz",
        output_name = ctx.label.name,
        prefer_local = True,
        strip_prefix = ctx.attrs.strip_prefix,
        sub_targets = [],
    )

    return [
        DefaultInfo(default_output = output),
        NodePackageInfo(
            lib = ctx.actions.tset(
                NodePackageTSet,
                children = [dep[NodePackageInfo].lib for dep in ctx.attrs.deps],
                value = NodePackage(contents = output, package = full_package),
            ),
        ),
    ]

npm_package = rule(
    impl = _npm_package_impl,
    attrs = {
        "deps": attrs.list(
            attrs.dep(providers = [NodePackageInfo]),
            default = [],
            doc = "The package dependencies.",
        ),
        "package": attrs.option(
            attrs.string(),
            default = None,
            doc = "The npm package name. Defaults to the rule name.",
        ),
        "sha256": attrs.option(
            attrs.string(),
            default = None,
            doc = "The SHA-256 hash of the downloaded archive.",
        ),
        "strip_prefix": attrs.string(
            default = "package",
            doc = """
            Leading path to strip from the archive. npm tarballs root at
            `package/`, but some (e.g. `@types/node`) use a different directory.
            """,
        ),
        "version": attrs.string(
            doc = "The npm package version.",
        ),
        "_archive_exec_deps": attrs.default_only(
            attrs.exec_dep(
                default = "prelude//http_archive/tools:exec_deps",
                providers = [HttpArchiveExecDeps],
            )
        ),
    },
)
