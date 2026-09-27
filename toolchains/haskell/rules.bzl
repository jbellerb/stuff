load("@prelude//:rules_impl.bzl", "categorized_extra_attributes")
load("@prelude//cxx:cxx_toolchain_types.bzl", "CxxToolchainInfo")
load("@prelude//decls:haskell_rules.bzl", "haskell_rules")
load(
    "@prelude//haskell:haskell.bzl",
    "haskell_binary_impl",
    "haskell_library_impl",
    prelude_haskell_prebuilt_library_impl = "haskell_prebuilt_library_impl",
)
load(
    "@prelude//haskell:library_info.bzl",
    "HaskellLibraryInfo",
    "HaskellLibraryInfoTSet",
)
load("@prelude//haskell:link_info.bzl", "HaskellLinkInfo")
load("@prelude//linking:link_info.bzl", "LinkStyle")

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
                    id = ctx.attrs.id,
                    import_dirs = ctx.attrs.import_dirs,  # new
                    is_prebuilt = True,
                    libs = libs,
                    profiling_enabled = False,
                    stub_dirs = [],
                    version = ctx.attrs.version,
                )
                prof_hlibinfo = HaskellLibraryInfo(
                    name = ctx.attrs.name,
                    db = ctx.attrs.db,
                    id = ctx.attrs.id,
                    import_dirs = ctx.attrs.import_dirs,  # new
                    is_prebuilt = True,
                    libs = prof_libs,
                    profiling_enabled = True,
                    stub_dirs = [],
                    version = ctx.attrs.version,
                )

                haskell_infos = [dep[HaskellLinkInfo] for dep in ctx.attrs.deps if HaskellLinkInfo in dep]
                new_info[link_style] = ctx.actions.tset(
                    HaskellLibraryInfoTSet,
                    children = [lib.info[link_style] for lib in haskell_infos],
                    value = hlibinfo,
                )
                new_prof_info[link_style] = ctx.actions.tset(
                    HaskellLibraryInfoTSet,
                    children = [lib.prof_info[link_style] for lib in haskell_infos],
                    value = prof_hlibinfo,
                )

            new_providers.append(
                HaskellLinkInfo(
                    info = new_info,
                    prof_info = new_prof_info,
                )
            )
        else:
            # keep other providers unchanged
            new_providers.append(provider)

    return new_providers

haskell_prebuilt_library = rule(
    impl = _haskell_prebuilt_library_impl,
    attrs = haskell_rules.haskell_prebuilt_library.attrs,
)

# `haskell_library` and `haskell_binary` wrap the prelude's rules, but default
# the cxx toolchain to the one GHC was installed with. This keeps linking
# consistent when using a hermetic toolchain (e.g. when building WASM targets).

haskell_library = rule(
    impl = haskell_library_impl,
    attrs = (
        haskell_rules.haskell_library.attrs
        | categorized_extra_attributes["haskell"]["haskell_library"]
        | {
            "_cxx_toolchain": attrs.toolchain_dep(
                default = "toolchains//:haskell",
                providers = [CxxToolchainInfo],
            ),
        }
    ),
)

haskell_binary = rule(
    impl = haskell_binary_impl,
    attrs = (
        haskell_rules.haskell_binary.attrs
        | categorized_extra_attributes["haskell"]["haskell_binary"]
        | {
            "_cxx_toolchain": attrs.toolchain_dep(
                default = "toolchains//:haskell",
                providers = [CxxToolchainInfo],
            ),
        }
    ),
)
