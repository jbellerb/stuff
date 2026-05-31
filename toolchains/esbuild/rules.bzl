load("//deno:npm.bzl", "NodePackageInfo", "NodePackageTSet")
load(":defs.bzl", "EsbuildToolchainInfo")

def _esbuild_bundle_impl(ctx: AnalysisContext) -> list[Provider]:
    esbuild_toolchain = ctx.attrs._esbuild_toolchain[EsbuildToolchainInfo]

    if ctx.attrs.outfile:
        outfile = ctx.attrs.outfile
    else:
        outfile = ctx.label.name
        if not ctx.label.name.endswith(".js"):
            outfile += ".js"
    output = ctx.actions.declare_output(outfile)

    cmd = cmd_args([
        esbuild_toolchain.esbuild,
        ctx.attrs.entrypoints,
    ], hidden = ctx.attrs.srcs)

    if ctx.attrs.bundle:
        cmd.add("--bundle")

    if ctx.attrs.format != None:
        cmd.add("--format=" + ctx.attrs.format)

    if ctx.attrs.platform != None:
        cmd.add("--platform=" + ctx.attrs.platform)

    if ctx.attrs.target != []:
        cmd.add("--target=" + ",".join(ctx.attrs.target))

    if ctx.attrs.tsconfig != None:
        cmd.add(cmd_args(ctx.attrs.tsconfig, format = "--tsconfig={}"))

    if ctx.attrs.minify:
        cmd.add("--minify")

    if ctx.attrs.sourcemap != None:
        cmd.add("--sourcemap=" + ctx.attrs.sourcemap)

    for pkg in ctx.attrs.external:
        cmd.add("--external:" + pkg)

    for key, value in ctx.attrs.define.items():
        cmd.add("--define:" + key + "=" + value)

    for ext, loader_type in ctx.attrs.loader.items():
        cmd.add("--loader:" + ext + "=" + loader_type)

    cmd.add(cmd_args(output.as_output(), format = "--outfile={}"))

    deps = [
        "{}:{}".format(dep.package, dep.contents)
        for dep in ctx.actions.tset(
            NodePackageTSet,
            children = [dep[NodePackageInfo].lib for dep in ctx.attrs.deps],
        ).traverse()
    ]

    bundle = cmd_args([
        "sh",
        "-c",
        r"""
mkdir -p "$BUCK_SCRATCH_PATH/node_path"

while test "$#" -gt 0
do
    if test "$1" = "--"
    then
        shift
        break
    fi

    package=${1%:*}
    path=${1##*:}
    scope=${package%/*}
    test "$scope" = "$package" || \
        mkdir -p "$BUCK_SCRATCH_PATH/node_path/$scope"

    ln -s "$PWD/$path" "$BUCK_SCRATCH_PATH/node_path/$package"
    shift
done

NODE_PATH="$BUCK_SCRATCH_PATH/node_path" "$@"
""",
        "--",
        deps,
        "--",
        cmd,
    ])

    ctx.actions.run(bundle, category = "esbuild_bundle", identifier = ctx.label.name)

    return [DefaultInfo(default_output = output)]

esbuild_bundle = rule(
    impl = _esbuild_bundle_impl,
    attrs = {
        "entrypoints": attrs.list(
            attrs.source(),
            doc = "The JS/TS entrypoints.",
        ),
        "srcs": attrs.list(
            attrs.source(),
            default = [],
            doc = "Additional source files available to the bundler.",
        ),
        "deps": attrs.list(
            attrs.dep(providers = [NodePackageInfo]),
            default = [],
            doc = "A list of dependencies to include in NODE_PATH.",
        ),
        "outfile": attrs.option(
            attrs.string(),
            default = None,
            doc = "The output filename. Defaults to the rule name with a .js extension.",
        ),
        "bundle": attrs.bool(
            default = True,
            doc = "Inline all imported dependencies into the output.",
        ),
        "format": attrs.option(
            attrs.enum(["iife", "cjs", "esm"]),
            default = None,
            doc = "Output format for the generated JavaScript bundle.",
        ),
        "platform": attrs.option(
            attrs.enum(["browser", "node", "neutral"]),
            default = None,
            doc = "Platform to target.",
        ),
        "target": attrs.list(
            attrs.string(),
            default = [],
            doc = "Target environments for the generated JavaScript.",
        ),
        "tsconfig": attrs.option(
            attrs.source(),
            default = None,
            doc = "A custom tsconfig.json to use.",
        ),
        "minify": attrs.bool(
            default = False,
            doc = "Minify the output.",
        ),
        "sourcemap": attrs.option(
            attrs.enum(["inline", "linked", "external", "both"]),
            default = None,
            doc = "Sourcemap generation mode.",
        ),
        "external": attrs.list(
            attrs.string(),
            default = [],
            doc = "Packages to exclude from the bundle.",
        ),
        "define": attrs.dict(
            attrs.string(),
            attrs.string(),
            default = {},
            doc = "Replace global identifiers with constant expressions.",
        ),
        "loader": attrs.dict(
            attrs.string(),
            attrs.string(),
            default = {},
            doc = "Map file extensions to esbuild loaders.",
        ),
        "_esbuild_toolchain": attrs.default_only(
            attrs.toolchain_dep(
                default = "toolchains//:esbuild",
                providers = [EsbuildToolchainInfo],
            ),
        ),
    },
)
