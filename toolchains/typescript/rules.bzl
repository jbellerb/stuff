load("//deno:node.bzl", "NodePackageInfo", "NodePackageTSet")
load(":defs.bzl", "TypeScriptToolchainInfo")

TypeScriptModule = record(
    specifier = str,
    main = field([str, None], default = None),
    # directory of tsc-emitted .js and .d.ts files.
    transpiled = Artifact,
)

def _project_module_as_json(module: TypeScriptModule):
    return module

TypeScriptModuleTSet = transitive_set(
    json_projections = {"module": _project_module_as_json},
)

def _project_lib_as_args(lib: list[str]):
    return cmd_args(lib)

TypeScriptLibTSet = transitive_set(
    args_projections = {"lib": _project_lib_as_args},
)

TypeScriptLibraryInfo = provider(
    fields = {
        "transpiled": provider_field(TypeScriptModuleTSet),
        "lib": provider_field(TypeScriptLibTSet),
        # npm packages needed to resolve imports in this library and the .d.ts
        # files it re-exports.
        "packages": provider_field(NodePackageTSet),
    },
)

def _normalize_srcs(
        srcs: [list[Artifact], dict[str, Artifact]]) -> dict[str, Artifact]:
    if type(srcs) == type({}):
        return srcs
    else:
        return {src.short_path: src for src in srcs}

def _canonical_label(label: Label) -> str:
    return "{}//{}:{}".format(label.cell, label.package, label.name)

def _strip_ts_ext(path: str) -> [str, None]:
    for ext in [".ts", ".tsx", ".mts", ".cts"]:
        if path.endswith(ext):
            return path[:-len(ext)]
    return None

def _split_deps(deps: list[Dependency]) -> (list, list):
    ts_deps = []
    package_children = []
    for dep in deps:
        ts_info = dep.get(TypeScriptLibraryInfo)
        node_info = dep.get(NodePackageInfo)
        if ts_info != None:
            ts_deps.append(ts_info)
            package_children.append(ts_info.packages)
        elif node_info != None:
            package_children.append(node_info.lib)
        else:
            fail("{}: not a typescript_library or node package".format(dep.label))
    return ts_deps, package_children

def _typescript_library_impl(ctx: AnalysisContext) -> list[Provider]:
    toolchain = ctx.attrs._typescript_toolchain[TypeScriptToolchainInfo]

    srcs = _normalize_srcs(ctx.attrs.srcs)

    main = None
    if ctx.attrs.main != None:
        main = _strip_ts_ext(ctx.attrs.main.short_path)
    elif "index.ts" in srcs:
        main = "index"
    elif len(srcs) == 1:
        main = _strip_ts_ext(srcs.keys()[0])

    ts_deps, package_children = _split_deps(ctx.attrs.deps)
    packages = ctx.actions.tset(NodePackageTSet, children = package_children)
    dep_modules = ctx.actions.tset(
        TypeScriptModuleTSet,
        children = [dep.transpiled for dep in ts_deps],
    )

    lib = ctx.actions.tset(
        TypeScriptLibTSet,
        value = ctx.attrs.lib,
        children = [dep.lib for dep in ts_deps],
    )

    output = ctx.actions.declare_output(ctx.label.name, dir = True)

    config = {
        "cell": str(ctx.label.cell),
        "package": ctx.label.package,
        "srcs": srcs,
        "deps": dep_modules.project_as_json("module"),
        "packages": packages.project_as_json("package"),
        "lib": lib.project_as_args("lib"),
    }

    tsc_cfg = ctx.actions.write_json(
        ctx.actions.declare_output("tsc.json").as_output(),
        config,
        with_inputs = True,
    )

    ctx.actions.run(
        cmd_args([toolchain.tsc_build, tsc_cfg, output.as_output()]),
        category = "tsc",
        identifier = ctx.label.name,
    )

    return [
        DefaultInfo(default_output = output),
        TypeScriptLibraryInfo(
            transpiled = ctx.actions.tset(
                TypeScriptModuleTSet,
                value = TypeScriptModule(
                    specifier = _canonical_label(ctx.label),
                    main = main,
                    transpiled = output,
                ),
                children = [dep.transpiled for dep in ts_deps],
            ),
            lib = lib,
            packages = packages,
        ),
    ]

_typescript_library_attrs = {
    "srcs": attrs.named_set(
        attrs.source(),
        default = [],
        doc = "The TypeScript sources.",
    ),
    "main": attrs.option(
        attrs.source(),
        default = None,
        doc = """
        The module a bare import of this library's label resolves to. Defaults
        to index.ts if present, or the only source.
        """,
    ),
    "deps": attrs.list(
        attrs.dep(),
        default = [],
        doc = "typescript_library and npm package dependencies.",
    ),
    "lib": attrs.list(
        attrs.string(),
        default = [],
        doc = "tsconfig lib entries this library type checks against.",
    ),
    "_typescript_toolchain": attrs.default_only(
        attrs.toolchain_dep(
            default = "toolchains//:typescript",
            providers = [TypeScriptToolchainInfo],
        ),
    ),
}

typescript_library = rule(
    impl = _typescript_library_impl,
    attrs = _typescript_library_attrs,
)

def _typescript_bundle_impl(ctx: AnalysisContext) -> list[Provider]:
    # wrap _typescript_library_impl instead of reimplementing the build logic
    # here. This works as long as both rules don't have any conflicting attrs.
    lib_providers = _typescript_library_impl(ctx)
    info = None
    for provider in lib_providers:
        if isinstance(provider, TypeScriptLibraryInfo):
            info = provider

    toolchain = ctx.attrs._typescript_toolchain[TypeScriptToolchainInfo]
    bundler = toolchain.bundler

    entry_module = info.transpiled.value
    entry = ctx.attrs.entry if ctx.attrs.entry != None else entry_module.main
    if entry == None:
        fail("{}: has no main module and entry is unset".format(
            _canonical_label(ctx.label),
        ))

    if ctx.attrs.outfile:
        outfile = ctx.attrs.outfile
    else:
        outfile = ctx.label.name
        if not ctx.label.name.endswith(".js"):
            outfile += ".js"
    output = ctx.actions.declare_output(outfile)

    options = {
        "cell": str(ctx.label.cell),
        "package": ctx.label.package,
        "deps": info.transpiled.project_as_json("module"),
        "entryPoints": [
            cmd_args([entry_module.transpiled, "{}.js".format(entry)], delimiter = "/"),
        ],
    }
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

    node_packages = {
        package.package: package.contents
        for package in info.packages.traverse()
    }
    if node_packages:
        node_modules = ctx.actions.declare_output("node_modules", dir = True)
        ctx.actions.symlinked_dir(node_modules.as_output(), node_packages)

        # write_json serializes a cmd_args as a list unless it has a delimiter
        options["nodePaths"] = [cmd_args(node_modules, delimiter = "")]

    bundle_cfg = ctx.actions.write_json(
        ctx.actions.declare_output("bundle.json").as_output(),
        options,
        with_inputs = True,
    )

    ctx.actions.run(
        cmd_args([bundler.bundle, bundle_cfg, output.as_output()]),
        category = "bundle",
        identifier = ctx.label.name,
        env = bundler.env,
    )

    return [DefaultInfo(default_output = output)]

typescript_bundle = rule(
    impl = _typescript_bundle_impl,
    attrs = _typescript_library_attrs | {
        "entry": attrs.option(
            attrs.string(),
            default = None,
            doc = "Entrypoint module, without extension. Defaults to the main module.",
        ),
        "outfile": attrs.option(
            attrs.string(),
            default = None,
            doc = "The output filename. Defaults to the rule name with a .js extension.",
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
    },
)
