load("@prelude//cxx:cxx_toolchain_types.bzl", "CxxToolchainInfo", "PicBehavior")
load("@prelude//cxx:linker.bzl", "LINKERS")
load("@prelude//decls:common.bzl", "buck")
load("@prelude//decls:haskell_common.bzl", "haskell_common")
load("@prelude//decls:native_common.bzl", "native_common")
load("@prelude//decls:toolchains_common.bzl", "toolchains_common")
load("@prelude//haskell:compile.bzl", "get_packages_info")
load(
    "@prelude//haskell:library_info.bzl",
    "HaskellLibraryInfo",
    "HaskellLibraryInfoTSet",
    "HaskellLibraryProvider",
)
load("@prelude//haskell:link_info.bzl", "HaskellLinkInfo", "HaskellProfLinkInfo")
load("@prelude//haskell:toolchain.bzl", "HaskellToolchainInfo")
load(
    "@prelude//haskell:util.bzl",
    "attr_deps_haskell_link_infos_sans_template_deps",
    "attr_deps_merged_link_infos",
    "attr_deps_profiling_link_infos",
    "attr_deps_shared_library_infos",
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
    "get_lib_output_style",
    "get_output_styles_for_linkage",
    "legacy_output_style_to_link_style",
    "to_link_strategy",
)
load(
    "@prelude//linking:linkable_graph.bzl",
    "create_linkable_graph",
    "create_linkable_graph_node",
    "create_linkable_node",
)
load(
    "@prelude//linking:shared_libraries.bzl",
    "SharedLibrariesTSet",
    "create_shared_libraries",
    "merge_shared_libraries",
)
load("@prelude//linking:types.bzl", "Linkage")
load("//haskell/defs.bzl", "ghc_wrapper")
load("//haskell/lib/pkgs.bzl", "BOOT_MANIFESTS")

def _compile_setup_impl(ctx: AnalysisContext) -> list[Provider]:
    toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    link_style = LinkStyle(ctx.attrs.link_style)
    hlis = attr_deps_haskell_link_infos_sans_template_deps(ctx)

    setup_bin = ctx.actions.declare_output("setup")
    cmd = cmd_args([
        toolchain.compiler,
        "-package-env=-",
        "--make",
        "-fbuilding-cabal-package",  # this only changes error message wording?
        "-i",
        "-hide-all-packages",
        "-no-user-package-db",
        # TODO: add threading support to prebuilt boot libs
        # "-threaded",
    ])

    packages_info = get_packages_info(
        ctx,
        link_style,
        specify_pkg_version = False,
        enable_profiling = False,
    )
    cmd.add(packages_info.exposed_package_args)
    cmd.add(packages_info.packagedb_args)

    cmd.add(ctx.attrs.setup_src)
    cmd.add("-o", setup_bin.as_output())

    ctx.actions.run(
        cmd,
        category = "haskell_compile_setup",
        identifier = ctx.attrs.setup_src.short_path,
    )

    return [DefaultInfo(default_output = setup_bin)]

_compile_setup = anon_rule(
    impl = _compile_setup_impl,
    attrs = {
        "setup_src": attrs.source(),
        "deps": attrs.list(attrs.dep(), default = []),
        "link_style": attrs.enum(LinkStyle.values()),
        "template_deps": attrs.default_only(
            attrs.list(attrs.exec_dep(providers = [HaskellLibraryProvider]), default = []),
        ),
        # anon_rule doesn't support toolchain_dep or exec_dep with platform
        # resolution
        "_haskell_toolchain": attrs.dep(providers = [HaskellToolchainInfo]),
    },
    artifact_promise_mappings = {
        "setup": lambda x: x[DefaultInfo].default_outputs[0],
    },
)

def _extract_dep_package_names(ctx: AnalysisContext, output_style: LibOutputStyle) -> list[str]:
    hlis = attr_deps_haskell_link_infos_sans_template_deps(ctx)
    link_style = legacy_output_style_to_link_style(output_style)
    return [li.info[link_style].value.name for li in hlis]

def _generate_cabal_file(
        ctx: AnalysisContext,
        package_name: str,
        build_type: str,
        output_style: LibOutputStyle) -> Artifact:
    def _cabal_identifier_list(name: str, args) -> cmd_args:
        return cmd_args([
            "{}:".format(name),
            cmd_args(args, delimiter = ", "),
        ], delimiter = " ")

    cabal = cmd_args([
        "cabal-version: 3.0",
        "name: {}".format(package_name),
        "version: {}".format(ctx.attrs.version),
        "build-type: {}".format(build_type),
        "custom-setup: {}".format(ctx.attrs.custom_setup).rstrip(),
        "library",
        cmd_args([
            cmd_args([
                "ghc-options:",
                [ctx.attrs.compiler_flags or []],
            ], delimiter = " "),
            _cabal_identifier_list(
                "exposed-modules",
                ctx.attrs.exposed_modules or [],
            ),
            _cabal_identifier_list(
                "reexported-modules",
                ctx.attrs.reexported_modules or [],
            ),
            _cabal_identifier_list(
                "other-modules",
                ctx.attrs.other_modules or [],
            ),
            _cabal_identifier_list(
                "hs-source-dirs",
                [
                    (ctx.attrs.src if dir == "." else ctx.attrs.src.project(dir))
                    for dir in ctx.attrs.hs_source_dirs or ["."]
                ],
            ),
            cmd_args([
                "default-language:",
                ctx.attrs.default_language,
            ], delimiter = " "),
            _cabal_identifier_list(
                "default-extensions",
                ctx.attrs.default_extensions or [],
            ),
            _cabal_identifier_list(
                "build-depends",
                _extract_dep_package_names(ctx, output_style),
            ),
            _cabal_identifier_list(
                "c-sources",
                [ctx.attrs.src.project(src) for src in ctx.attrs.c_sources or []],
            ),
            _cabal_identifier_list(
                "include-dirs",
                [
                    (ctx.attrs.src if dir == "." else ctx.attrs.src.project(dir))
                    for dir in ctx.attrs.include_dirs or []
                ],
            ),
            _cabal_identifier_list(
                "cc-options",
                ctx.attrs.cc_options or [],
            ),
            _cabal_identifier_list(
                "cpp-options",
                ctx.attrs.cpp_options or [],
            ),
            _cabal_identifier_list(
                "ld-options",
                ctx.attrs.ld_options or [],
            ),
            _cabal_identifier_list(
                "extra-libraries",
                ctx.attrs.extra_libraries or [],
            ),
        ], format = "    {}"),
        "",
    ], delimiter = "\n")

    return ctx.actions.write(
        "{}.cabal".format(package_name),
        cabal,
        with_inputs = True,
    )

def _cabal_library_impl(ctx: AnalysisContext) -> list[Provider]:
    toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    cxx_toolchain = ctx.attrs._cxx_toolchain[CxxToolchainInfo]
    linker_info = cxx_toolchain.linker_info

    package_name = ctx.attrs.package or ctx.label.name
    build_type = ctx.attrs.build_type or ("Custom" if ctx.attrs.custom_setup else "Simple")

    if build_type == "Simple" or build_type == "Configure":
        setup_src = ctx.attrs._setup_templates.project("Setup_Simple.hs")
    elif build_type == "Custom":
        if ctx.attrs.custom_setup:
            setup_src = ctx.attrs.custom_setup
        else:
            setup_src = ctx.attrs.src.project("Setup.hs")
    else:
        fail("unrecognized build-type '{}'".format(build_type))
    setup_deps = ctx.attrs.setup_deps or ctx.attrs._default_setup_deps

    ghc_wrapper = ctx.actions.anon_target(
        ghc_wrapper,
        {"_haskell_toolchain": ctx.attrs._haskell_toolchain},
    ).artifact("wrapper")

    setup = ctx.actions.anon_target(
        _compile_setup,
        {
            "setup_src": setup_src,
            "deps": setup_deps,
            # NOTE: Setup.hs is always statically linked
            "link_style": "static",
            "_haskell_toolchain": ctx.attrs._haskell_toolchain,
        },
    ).artifact("setup")

    cabal_file = _generate_cabal_file(
        ctx,
        package_name,
        build_type,
        # TODO: is it safe to assume deps don't change between output styles?
        LibOutputStyle("archive"),
    )

    hlis = attr_deps_haskell_link_infos_sans_template_deps(ctx)

    lib_infos = {}
    link_infos = {}
    link_info_tsets = {}
    prof_lib_infos = {}
    prof_link_info_tsets = {}
    prof_link_infos = {}
    solibs = {}

    preferred_linkage = Linkage(ctx.attrs.preferred_linkage)

    for output_style in get_output_styles_for_linkage(preferred_linkage):
        link_style = legacy_output_style_to_link_style(output_style)
        identifier = "{}-{}".format(package_name, output_style.value)

        build_dir = ctx.actions.declare_output(
            "build-{}".format(output_style.value),
            dir = True,
        )
        pkg_conf = ctx.actions.declare_output(
            "pkg-{}.conf".format(output_style.value),
        )
        package_db = ctx.actions.declare_output(
            "package.conf.d-{}".format(output_style.value),
            dir = True,
        )

        # Use a deterministic package ID so we know the library filename
        pkg_id = "{}-{}".format(package_name, ctx.attrs.version)

        build_profiling = output_style == LibOutputStyle("archive")

        cmd_configure = cmd_args([
            setup,
            "configure",
            cmd_args(cabal_file, format = "--cabal-file={}"),
            "--builddir=\"$1\"",
            "--ghc",
            "--ipid={}".format(pkg_id),
        ])

        if output_style == LibOutputStyle("shared_lib"):
            cmd_configure.add("--enable-shared")
            cmd_configure.add("--disable-library-vanilla")
        elif output_style == LibOutputStyle("archive"):
            cmd_configure.add("--disable-shared")
            cmd_configure.add("--enable-library-vanilla")
        elif output_style == LibOutputStyle("pic_archive"):
            cmd_configure.add("--disable-shared")
            cmd_configure.add("--enable-library-vanilla")
            cmd_configure.add("--ghc-option=-fPIC")

        if build_profiling:
            cmd_configure.add("--enable-library-profiling")
        else:
            cmd_configure.add("--disable-library-profiling")
        cmd_configure.add("--enable-optimization")
        cmd_configure.add("--exact-configuration")
        cmd_configure.add("--package-db=clear")

        transitive_deps = ctx.actions.tset(
            HaskellLibraryInfoTSet,
            children = [li.info[link_style] for li in hlis],
        )
        for lib_info in transitive_deps.traverse():
            cmd_configure.add([
                cmd_args(lib_info.db, format = "--package-db={}"),
                "--dependency={}={}".format(lib_info.name, lib_info.id),
            ])

        if output_style == LibOutputStyle("shared_lib"):
            shared_lib_infos = attr_deps_shared_library_infos(ctx)
            combined_libs = ctx.actions.tset(
                SharedLibrariesTSet,
                children = [info.set for info in shared_lib_infos if info.set],
            )
            for libs in combined_libs.traverse():
                for shlib in libs.libraries:
                    cmd_configure.add(cmd_args(
                        shlib.lib.output,
                        format = "--ghc-option=-optl-L{}",
                        parent = 1,  # get parent directory
                    ))

        cmd_configure.add([
            cmd_args(ghc_wrapper, format = "--with-ghc={}"),
            cmd_args(toolchain.packager, format = "--with-ghc-pkg={}"),
        ])

        cmd_build = cmd_args([setup, "build", "--builddir=\"$1\""])

        cmd_gen_pkg = cmd_args([
            setup,
            "register",
            "--builddir=\"$1\"",
            # without --inplace, Cabal generates the package description as
            # it would appear after `install` to the (unset, so system default)
            # --prefix, i.e. pointing at /usr/local/lib/...
            "--inplace",
            cmd_args(pkg_conf.as_output(), format = "--gen-pkg-config={}"),
        ])

        ctx.actions.run(
            cmd_args([
                "sh",
                "-c",
                cmd_args([
                    cmd_configure,
                    "&&",
                    cmd_build,
                    "&&",
                    cmd_gen_pkg,
                ], delimiter = " "),
                "--",
                build_dir.as_output(),
            ]),
            category = "cabal_build",
            identifier = identifier,
        )

        cmd_db_init = cmd_args([toolchain.packager, "init", "\"$1\""])

        cmd_register = cmd_args([toolchain.packager, "register"])

        for lib_info in transitive_deps.traverse():
            cmd_register.add(cmd_args(lib_info.db, format = "--package-db={}"))

        cmd_register.add([
            "--package-db=\"$1\"",
            "--no-expand-pkgroot",
            pkg_conf,
        ])

        ctx.actions.run(
            cmd_args([
                "sh",
                "-c",
                cmd_args([cmd_db_init, "&&", cmd_register], delimiter = " "),
                "--",
                package_db.as_output(),
            ]),
            category = "haskell_package_db",
            identifier = identifier,
        )

        # extract library artifact from Cabal's build output
        # TODO: isolate .hi files from binaries
        import_dir = build_dir.project("build")
        if output_style == LibOutputStyle("shared_lib"):
            lib_name = "libHS{}-{}-ghc{}.{}".format(
                package_name,
                ctx.attrs.version,
                toolchain.compiler_major_version,
                LINKERS[linker_info.type].default_shared_library_extension,
            )
        else:
            lib_name = "libHS{}-{}.a".format(package_name, ctx.attrs.version)
        lib = build_dir.project("build/{}".format(lib_name))

        # roughly copying _build_haskell_lib in prelude//haskell:haskell.bzl
        if output_style == LibOutputStyle("shared_lib"):
            solibs[lib_name] = LinkedObject(output = lib, unstripped_output = lib)
            linkable = SharedLibLinkable(
                lib = lib,
                link_without_soname = False,
            )
        else:
            linkable = ArchiveLinkable(
                archive = Archive(artifact = lib),
                linker_type = linker_info.type,
                link_whole = False,
            )

        lib_infos[link_style] = HaskellLibraryInfo(
            name = package_name,
            db = package_db,
            id = "{}-{}".format(package_name, ctx.attrs.version),
            import_dirs = {False: import_dir},
            stub_dirs = [],
            libs = [lib],
            version = ctx.attrs.version,
            is_prebuilt = False,
            profiling_enabled = False,
        )

        link_info_tsets[link_style] = ctx.actions.tset(
            HaskellLibraryInfoTSet,
            value = lib_infos[link_style],
            children = [li.info[link_style] for li in hlis],
        )

        link_infos[output_style] = LinkInfos(
            default = LinkInfo(
                name = package_name,
                linkables = [linkable],
            ),
        )

        if build_profiling:
            prof_lib_name = "libHS{}-{}_p.a".format(package_name, ctx.attrs.version)
            prof_lib = build_dir.project("build/{}".format(prof_lib_name))

            prof_lib_infos[link_style] = HaskellLibraryInfo(
                name = package_name,
                db = package_db,
                id = "{}-{}".format(package_name, ctx.attrs.version),
                import_dirs = {True: import_dir},
                stub_dirs = [],
                libs = [prof_lib],
                version = ctx.attrs.version,
                is_prebuilt = False,
                profiling_enabled = True,
            )

            prof_link_info_tsets[link_style] = ctx.actions.tset(
                HaskellLibraryInfoTSet,
                value = prof_lib_infos[link_style],
                children = [li.prof_info[link_style] for li in hlis],
            )

            prof_link_infos[output_style] = LinkInfos(
                default = LinkInfo(
                    name = package_name,
                    linkables = [
                        ArchiveLinkable(
                            archive = Archive(artifact = prof_lib),
                            linker_type = linker_info.type,
                            link_whole = False,
                        ),
                    ],
                ),
            )

    # LinkStyles that don't get a real profiled build (static_pic, shared) still
    # need a `prof_info`/`prof_lib` entry, or any consumer that's built with
    # `enable_profiling = True` will hit a missing-key error. Fill those in as
    # empty.
    for output_style in get_output_styles_for_linkage(preferred_linkage):
        link_style = legacy_output_style_to_link_style(output_style)
        if link_style in prof_lib_infos:
            continue

        prof_lib_infos[link_style] = HaskellLibraryInfo(
            name = package_name,
            db = lib_infos[link_style].db,
            id = lib_infos[link_style].id,
            import_dirs = {},
            stub_dirs = [],
            libs = [],
            version = ctx.attrs.version,
            is_prebuilt = False,
            profiling_enabled = True,
        )

        prof_link_info_tsets[link_style] = ctx.actions.tset(
            HaskellLibraryInfoTSet,
            value = prof_lib_infos[link_style],
            children = [li.prof_info[link_style] for li in hlis],
        )

        prof_link_infos[output_style] = LinkInfos(
            default = LinkInfo(name = package_name, linkables = []),
        )

    # create linkable graph for C++ linker
    shared_libs = create_shared_libraries(ctx, solibs)
    linkable_graph = create_linkable_graph(
        ctx,
        node = create_linkable_graph_node(
            ctx,
            linkable_node = create_linkable_node(
                ctx = ctx,
                preferred_linkage = preferred_linkage,
                exported_deps = ctx.attrs.deps,
                link_infos = link_infos,
                shared_libs = shared_libs,
                default_soname = None,
            ),
        ),
        deps = ctx.attrs.deps,
    )

    output_style = get_lib_output_style(
        to_link_strategy(linker_info.link_style),
        preferred_linkage,
        cxx_toolchain.pic_behavior,
    )
    default_info = lib_infos[legacy_output_style_to_link_style(output_style)]

    return [
        DefaultInfo(default_outputs = default_info.libs),
        HaskellLibraryProvider(
            lib = lib_infos,
            prof_lib = prof_lib_infos,
        ),
        HaskellLinkInfo(
            info = link_info_tsets,
            prof_info = prof_link_info_tsets,
        ),
        create_merged_link_info(
            ctx,
            pic_behavior = PicBehavior("supported"),
            link_infos = link_infos,
            exported_deps = attr_deps_merged_link_infos(ctx),
        ),
        HaskellProfLinkInfo(
            prof_infos = create_merged_link_info(
                ctx,
                pic_behavior = PicBehavior("supported"),
                link_infos = prof_link_infos,
                exported_deps = attr_deps_profiling_link_infos(ctx),
            ),
        ),
        linkable_graph,
        merge_shared_libraries(
            ctx.actions,
            shared_libs,
            attr_deps_shared_library_infos(ctx),
        ),
    ]

cabal_library = rule(
    impl = _cabal_library_impl,
    attrs = (
        haskell_common.compiler_flags_arg() |
        haskell_common.deps_arg() |
        native_common.preferred_linkage(
            preferred_linkage_type = attrs.enum(
                Linkage.values(),
                default = "any",
            ),
        ) |
        {
            "package": attrs.option(attrs.string(), default = None),
            "version": attrs.string(),
            "src": attrs.source(allow_directory = True),
            "build_type": attrs.option(attrs.string(), default = None),
            "custom_setup": attrs.option(attrs.source(), default = None),
            "setup_deps": attrs.option(attrs.list(attrs.dep()), default = None),
            "exposed_modules": attrs.list(attrs.string(), default = []),
            "reexported_modules": attrs.list(attrs.string(), default = []),
            "other_modules": attrs.list(attrs.string(), default = []),
            "hs_source_dirs": attrs.list(attrs.string(), default = []),
            "default_language": attrs.string(default = "GHC2021"),
            "default_extensions": attrs.list(attrs.string(), default = []),
            "c_sources": attrs.list(attrs.string(), default = []),
            "include_dirs": attrs.list(attrs.string(), default = []),
            "cc_options": attrs.list(attrs.string(), default = []),
            "cpp_options": attrs.list(attrs.string(), default = []),
            "ld_options": attrs.list(attrs.string(), default = []),
            "extra_libraries": attrs.list(attrs.string(), default = []),
            "linker_flags": attrs.list(attrs.arg(), default = []),
            "_setup_templates": attrs.default_only(
                attrs.source(
                    allow_directory = True,
                    default = "toolchains//haskell/cabal:setup_templates",
                ),
            ),
            "_default_setup_deps": attrs.default_only(
                attrs.list(
                    attrs.dep(),
                    default = [
                        "toolchains//haskell/lib:{}".format(pkg["name"])
                        for pkg in BOOT_MANIFESTS.values()[0]["package"]
                    ],
                ),
            ),
            "_cxx_toolchain": toolchains_common.cxx(),
            "_haskell_toolchain": toolchains_common.haskell(),
        } |
        buck.labels_arg()
    ),
)
