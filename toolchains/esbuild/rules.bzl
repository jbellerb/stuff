load("//deno:node.bzl", "NodePackageInfo", "NodePackageTSet")
load(":defs.bzl", "EsbuildPluginInfo", "EsbuildToolchainInfo")

def _joined_arg(arg):
    # write_json serializes a cmd_args as a list, unless it has a delimiter
    # set. Wrap all attrs.arg() with a delimiter to collapse them back into
    # a plain string.
    return cmd_args(arg, delimiter = "")

def _joined_config_value(value):
    if type(value) == "list":
        return [_joined_arg(v) for v in value]
    elif type(value) == "dict":
        return {k: _joined_arg(v) for k, v in value.items()}
    else:
        return _joined_arg(value)

def _esbuild_bundle_impl(ctx: AnalysisContext) -> list[Provider]:
    esbuild_toolchain = ctx.attrs._esbuild_toolchain[EsbuildToolchainInfo]

    if ctx.attrs.outfile:
        outfile = ctx.attrs.outfile
    else:
        outfile = ctx.label.name
        if not ctx.label.name.endswith(".js") and not ctx.label.name.endswith(".css"):
            outfile += ".js"
    output = ctx.actions.declare_output(outfile)

    options = {"entryPoints": ctx.attrs.entrypoints}
    if ctx.attrs.bundle:
        options["bundle"] = True
    if ctx.attrs.format != None:
        options["format"] = ctx.attrs.format
    if ctx.attrs.platform != None:
        options["platform"] = ctx.attrs.platform
    if ctx.attrs.target != []:
        options["target"] = ctx.attrs.target
    if ctx.attrs.minify:
        options["minify"] = True
    if ctx.attrs.sourcemap != None:
        options["sourcemap"] = ctx.attrs.sourcemap
    if ctx.attrs.external != []:
        options["external"] = ctx.attrs.external
    if ctx.attrs.define != {}:
        options["define"] = ctx.attrs.define
    if ctx.attrs.loader != {}:
        options["loader"] = ctx.attrs.loader
    if ctx.attrs.tsconfig != None:
        options["tsconfig"] = ctx.attrs.tsconfig
    if ctx.attrs.deps != []:
        node_modules = ctx.actions.declare_output("node_modules", dir = True)
        deps = ctx.actions.tset(
            NodePackageTSet,
            children = [dep[NodePackageInfo].lib for dep in ctx.attrs.deps],
        )
        ctx.actions.symlinked_dir(
            node_modules.as_output(),
            {dep.package: dep.contents for dep in deps.traverse()},
        )
        options["nodePaths"] = cmd_args(node_modules)
    if ctx.attrs.plugins:
        options["plugins"] = [
            (plugin[EsbuildPluginInfo].name, plugin[EsbuildPluginInfo].source)
            for plugin in ctx.attrs.plugins
        ]
    if ctx.attrs.plugin_config:
        options["pluginConfig"] = {
            plugin: {key: _joined_config_value(value) for key, value in config.items()}
            for plugin, config in ctx.attrs.plugin_config.items()
        }

    bundle_cfg = ctx.actions.write_json(
        ctx.actions.declare_output("bundle.json").as_output(),
        options,
        with_inputs = True,
    )

    bundle = cmd_args(
        [esbuild_toolchain.esbuild_build, bundle_cfg, output.as_output()],
        hidden = ctx.attrs.srcs,
    )

    ctx.actions.run(
        bundle,
        category = "esbuild_bundle",
        identifier = ctx.label.name,
        env = {"ESBUILD_BINARY_PATH": esbuild_toolchain.esbuild},
    )

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
        "plugins": attrs.list(
            attrs.dep(providers = [EsbuildPluginInfo]),
            default = [],
            doc = "A list of esbuild plugins to apply during bundling.",
        ),
        "plugin_config": attrs.dict(
            attrs.string(),
            attrs.dict(
                attrs.string(),
                attrs.one_of(
                    attrs.arg(),
                    attrs.list(attrs.arg()),
                    attrs.dict(attrs.string(), attrs.arg()),
                ),
            ),
            default = {},
            doc = "Per-plugin config objects, passed as JSON to the matching plugin.",
        ),
        "_esbuild_toolchain": attrs.default_only(
            attrs.toolchain_dep(
                default = "toolchains//:esbuild",
                providers = [EsbuildToolchainInfo],
            ),
        ),
    },
)
