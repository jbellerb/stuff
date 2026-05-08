load("@prelude//decls:haskell_rules.bzl", "haskell_rules")
load(
    "@prelude//haskell:haskell.bzl",
    prelude_haskell_prebuilt_library_impl = "haskell_prebuilt_library_impl",
)
load(
    "@prelude//haskell:library_info.bzl",
    "HaskellLibraryInfo",
    "HaskellLibraryInfoTSet",
)
load("@prelude//haskell:link_info.bzl", "HaskellLinkInfo")
load(
    "@prelude//haskell:toolchain.bzl",
    "HaskellPlatformInfo",
    "HaskellToolchainInfo",
)
load("@prelude//linking:link_info.bzl", "LinkStyle")

HaskellGHCDistrInfo = provider(
    fields = {
        "compiler": provider_field(RunInfo),
        "linker": provider_field(RunInfo),
        "packager": provider_field(RunInfo),
        "haddock": provider_field(RunInfo),
        "version": provider_field(str),
    },
)

# adapted from prelude//haskell:haskell.bzl
def _get_haskell_prebuilt_libs(ctx: AnalysisContext, link_style: LinkStyle):
    if link_style == LinkStyle("shared"):
        # profiling doesn't support shared libraries
        return ctx.attrs.shared_libs.values(), []
    elif link_style == LinkStyle("static"):
        return ctx.attrs.static_libs, ctx.attrs.profiled_static_libs
    elif link_style == LinkStyle("static_pic"):
        return ctx.attrs.pic_static_libs, ctx.attrs.pic_profiled_static_libs
    else:
        fail("unexpected LinkStyle '{}'".format(link_style.value))

# wraps the prelude's prebuilt library rule, but assigns import_dirs to properly
# materialize .hi files
def _haskell_prebuilt_library_impl(ctx: AnalysisContext) -> list[Provider]:
    providers = prelude_haskell_prebuilt_library_impl(ctx)
    if not ctx.attrs.import_dirs:
        return providers

    new_providers = []
    for provider in providers:
        if type(provider) == HaskellLinkInfo:
            new_info = {}
            new_prof_info = {}
            for link_style in LinkStyle:
                libs, prof_libs = _get_haskell_prebuilt_libs(ctx, link_style)
                hlibinfo = HaskellLibraryInfo(
                    name = ctx.attrs.name,
                    db = ctx.attrs.db,
                    import_dirs = ctx.attrs.import_dirs,  # new
                    stub_dirs = [],
                    id = ctx.attrs.id,
                    libs = libs,
                    version = ctx.attrs.version,
                    is_prebuilt = True,
                    profiling_enabled = False,
                )
                prof_hlibinfo = HaskellLibraryInfo(
                    name = ctx.attrs.name,
                    db = ctx.attrs.db,
                    import_dirs = ctx.attrs.import_dirs,  # new
                    stub_dirs = [],
                    id = ctx.attrs.id,
                    libs = prof_libs,
                    version = ctx.attrs.version,
                    is_prebuilt = True,
                    profiling_enabled = True,
                )

                haskell_infos = [
                    dep[HaskellLinkInfo]
                    for dep in ctx.attrs.deps
                    if HaskellLinkInfo in dep
                ]
                new_info[link_style] = ctx.actions.tset(
                    HaskellLibraryInfoTSet,
                    value = hlibinfo,
                    children = [lib.info[link_style] for lib in haskell_infos],
                )
                new_prof_info[link_style] = ctx.actions.tset(
                    HaskellLibraryInfoTSet,
                    value = prof_hlibinfo,
                    children = [lib.prof_info[link_style] for lib in haskell_infos],
                )

            new_providers.append(HaskellLinkInfo(
                info = new_info,
                prof_info = new_prof_info,
            ))
        else:
            # keep other providers unchanged
            new_providers.append(provider)

    return new_providers

haskell_prebuilt_library = rule(
    impl = _haskell_prebuilt_library_impl,
    attrs = haskell_rules.haskell_prebuilt_library.attrs,
)

def _haskell_ghc_distr_impl(ctx: AnalysisContext) -> list[Provider]:
    def ghc_bin(name: str) -> RunInfo:
        return RunInfo(
            ctx.attrs.ghc_root.project(
                "bin/{}{}-{}".format(ctx.attrs.bin_prefix, name, ctx.attrs.version),
            ),
        )

    return [
        DefaultInfo(),
        HaskellGHCDistrInfo(
            compiler = ghc_bin("ghc"),
            linker = ghc_bin("ghc"),
            packager = ghc_bin("ghc-pkg"),
            haddock = ghc_bin("haddock-ghc"),
            version = ctx.attrs.version,
        ),
    ]

haskell_ghc_distr = rule(
    impl = _haskell_ghc_distr_impl,
    attrs = {
        "ghc_root": attrs.source(allow_directory = True),
        "bin_prefix": attrs.string(default = ""),
        "version": attrs.string(),
    },
)

def _haskell_ghc_wasm_distr_impl(ctx: AnalysisContext) -> list[Provider]:
    distr_info = _haskell_ghc_distr_impl(ctx)[1]

    wasi_sdk = ctx.attrs.wasi_sdk
    libffi = ctx.attrs.libffi

    # GHC adds .wasm to output paths (in the @response file it passes to pgml),
    # but buck2 expects the output without the extension. This wrapper calls
    # clang and then renames <output>.wasm to <output>.
    linker_wrapper, _ = ctx.actions.write(
        "ghc-wasm-linker.sh",
        cmd_args(
            wasi_sdk.project("bin/wasm32-wasi-clang"),
            format = """#!/bin/sh
output_wasm=""
prev=""
for arg in "$@"
do
    case "$arg" in
    @*)
        rspfile="${arg#@}"
        while IFS= read -r line
        do
            clean="${line#\\"}"
            clean="${clean%\\"}"
            if test "$prev" = "-o"
            then
                output_wasm="$clean"
            fi
            prev="$clean"
        done < "$rspfile"
        ;;
    *)
        if test "$prev" = "-o"
        then
            output_wasm="$arg"
        fi
        prev="$arg"
        ;;
    esac
done

"{}" "$@"
status=$?

if test $status -eq 0 && test -n "$output_wasm"
then
    output="${output_wasm%.wasm}"
    if test "$output" != "$output_wasm" && test -e "$output_wasm" && test ! -e "$output"
    then
        mv "$output_wasm" "$output"
    fi
fi

exit "$status"
""",
        ),
        is_executable = True,
        allow_args = True,
    )

    ghc = RunInfo(
        cmd_args([
            distr_info.compiler.args,
            cmd_args(libffi.project("include"), format = "-I{}"),
            cmd_args(libffi.project("lib"), format = "-optl-L{}"),
            "-pgma",
            wasi_sdk.project("bin/wasm32-wasi-clang"),
            "-pgmlas",
            wasi_sdk.project("bin/wasm32-wasi-clang"),
            "-pgmc",
            wasi_sdk.project("bin/wasm32-wasi-clang"),
            "-pgmcxx",
            wasi_sdk.project("bin/wasm32-wasi-clang++"),
            "-pgmP",
            wasi_sdk.project("bin/wasm32-wasi-clang"),
            # "-pgmJSP",
            # wasi_sdk.project("bin/wasm32-wasi-clang"),
            # "-pgmCmmP",
            # wasi_sdk.project("bin/wasm32-wasi-clang"),
            "-pgml",
            linker_wrapper,
            "-pgmlm",
            wasi_sdk.project("bin/wasm-ld"),
            "-pgmar",
            wasi_sdk.project("bin/llvm-ar"),
        ]),
    )

    return [
        DefaultInfo(),
        HaskellGHCDistrInfo(
            compiler = ghc,
            linker = ghc,
            packager = distr_info.packager,
            haddock = distr_info.haddock,
            version = distr_info.version,
        ),
    ]

haskell_ghc_wasm_distr = rule(
    impl = _haskell_ghc_wasm_distr_impl,
    attrs = {
        "ghc_root": attrs.source(allow_directory = True),
        "wasi_sdk": attrs.source(allow_directory = True),
        "libffi": attrs.source(allow_directory = True),
        "bin_prefix": attrs.string(default = ""),
        "version": attrs.string(),
    },
)

def _haskell_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    ghc_distr = ctx.attrs.ghc_distr[HaskellGHCDistrInfo]

    return [
        DefaultInfo(),
        ghc_distr,
        HaskellToolchainInfo(
            compiler = ghc_distr.compiler,
            compiler_flags = ctx.attrs.compiler_flags,
            linker = ghc_distr.linker,
            linker_flags = ctx.attrs.linker_flags,
            packager = ghc_distr.packager,
            haddock = ghc_distr.haddock,
        ),
        HaskellPlatformInfo(
            # TODO: what is HaskellPlatformInfo even used for?
            name = host_info().arch,
        ),
    ]

haskell_toolchain = rule(
    impl = _haskell_toolchain_impl,
    attrs = {
        "ghc_distr": attrs.exec_dep(providers = [HaskellGHCDistrInfo]),
        "compiler_flags": attrs.list(attrs.arg(), default = []),
        "linker_flags": attrs.list(attrs.arg(), default = []),
    },
    is_toolchain_rule = True,
)
