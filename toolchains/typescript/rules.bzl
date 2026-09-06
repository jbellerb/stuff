load("//deno:node.bzl", "NodePackageInfo", "NodePackageTSet")
load(":defs.bzl", "TypeScriptBundleInfo", "TypeScriptToolchainInfo")

TypeScriptModule = record(
    main = field([str, None], default = None),
    specifier = str,
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
        "lib": provider_field(TypeScriptLibTSet),
        # npm packages needed to resolve imports in this library and the .d.ts
        # files it re-exports.
        "packages": provider_field(NodePackageTSet),
        "transpiled": provider_field(TypeScriptModuleTSet),
    },
)

def _normalize_srcs(srcs: [list[Artifact], dict[str, Artifact]]) -> dict[str, Artifact]:
    if type(srcs) == type({}):
        return srcs
    else:
        return {src.short_path: src for src in srcs}

def _canonical_label(label: Label) -> str:
    return "{}//{}:{}".format(label.cell, label.package, label.name)

def _strip_ts_ext(path: str) -> [str, None]:
    for ext in [".ts", ".tsx", ".mts", ".cts"]:
        if path.endswith(ext):
            return path[: -len(ext)]
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

    main = ctx.attrs.main
    srcs = _normalize_srcs(ctx.attrs.extra_srcs) | {main.short_path: main}

    ts_deps, package_children = _split_deps(ctx.attrs.deps)
    packages = ctx.actions.tset(NodePackageTSet, children = package_children)
    dep_modules = ctx.actions.tset(
        TypeScriptModuleTSet,
        children = [dep.transpiled for dep in ts_deps],
    )

    lib = ctx.actions.tset(
        TypeScriptLibTSet,
        children = [dep.lib for dep in ts_deps],
        value = ctx.attrs.lib,
    )

    output = ctx.actions.declare_output(ctx.label.name + "_dist", dir = True)

    config = {
        "alias": getattr(ctx.attrs, "alias", {}),
        "cell": str(ctx.label.cell),
        "deps": dep_modules.project_as_json("module"),
        "lib": lib.project_as_args("lib"),
        "package": ctx.label.package,
        "packages": packages.project_as_json("package"),
        "srcs": srcs,
        "strict": ctx.attrs.strict,
    }

    tsc_cfg = ctx.actions.write_json(
        ctx.actions.declare_output("tsc.json").as_output(),
        config,
        with_inputs = True,
    )

    ctx.actions.run(
        cmd_args([tsc_cfg, output.as_output()]),
        category = "tsc",
        exe = WorkerRunInfo(
            exe = toolchain.tsc_build.exe,
            worker = toolchain.tsc_build,
        ),
        identifier = ctx.label.name,
    )

    return [
        DefaultInfo(default_output = output),
        TypeScriptLibraryInfo(
            lib = lib,
            packages = packages,
            transpiled = ctx.actions.tset(
                TypeScriptModuleTSet,
                children = [dep.transpiled for dep in ts_deps],
                value = TypeScriptModule(
                    main = _strip_ts_ext(main.short_path),
                    specifier = _canonical_label(ctx.label),
                    transpiled = output,
                ),
            ),
        ),
    ]

_typescript_library_attrs = {
    "alias": attrs.dict(attrs.string(), attrs.string(), default = {}, doc = "Import aliases used during type checking."),
    "deps": attrs.list(
        attrs.dep(),
        default = [],
        doc = "typescript_library and npm package dependencies.",
    ),
    "extra_srcs": attrs.named_set(
        attrs.source(),
        default = [],
        doc = "The other TypeScript sources.",
    ),
    "lib": attrs.list(
        attrs.string(),
        default = [],
        doc = "tsconfig lib entries this library type checks against.",
    ),
    "main": attrs.source(
        doc = """
        The main entrypoint of the library. This is the file a bare import of
        this library's label resolves to.
        """,
    ),
    "strict": attrs.bool(
        default = True,
        doc = "Whether to type check under strict mode.",
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
    bundler = ctx.attrs._typescript_toolchain[TypeScriptToolchainInfo].bundler
    if not ctx.attrs.entrypoints:
        fail("entrypoints must not be empty")
    if ctx.attrs.splitting and (not bundler.supports_splitting or ctx.attrs.format != "esm"):
        fail("splitting requires the Rolldown bundler and format = 'esm'")
    if ctx.attrs.assets and not bundler.supports_splitting:
        fail("emitting assets requires the Rolldown bundler")

    if not ctx.attrs.splitting and len(ctx.attrs.entrypoints) != 1:
        fail("splitting = False requires exactly one entrypoint")

    entries = {}
    libraries = []
    for name, dep in ctx.attrs.entrypoints.items():
        if not name.endswith(".js") or name.startswith("/") or ".." in name.split("/"):
            fail("entrypoint names must be relative .js paths: {}".format(name))
        if name in ctx.attrs.assets:
            fail("entrypoint and asset names overlap: {}".format(name))
        info = dep[TypeScriptLibraryInfo]
        module = info.transpiled.value
        if module.main == None:
            fail("entrypoint library has no JavaScript main: {}".format(dep.label))
        entries[name] = cmd_args([module.transpiled, module.main + ".js"], delimiter = "/")
        libraries.append(info)

    modules = ctx.actions.tset(TypeScriptModuleTSet, children = [info.transpiled for info in libraries])
    packages = ctx.actions.tset(NodePackageTSet, children = [info.packages for info in libraries])
    output = ctx.actions.declare_output("bundle", dir = True)
    urls = ctx.actions.declare_output("urls.json")
    options = {
        "assets": ctx.attrs.assets,
        "cell": str(ctx.label.cell),
        "deps": modules.project_as_json("module"),
        "entryPoints": entries,
        "hashNames": ctx.attrs.hash_names,
        "package": ctx.label.package,
        "splitting": ctx.attrs.splitting,
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
    if ctx.attrs.alias != {}:
        options["alias"] = ctx.attrs.alias

    node_packages = {package.package: package.contents for package in packages.traverse()}
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
        cmd_args(
            [bundler.bundle, bundle_cfg, output.as_output(), urls.as_output()],
        ),
        category = "bundle",
        env = bundler.env,
        identifier = ctx.label.name,
    )

    sub_targets = {}
    if not ctx.attrs.hash_names:
        sub_targets = {name: [DefaultInfo(default_output = output.project(name))] for name in ctx.attrs.entrypoints}
    return [
        DefaultInfo(default_output = output, other_outputs = [urls], sub_targets = sub_targets),
        TypeScriptBundleInfo(directory = output, urls = urls),
    ]

typescript_bundle = rule(
    impl = _typescript_bundle_impl,
    attrs = {
        "alias": attrs.dict(
            attrs.string(),
            attrs.string(),
            default = {},
            doc = """
            Remap imports during bundling. For type checking, configure aliases
            on the entrypoint libraries too.
            """,
        ),
        "assets": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "define": attrs.dict(
            attrs.string(),
            attrs.string(),
            default = {},
            doc = "Replace global identifiers with constant expressions.",
        ),
        "entrypoints": attrs.dict(
            attrs.string(),
            attrs.dep(providers = [TypeScriptLibraryInfo]),
        ),
        "external": attrs.list(
            attrs.string(),
            default = [],
            doc = "Packages to exclude from the bundle.",
        ),
        "format": attrs.enum(
            ["iife", "cjs", "esm"],
            default = "esm",
            doc = "Output format for the generated JavaScript bundle.",
        ),
        "hash_names": attrs.bool(
            default = False,
            doc = "Include content hashes in output filenames.",
        ),
        "minify": attrs.bool(
            default = False,
            doc = "Minify the output.",
        ),
        "platform": attrs.option(
            attrs.enum(["browser", "node", "neutral"]),
            default = None,
            doc = "Platform to target.",
        ),
        "sourcemap": attrs.option(
            attrs.enum(["inline", "linked", "external", "both"]),
            default = None,
            doc = "Sourcemap generation mode.",
        ),
        "splitting": attrs.bool(
            default = False,
            doc = "Share ESM chunks across entrypoints. Requires ESM and Rolldown.",
        ),
        "target": attrs.list(
            attrs.string(),
            default = [],
            doc = "Target environments for the generated JavaScript.",
        ),
        "_typescript_toolchain": _typescript_library_attrs["_typescript_toolchain"],
    },
)

def _oxlint_lint_impl(ctx: AnalysisContext) -> list[Provider]:
    oxlint = ctx.attrs._oxlint_cli[RunInfo].args

    config = {}
    if ctx.attrs.categories:
        config["categories"] = ctx.attrs.categories
    if ctx.attrs.rules:
        config["rules"] = ctx.attrs.rules
    if ctx.attrs.env:
        config["env"] = ctx.attrs.env
    if ctx.attrs.globals:
        config["globals"] = ctx.attrs.globals

    oxlintrc = ctx.actions.write_json(
        ctx.actions.declare_output("oxlintrc.json").as_output(),
        config,
    )

    command = cmd_args([
        oxlint,
        "--config",
        oxlintrc,
        ctx.attrs.srcs,
    ])

    return [
        DefaultInfo(),
        ExternalRunnerTestInfo(
            command = [command],
            type = "oxlint",
        ),
    ]

oxlint_lint = rule(
    impl = _oxlint_lint_impl,
    attrs = {
        "categories": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "env": attrs.dict(attrs.string(), attrs.bool(), default = {}),
        "globals": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "rules": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "srcs": attrs.list(attrs.source(), doc = "The JS/TS sources to lint."),
        "_oxlint_cli": attrs.default_only(
            attrs.exec_dep(
                default = "toolchains//typescript:oxlint",
                providers = [RunInfo],
            ),
        ),
    },
)
