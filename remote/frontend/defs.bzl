load("@toolchains//deno:node.bzl", "NodePackageInfo", "NodePackageTSet")
load(
    "@toolchains//typescript:rules.bzl",
    "TypeScriptLibTSet",
    "TypeScriptLibraryInfo",
    "TypeScriptModule",
    "TypeScriptModuleTSet",
)

def _css_stylesheet_impl(ctx: AnalysisContext) -> list[Provider]:
    esbuild = ctx.attrs._esbuild[DefaultInfo].default_outputs[0]

    package = ctx.attrs.package[NodePackageInfo].lib
    node_modules = ctx.actions.declare_output("node_modules", dir = True)
    ctx.actions.symlinked_dir(
        node_modules.as_output(),
        {dep.package: dep.contents for dep in package.traverse()},
    )

    output = ctx.actions.declare_output(ctx.label.name, dir = True)

    cmd = cmd_args([
        "sh",
        "-c",
        r"""
esbuild=$1
entry=$2
node_modules=$3
output=$4

mkdir -p "$output"

NODE_PATH="$PWD/$node_modules" "$esbuild" "$entry" --bundle --minify \
    --outfile="$BUCK_SCRATCH_PATH/main.css"

cat > "$BUCK_SCRATCH_PATH/stub.js" << EOF
import rules from "./main.css";
const stylesheet = new CSSStyleSheet();
stylesheet.replaceSync(rules);
export default stylesheet;
EOF

"$esbuild" "$BUCK_SCRATCH_PATH/stub.js" --bundle --format=esm \
    --loader:.css=text --outfile="$output/index.js"

cat > "$output/index.d.ts" << EOF
declare const stylesheet: CSSStyleSheet;
export default stylesheet;
EOF
""",
        "--",
        esbuild,
        cmd_args(
            [ctx.attrs.package[DefaultInfo].default_outputs[0], ctx.attrs.path],
            delimiter = "/",
        ),
        node_modules,
        output.as_output(),
    ])

    ctx.actions.run(cmd, category = "bundle", identifier = ctx.label.name)

    return [
        DefaultInfo(default_output = output),
        TypeScriptLibraryInfo(
            transpiled = ctx.actions.tset(
                TypeScriptModuleTSet,
                value = TypeScriptModule(
                    specifier = "{}//{}:{}".format(
                        ctx.label.cell,
                        ctx.label.package,
                        ctx.label.name,
                    ),
                    main = "index",
                    transpiled = output,
                ),
            ),
            lib = ctx.actions.tset(TypeScriptLibTSet, value = ["dom"]),
            packages = ctx.actions.tset(NodePackageTSet),
        ),
    ]

css_stylesheet = rule(
    impl = _css_stylesheet_impl,
    attrs = {
        "package": attrs.dep(
            providers = [NodePackageInfo],
            doc = "The npm package containing the stylesheet.",
        ),
        "path": attrs.string(
            doc = "Path of the stylesheet within the package.",
        ),
        "_esbuild": attrs.default_only(
            attrs.exec_dep(
                default = "toolchains//esbuild:binary",
                providers = [RunInfo],
            ),
        ),
    },
)
