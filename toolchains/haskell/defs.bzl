load("@prelude//cxx:cxx_toolchain_types.bzl", "CxxToolchainInfo")
load(
    "@prelude//haskell:toolchain.bzl",
    "HaskellPlatformInfo",
    "HaskellToolchainInfo",
)
load(
    "//haskell/lib/package_db.bzl",
    "HaskellGHCPackageDBInfo",
    "haskell_boot_package_database",
)

_DEFAULT_TRIPLE = select({
    "prelude//os:linux": select({
        "prelude//cpu:x86_64": "x86_64-ubuntu20_04-linux",
    }),
    "prelude//os:macos": select({
        "prelude//cpu:arm64": "aarch64-apple-darwin",
    }),
})

HaskellGHCDistrInfo = provider(
    fields = {
        "compiler": provider_field(RunInfo),
        "linker": provider_field(RunInfo),
        "packager": provider_field(RunInfo),
        "haddock": provider_field(RunInfo),
        "version": provider_field(str),
    },
)

def haskell_ghc_distr_impl(ctx: AnalysisContext) -> list[Provider]:
    cxx_toolchain = ctx.attrs.cxx_toolchain[CxxToolchainInfo]

    topdir = ctx.actions.declare_output(ctx.label.name, dir = True)
    bin = topdir.project("bin")
    lib = topdir.project("lib")

    install = cmd_args([
        ctx.attrs._install_ghc[RunInfo].args,
        cmd_args(ctx.attrs.ghc_root, format = "--bindist={}"),
        cmd_args(topdir.as_output(), format = "--out={}"),
        cmd_args(cxx_toolchain.c_compiler_info.compiler, format = "--cc={}"),
        cmd_args(cxx_toolchain.cxx_compiler_info.compiler, format = "--cxx={}"),
        cmd_args(cxx_toolchain.linker_info.linker, format = "--ld={}"),
        cmd_args(cxx_toolchain.linker_info.archiver, format = "--ar={}"),
        cmd_args(cxx_toolchain.binary_utilities_info.nm, format = "--nm={}"),
        cmd_args(cxx_toolchain.binary_utilities_info.ranlib, format = "--ranlib={}"),
        cmd_args(
            cmd_args(
                cxx_toolchain.c_compiler_info.compiler_flags or [],
                delimiter = " ",
            ),
            format = "--cflags={}",
        ),
        cmd_args(
            cmd_args(
                cxx_toolchain.cxx_compiler_info.compiler_flags or [],
                delimiter = " ",
            ),
            format = "--cxxflags={}",
        ),
        cmd_args(
            cmd_args(cxx_toolchain.linker_info.linker_flags or [], delimiter = " "),
            format = "--linkflags={}",
        ),
        "--bin-prefix={}".format(ctx.attrs.bin_prefix),
        "--host-triple={}".format(ctx.attrs.host),
        "--target-triple={}".format(ctx.attrs.target),
    ])

    ctx.actions.run(
        install,
        category = "configure_ghc",
        identifier = ctx.label.name,
    )

    def ghc_bin(name: str) -> RunInfo:
        return RunInfo(
            bin.project(
                "{}{}-{}".format(ctx.attrs.bin_prefix, name, ctx.attrs.version),
            ),
        )

    ghc = cmd_args([
        ghc_bin("ghc"),
        cmd_args(lib, format = "-B{}"),
        "-no-user-package-db",
    ])

    arch, _, tail = ctx.attrs.target.partition("-")
    _, _, os = tail.rpartition("-")

    return [
        DefaultInfo(
            sub_targets = haskell_boot_package_database(
                ctx,
                ctx.attrs.ghc_root,
                os,
                ctx.attrs.version,
                ctx.attrs.package_manifest,
            ),
        ),
        HaskellGHCDistrInfo(
            compiler = RunInfo(ghc),
            linker = RunInfo(ghc),
            packager = ghc_bin("ghc-pkg"),
            haddock = ghc_bin("haddock-ghc"),
            version = ctx.attrs.version,
        ),
        HaskellGHCPackageDBInfo(
            db = lib.project("package.conf.d"),
            arch = arch,
            os = os,
            version = ctx.attrs.version,
        ),
    ]

haskell_ghc_distr = rule(
    impl = haskell_ghc_distr_impl,
    attrs = {
        "ghc_root": attrs.source(allow_directory = True),
        "cxx_toolchain": attrs.toolchain_dep(
            providers = [CxxToolchainInfo],
            default = "toolchains//:cxx",
        ),
        "bin_prefix": attrs.string(default = ""),
        "target": attrs.string(),
        "host": attrs.string(default = _DEFAULT_TRIPLE),
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

def _exec_alias_impl(ctx):
    return ctx.attrs.actual.providers

exec_alias = rule(
    impl = _exec_alias_impl,
    attrs = {
        "actual": attrs.exec_dep(),
    },
)
