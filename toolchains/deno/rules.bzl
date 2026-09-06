load("@root//tools/reflink:defs.bzl", "reflink_dir")
load("//typescript:rules.bzl", "TypeScriptLibraryInfo")
load(":defs.bzl", "DenoToolchainInfo")
load(":node.bzl", "NodePackageInfo")

def _module_imports(modules, cell, package):
    imports = {}
    for i, module in enumerate(modules):
        owner_cell, target = module.specifier.split("//", 1)
        owner_package, name = target.rsplit(":", 1)
        labels = [module.specifier]
        if owner_cell == cell:
            labels.append("//" + target)
            if owner_package == package:
                labels.append(":" + name)

        directory = "./modules/{}/".format(i)
        for label in labels:
            if module.main != None:
                imports[label] = directory + module.main + ".js"
            imports[label + "/"] = directory
    return imports

def _deno_binary_impl(ctx: AnalysisContext) -> list[Provider]:
    deno_toolchain = ctx.attrs._deno_toolchain[DenoToolchainInfo]

    cfg = {"lock": False}
    hidden = []
    modules = {}
    packages = {}

    # traverse each TSet separately for dependencies that originate in another
    # cell
    for dep in ctx.attrs.deps:
        info = dep[TypeScriptLibraryInfo]
        for module in info.transpiled.traverse():
            modules[module.specifier] = module
        for package in info.packages.traverse():
            packages[package.package] = package.contents
    for dep in ctx.attrs.npm_deps:
        for package in dep[NodePackageInfo].lib.traverse():
            packages[package.package] = package.contents

    includes_srcs = list(ctx.attrs.srcs)
    if modules:
        modules = [modules[label] for label in sorted(modules)]
        directory = ctx.actions.declare_output("modules", dir = True)
        reflink_dir(
            ctx.actions,
            ctx.attrs._reflinker[RunInfo],
            directory.as_output(),
            [(module.transpiled, str(i)) for i, module in enumerate(modules)],
            identifier = "modules",
        )
        hidden.append(directory)
        includes_srcs.append(directory)
        cfg["imports"] = _module_imports(modules, str(ctx.label.cell), ctx.label.package)
        cfg["scopes"] = {}
        for i, module in enumerate(modules):
            cell, target = module.specifier.split("//", 1)
            package = target.rsplit(":", 1)[0]
            cfg["scopes"]["./modules/{}/".format(i)] = _module_imports(modules, cell, package)

    if packages:
        # npm packages' real paths must be nested under the workspace root,
        # so we copy each package into a `node_modules/` dir beside deno.json.
        node_modules = ctx.actions.declare_output("node_modules", dir = True)
        reflink_dir(
            ctx.actions,
            ctx.attrs._reflinker[RunInfo],
            node_modules.as_output(),
            [(contents, name) for name, contents in sorted(packages.items())],
            identifier = "node_modules",
        )
        cfg["nodeModulesDir"] = "manual"

        cfg["imports"] = cfg.get("imports", {}) | {name: "npm:" + name for name in packages}

        hidden.append(node_modules)

    deno_cfg = ctx.actions.write_json(
        ctx.actions.declare_output("deno.json").as_output(),
        cfg,
        with_inputs = True,
    )

    permissions = cmd_args(ctx.attrs.permissions, format = "--allow-{}")
    unstable_features = cmd_args(ctx.attrs.unstable_features, format = "--unstable-{}")
    includes = cmd_args(
        [x for x in includes_srcs if x != ctx.attrs.main],
        format = "--include={}",
    )

    output = ctx.actions.declare_output(ctx.label.name)

    cmd = cmd_args(
        [
            deno_toolchain.deno,
            "compile",
            "--config",
            deno_cfg,
            "--no-remote",
            permissions,
            unstable_features,
            includes,
            cmd_args(["--no-check"] if ctx.attrs.skip_check else []),
            "--output",
            output.as_output(),
            ctx.attrs.main,
        ],
        hidden = hidden,
    )

    ctx.actions.run(cmd, category = "deno_compile", identifier = ctx.label.name)

    return [
        DefaultInfo(default_output = output),
        RunInfo(
            args = cmd_args(
                [
                    deno_toolchain.deno,
                    "run",
                    "--config",
                    deno_cfg,
                    "--no-remote",
                    permissions,
                    unstable_features,
                    cmd_args(["--check"] if not ctx.attrs.skip_check else []),
                    ctx.attrs.main,
                ],
                hidden = hidden + [ctx.attrs.srcs],
            ),
        ),
    ]

deno_binary = rule(
    impl = _deno_binary_impl,
    attrs = {
        "deps": attrs.list(
            attrs.dep(providers = [TypeScriptLibraryInfo]),
            default = [],
            doc = "TypeScript libraries, including their transitive modules and npm packages.",
        ),
        "main": attrs.source(doc = "The JS/TS entrypoint."),
        "npm_deps": attrs.list(
            attrs.dep(providers = [NodePackageInfo]),
            default = [],
            doc = "A list of npm dependencies to provide during execution.",
        ),
        "permissions": attrs.list(
            attrs.string(),
            default = [],
            doc = "Permissions to enable.",
        ),
        # TODO: this shouldn't be an option because we need to set these values
        # from Buck, but the json file is still needed for the Deno CLI. How
        # should these by synced?
        # "config": attrs.option(
        #     attrs.source(),
        #     default = None,
        #     doc = "The deno.json config file.",
        # ),
        "skip_check": attrs.bool(default = False, doc = "Disable type checking."),
        "srcs": attrs.list(
            attrs.source(),
            default = [],
            doc = "Additional JS/TS files to reference.",
        ),
        "unstable_features": attrs.list(
            attrs.string(),
            default = [],
            doc = "Unsable features to enable.",
        ),
        "_deno_toolchain": attrs.default_only(
            attrs.toolchain_dep(
                default = "toolchains//:deno",
                providers = [DenoToolchainInfo],
            ),
        ),
        "_reflinker": attrs.default_only(
            attrs.exec_dep(
                default = "root//tools/reflink:reflink",
                providers = [RunInfo],
            ),
        ),
    },
)
