load("@prelude//http_archive:exec_deps.bzl", "HttpArchiveExecDeps")
load("@prelude//http_archive:unarchive.bzl", "unarchive")

NodePackageInfo = provider(
    fields = {
        "package": provider_field(str),
        "contents": provider_field(Artifact),
    },
)

def _parse_npm_name(name: str) -> typing.Any:
    if name.startswith("@"):
        scope, package = name.split("/", 1)
        return scope, package
    return "", name

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
        output_name = ctx.label.name,
        ext_type = "tar.gz",
        excludes = [],
        strip_prefix = "package",
        sub_targets = [],
        exec_deps = ctx.attrs._archive_exec_deps[HttpArchiveExecDeps],
        prefer_local = True,
    )

    return [
        DefaultInfo(default_output = output),
        NodePackageInfo(
            package = full_package,
            contents = output,
        ),
    ]

npm_package = rule(
    impl = _npm_package_impl,
    attrs = {
        "package": attrs.option(
            attrs.string(),
            default = None,
            doc = "The npm package name. Defaults to the rule name.",
        ),
        "version": attrs.string(
            doc = "The npm package version.",
        ),
        "sha256": attrs.option(
            attrs.string(),
            default = None,
            doc = "The SHA-256 hash of the downloaded archive.",
        ),
        "_archive_exec_deps": attrs.default_only(attrs.exec_dep(
            providers = [HttpArchiveExecDeps],
            default = "prelude//http_archive/tools:exec_deps",
        )),
    },
)
