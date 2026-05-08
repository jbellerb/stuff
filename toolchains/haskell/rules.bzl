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
