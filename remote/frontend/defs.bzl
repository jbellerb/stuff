load("@toolchains//deno:node.bzl", "NodePackageInfo", "NodePackageTSet")
load(
    "@toolchains//typescript:rules.bzl",
    "TypeScriptLibTSet",
    "TypeScriptLibraryInfo",
    "TypeScriptModule",
    "TypeScriptModuleTSet",
)

def _css_stylesheet_impl(ctx: AnalysisContext) -> list[Provider]:
    lightningcss = ctx.attrs._lightningcss[DefaultInfo].default_outputs[0]

    output = ctx.actions.declare_output(ctx.label.name, dir = True)

    cmd = cmd_args([
        "sh",
        "-c",
        r"""
lightningcss=$1
entry=$2
output=$3

mkdir -p "$output"

"$lightningcss" --bundle --minify "$entry" \
    --output-file="$BUCK_SCRATCH_PATH/main.css"

cat > "$output/index.js" << EOF
const rules = "$(sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' "$BUCK_SCRATCH_PATH/main.css")";
const stylesheet = new CSSStyleSheet();
stylesheet.replaceSync(rules);
export default stylesheet;
EOF

cat > "$output/index.d.ts" << EOF
declare const stylesheet: CSSStyleSheet;
export default stylesheet;
EOF
""",
        "--",
        lightningcss,
        cmd_args(
            [ctx.attrs.package[DefaultInfo].default_outputs[0], ctx.attrs.path],
            delimiter = "/",
        ),
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
        "_lightningcss": attrs.default_only(
            attrs.exec_dep(
                default = "toolchains//css:lightningcss",
                providers = [RunInfo],
            ),
        ),
    },
)
