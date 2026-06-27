load("@prelude//:rules_impl.bzl", "categorized_extra_attributes")
load("@prelude//cxx:cxx_toolchain_types.bzl", "CxxToolchainInfo")
load("@prelude//decls:haskell_rules.bzl", "haskell_rules")
load("@prelude//haskell:haskell.bzl", "haskell_binary_impl")
load("@prelude//transitions:utils.bzl", "transition_utils")
load("//deno:defs.bzl", "DenoToolchainInfo")
load("//deno:npm.bzl", "NodePackage", "NodePackageInfo", "NodePackageTSet")
load(":defs.bzl", "HaskellGHCDistrInfo", "haskell_ghc_distr_impl")

HaskellGHCWasmDistrInfo = provider(
    fields = {
        "post_linker": provider_field(RunInfo),
    },
)

def _haskell_ghc_wasm_distr_impl(ctx: AnalysisContext) -> list[Provider]:
    providers = haskell_ghc_distr_impl(ctx)

    new_providers = []
    for provider in providers:
        if isinstance(provider, HaskellGHCDistrInfo):
            # GHC adds .wasm to output paths, but buck2 expects the output
            # without the extension. This wrapper calls clang and then renames
            # "<output>.wasm" to "<output>".
            linker_wrapper, _ = ctx.actions.write(
                "ghc-wasm-linker-wrapper.sh",
                cmd_args(
                    cmd_args(provider.compiler, delimiter = " "),
                    format = """#!/usr/bin/env sh
for arg in "$@"
do
    if test "$prev" = "-o"
    then
        output="$arg"
        prev=""
        continue
    fi
    prev="$arg"
done

{} "$@"
status=$?

if test $status -eq 0 && test -n "$output" && test -e "$output.wasm" && test ! -e "$output"
then
    mv "$output.wasm" "$output"
fi

exit "$status"
""",
                ),
                with_inputs = True,
                is_executable = True,
                allow_args = True,
            )

            new_providers.append(
                HaskellGHCDistrInfo(
                    # NOTE: haskell_binary uses compiler instead of linker for
                    # linking static binaries.
                    compiler = RunInfo(linker_wrapper),
                    linker = RunInfo(linker_wrapper),
                    packager = provider.packager,
                    haddock = provider.haddock,
                    version = provider.version,
                ),
            )
        else:
            new_providers.append(provider)

    post_linker = cmd_args([
        ctx.attrs._deno_toolchain[DenoToolchainInfo].deno,
        "run",
        "--no-check",
        "--allow-read",
        "--allow-write",
        ctx.attrs.ghc_root.project("lib/post-link.mjs"),
    ])

    return new_providers + [
        HaskellGHCWasmDistrInfo(post_linker = RunInfo(args = post_linker)),
    ]

haskell_ghc_wasm_distr = rule(
    impl = _haskell_ghc_wasm_distr_impl,
    attrs = {
        "ghc_root": attrs.source(allow_directory = True),
        "cxx_toolchain": attrs.toolchain_dep(providers = [CxxToolchainInfo]),
        "bin_prefix": attrs.string(default = ""),
        "target": attrs.default_only(attrs.string(default = "wasm32-unknown-wasi")),
        "host": attrs.string(),
        "version": attrs.string(),
        "package_manifest": attrs.dict(
            key = attrs.string(),
            value = attrs.any(),
            default = {},
        ),
        "labels": attrs.list(attrs.string(), default = []),
        "_install_ghc": attrs.default_only(
            attrs.exec_dep(
                providers = [RunInfo],
                default = "//haskell/tools:install_ghc",
            ),
        ),
        "_deno_toolchain": attrs.default_only(
            attrs.toolchain_dep(
                default = "toolchains//:deno",
                providers = [DenoToolchainInfo],
            ),
        ),
    },
)

def _wasm_ghc_transition_impl(platform: PlatformInfo, refs: struct) -> PlatformInfo:
    cpu = refs.cpu[ConstraintSettingInfo].label
    os = refs.os[ConstraintSettingInfo].label

    updated_constraints = transition_utils.filtered_platform_constraints(
        platform,
        [cpu, os],
    )
    updated_constraints[cpu] = refs.wasm32[ConstraintValueInfo]
    updated_constraints[os] = refs.wasi[ConstraintValueInfo]

    return PlatformInfo(
        label = "wasm_ghc_transition",
        configuration = ConfigurationInfo(
            constraints = updated_constraints,
            values = platform.configuration.values,
        ),
    )

wasm_ghc_transition = transition(
    impl = _wasm_ghc_transition_impl,
    refs = {
        "cpu": "config//cpu/constraints:cpu",
        "wasm32": "config//cpu/constraints:wasm32",
        "os": "config//os/constraints:os",
        "wasi": "config//os/constraints:wasi",
    },
)

haskell_wasm_binary = rule(
    impl = haskell_binary_impl,
    attrs = (
        haskell_rules.haskell_binary.attrs |
        categorized_extra_attributes["haskell"]["haskell_binary"] |
        {
            "link_style": attrs.string(default = "static"),
            "_cxx_toolchain": attrs.toolchain_dep(
                default = "toolchains//haskell:cxx-wasm32-wasi-sdk",
                providers = [CxxToolchainInfo],
            ),
        }
    ),
    cfg = wasm_ghc_transition,
    doc = """
    A `haskell_wasm_binary()` rule represents a group of Haskell sources and
    deps which build a WebAssembly executable. It applies the WebAssembly
    platform transition automatically, so the binary and its dependencies are
    built for WebAssembly regardless of the target platform.
    """,
)

def _haskell_wasm_exports_impl(ctx: AnalysisContext) -> list[Provider]:
    package_name = ctx.attrs.package_name or ctx.label.name

    output = ctx.actions.declare_output(ctx.label.name, dir = True)

    cmd = cmd_args([
        "sh",
        "-c",
        r"""
package_name=$1
input=$2
output=$3
shift 3

mkdir -p "$output"

"$@" -i "$input" -o "$output/main.js"

cat > "$output/package.json" << EOF
{
  "name": "$package_name",
  "main": "./main.js"
}
EOF
""",
        "--",
        package_name,
        ctx.attrs.binary,
        output.as_output(),
        ctx.attrs._haskell_wasm_distr[HaskellGHCWasmDistrInfo].post_linker,
    ])

    ctx.actions.run(cmd, category = "ghc_wasm_post_linker", identifier = ctx.label.name)

    return [
        DefaultInfo(default_output = output),
        NodePackageInfo(
            lib = ctx.actions.tset(
                NodePackageTSet,
                value = NodePackage(package = package_name, contents = output),
            ),
        ),
    ]

haskell_wasm_exports = rule(
    impl = _haskell_wasm_exports_impl,
    attrs = {
        "package_name": attrs.option(attrs.string(), default = None),
        "binary": attrs.source(),
        "_haskell_wasm_distr": attrs.toolchain_dep(
            default = "toolchains//:haskell[ghc]",
            providers = [HaskellGHCWasmDistrInfo],
        ),
    },
    cfg = wasm_ghc_transition,
    doc = """
    A `haskell_wasm_exports()` rule represents a .wasm binary with embedded
    JSFFI annotations and generates a Node module for running the binary.
    """,
)

def _wasi_sdk_binary_impl(ctx: AnalysisContext) -> list[Provider]:
    return [
        DefaultInfo(),
        RunInfo(args = [ctx.attrs.sdk.project(ctx.attrs.binary)]),
    ]

wasi_sdk_binary = rule(
    impl = _wasi_sdk_binary_impl,
    attrs = {
        "sdk": attrs.source(allow_directory = True),
        "binary": attrs.string(),
    },
)
