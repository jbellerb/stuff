load("//deno:node.bzl", "NodePackage", "NodePackageInfo", "NodePackageTSet")

_PREVIEW2_SHIM_MAP = {
    "wasi:cli/*": "@bytecodealliance/preview2-shim/cli#*",
    "wasi:clocks/*": "@bytecodealliance/preview2-shim/clocks#*",
    "wasi:filesystem/*": "@bytecodealliance/preview2-shim/filesystem#*",
    "wasi:http/*": "@bytecodealliance/preview2-shim/http#*",
    "wasi:io/*": "@bytecodealliance/preview2-shim/io#*",
    "wasi:random/*": "@bytecodealliance/preview2-shim/random#*",
    "wasi:sockets/*": "@bytecodealliance/preview2-shim/sockets#*",
}

def _jco_transpile_impl(ctx: AnalysisContext) -> list[Provider]:
    component = ctx.attrs.component[DefaultInfo]
    if len(component.default_outputs) != 1:
        fail("Expected single component artifact.")

    package = ctx.attrs.package_name or ctx.label.name
    out = ctx.actions.declare_output("out", dir = True)

    config = ctx.actions.write_json(
        ctx.actions.declare_output("jco.json").as_output(),
        {
            "input": component.default_outputs[0],
            "instantiation": "async",
            "map": ctx.attrs.shim_map,
            "name": ctx.attrs.module_name,
        },
        with_inputs = True,
    )

    ctx.actions.run(
        cmd_args([ctx.attrs._jco_transpile[RunInfo], config, out.as_output()]),
        category = "jco_transpile",
        identifier = ctx.label.name,
    )

    return [
        DefaultInfo(default_output = out),
        NodePackageInfo(
            lib = ctx.actions.tset(
                NodePackageTSet,
                value = NodePackage(package = package, contents = out),
            ),
        ),
    ]

jco_transpile = rule(
    impl = _jco_transpile_impl,
    attrs = {
        "component": attrs.dep(
            providers = [DefaultInfo],
            doc = "The WebAssembly component to transpile to an ES module.",
        ),
        "module_name": attrs.string(
            default = "component",
            doc = "Base name for the emitted module.",
        ),
        "package_name": attrs.option(
            attrs.string(),
            default = None,
            doc = "Node package name for importing the output. Defaults to the rule name.",
        ),
        "shim_map": attrs.dict(
            key = attrs.string(),
            value = attrs.string(),
            default = _PREVIEW2_SHIM_MAP,
            doc = "Mapping of WASI interfaces to shim packages.",
        ),
        "_jco_transpile": attrs.default_only(
            attrs.exec_dep(
                default = "//wasm/tools:jco-transpile",
                providers = [RunInfo],
            ),
        ),
    },
)
