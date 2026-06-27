load("@prelude//cxx:cxx_toolchain_types.bzl", "LinkerType", "PicBehavior")
load("@prelude//cxx:linker.bzl", "LINKERS")
load("@prelude//cxx:preprocessor.bzl", "CPreprocessorInfo")
load(
    "@prelude//haskell:library_info.bzl",
    "HaskellLibraryInfo",
    "HaskellLibraryInfoTSet",
    "HaskellLibraryProvider",
)
load(
    "@prelude//haskell:link_info.bzl",
    "HaskellLinkInfo",
    "HaskellProfLinkInfo",
)
load(
    "@prelude//linking:link_groups.bzl",
    "LinkGroupLibInfo",
    "merge_link_group_lib_info",
)
load(
    "@prelude//linking:link_info.bzl",
    "Archive",
    "ArchiveLinkable",
    "LibOutputStyle",
    "LinkInfo",
    "LinkInfos",
    "LinkStyle",
    "LinkedObject",
    "MergedLinkInfo",
    "SharedLibLinkable",
    "create_merged_link_info",
)
load(
    "@prelude//linking:linkable_graph.bzl",
    "LinkableGraph",
    "LinkableNode",
    "create_linkable_graph",
    "create_linkable_graph_node",
    "create_linkable_node",
)
load("@prelude//linking:shared_libraries.bzl", "SharedLibraryInfo", "create_shared_libraries", "merge_shared_libraries")
load("@prelude//utils:dicts.bzl", "flatten_x")
load("@prelude//utils:expect.bzl", "expects")
load("@prelude//utils:graph_utils.bzl", "post_order_traversal")

_PseudoProviderCollection = dict[str, Provider]

HaskellGHCPackageDBInfo = provider(
    fields = {
        "db": provider_field(Artifact),
        "arch": provider_field(str),
        "os": provider_field(str),
        "version": provider_field(str),
    },
)

# prelude's Haskell providers use the legacy LinkStyle type instead of the
# LinkStrategy and LibOutputStyle. To properly link with cxx dependencies, we
# need to convert it at the edges. Adapted from prelude//haskell:haskell.bzl.
def _to_lib_output_style(link_style: LinkStyle) -> LibOutputStyle:
    if link_style == LinkStyle("static"):
        return LibOutputStyle("archive")
    elif link_style == LinkStyle("static_pic"):
        return LibOutputStyle("pic_archive")
    elif link_style == LinkStyle("shared"):
        return LibOutputStyle("shared_lib")
    else:
        fail("unexpected LinkStyle '{}'".format(link_style.value))

def _to_linker_type(os: str) -> LinkerType:
    if os == "linux" or os == "wasi":
        return LinkerType("gnu")
    elif os == "darwin":
        return LinkerType("darwin")
    else:
        fail("unexpected os '{}'".format(os))

def _build_linkable(output_style: LibOutputStyle, lib: Artifact) -> typing.Any:
    if output_style == LibOutputStyle("shared_lib"):
        return SharedLibLinkable(lib = lib)
    else:
        return ArchiveLinkable(
            archive = Archive(artifact = lib),
            linker_type = LinkerType("gnu"),
        )

def _collect_dep_infos(
        deps: list[_PseudoProviderCollection],
        name: str) -> list[Provider]:
    infos = []
    for dep in deps:
        expects.expect(
            name in dep,
            "Expected {} in boot dependency".format(name),
        )
        infos.append(dep[name])

    return infos

def _collect_boot_library_libs(
        actions: AnalysisActions,
        pkg: dict[str, typing.Any],
        db: Artifact,
        import_dir: Artifact,
        all_libs: dict[LinkStyle, list[Artifact]],
        deps_infos: list[HaskellLinkInfo],
        profiling_enabled: bool) -> typing.Any:
    hlibinfos = {}
    hlinkinfos = {}
    link_infos = {}
    for link_style in LinkStyle:
        libs = all_libs.get(link_style, [])

        hlibinfos[link_style] = HaskellLibraryInfo(
            name = pkg["name"],
            db = db,
            import_dirs = {profiling_enabled: import_dir},
            stub_dirs = [],
            id = pkg["id"],
            libs = libs,
            version = pkg["version"],
            is_prebuilt = True,
            profiling_enabled = profiling_enabled,
        )
        hlinkinfos[link_style] = actions.tset(
            HaskellLibraryInfoTSet,
            value = hlibinfos[link_style],
            children = [
                dep.prof_info[link_style] if profiling_enabled else dep.info[link_style]
                for dep in deps_infos
            ],
        )

        output_style = _to_lib_output_style(link_style)
        link_infos[output_style] = LinkInfos(
            default = LinkInfo(
                linkables = [_build_linkable(output_style, lib) for lib in libs],
            ),
        )

    return hlibinfos, hlinkinfos, link_infos

def _haskell_boot_library(
        ctx: AnalysisContext,
        pkg: dict[str, typing.Any],
        libs: Artifact,
        db: Artifact,
        os: str,
        version: str,
        deps: list[_PseudoProviderCollection]) -> _PseudoProviderCollection:
    import_dir = libs.project(pkg["id"])

    static_lib = import_dir.project("libHS{}.a".format(pkg["id"]))
    static_prof_lib = import_dir.project("libHS{}_p.a".format(pkg["id"]))
    shared_lib = libs.project(
        "libHS{}-ghc{}.{}".format(
            pkg["id"],
            version,
            LINKERS[_to_linker_type(os)].default_shared_library_extension,
        ),
    )

    deps_infos = _collect_dep_infos(deps, "HaskellLinkInfo")
    native_infos = _collect_dep_infos(deps, "MergedLinkInfo")
    prof_native_infos = _collect_dep_infos(deps, "HaskellProfLinkInfo")
    shared_library_infos = _collect_dep_infos(deps, "SharedLibraryInfo")
    link_group_infos = _collect_dep_infos(deps, "LinkGroupLibInfo")

    hlibinfos, hlinkinfos, link_infos = _collect_boot_library_libs(
        ctx.actions,
        pkg,
        db,
        import_dir,
        {LinkStyle("static"): [static_lib], LinkStyle("shared"): [shared_lib]},
        deps_infos,
        False,
    )
    prof_hlibinfos, prof_hlinkinfos, prof_link_infos = _collect_boot_library_libs(
        ctx.actions,
        pkg,
        db,
        import_dir,
        {LinkStyle("static"): [static_prof_lib]},
        deps_infos,
        True,
    )

    shared_libs = create_shared_libraries(ctx, {
        shared_lib.basename: LinkedObject(
            output = shared_lib,
            unstripped_output = shared_lib,
        ),
    })

    return {
        "DefaultInfo": DefaultInfo(),
        "HaskellLibraryProvider": HaskellLibraryProvider(
            lib = hlibinfos,
            prof_lib = prof_hlibinfos,
        ),
        "HaskellLinkInfo": HaskellLinkInfo(
            info = hlinkinfos,
            prof_info = prof_hlinkinfos,
        ),
        "MergedLinkInfo": create_merged_link_info(
            ctx,
            # matching the behavior of prelude//haskell:haskell.bzl
            pic_behavior = PicBehavior("supported"),
            link_infos = link_infos,
            exported_deps = native_infos,
        ),
        "HaskellProfLinkInfo": HaskellProfLinkInfo(
            prof_infos = create_merged_link_info(
                ctx,
                # matching the behavior of prelude//haskell:haskell.bzl
                pic_behavior = PicBehavior("supported"),
                link_infos = prof_link_infos,
                exported_deps = [info.prof_infos for info in prof_native_infos],
            ),
        ),
        "SharedLibraryInfo": merge_shared_libraries(
            ctx.actions,
            shared_libs,
            shared_library_infos,
        ),
        "LinkableGraph": create_linkable_graph(
            ctx,
            node = create_linkable_graph_node(
                ctx,
                linkable_node = create_linkable_node(
                    ctx,
                    exported_deps = [dep["LinkableGraph"] for dep in deps],
                    link_infos = link_infos,
                    shared_libs = shared_libs,
                    default_soname = shared_lib.basename,
                ),
            ),
            deps = [dep["LinkableGraph"] for dep in deps],
        ),
        "LinkGroupLibInfo": merge_link_group_lib_info(children = link_group_infos),
    }

def haskell_boot_package_database(
        ctx: AnalysisContext,
        ghc_root: Artifact,
        os: str,
        version: str,
        manifest: dict) -> dict[str, list[Provider]]:
    lib = ghc_root.project("lib")
    db = lib.project("package.conf.d")
    libs = lib.project(manifest["lib_prefix"])

    pkgs = {pkg["id"]: pkg for pkg in manifest["package"]}
    outputs = {}

    for id in post_order_traversal({id: pkgs[id]["depends"] for id in pkgs}):
        deps = []
        for dep in pkgs[id]["depends"]:
            expects.expect(
                dep in outputs,
                "Expected dependency in existing output providers",
            )
            deps.append(outputs[dep])

        outputs[id] = _haskell_boot_library(ctx, pkgs[id], libs, db, os, version, deps)

    return {pkgs[id]["name"]: outputs[id].values() for id in outputs}
