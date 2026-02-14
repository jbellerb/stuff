load(
    "@prelude//:artifact_tset.bzl",
    "ArtifactInfoTag",
    "make_artifact_tset",
)
load("@prelude//apple:apple_rules_decls.bzl", "SWIFT_VERSION_FEATURE_MAP")
load("@prelude//apple:apple_toolchain_types.bzl", "AppleToolchainInfo")
load("@prelude//apple/swift:swift_toolchain.bzl", "compute_sdk_module_graph")
load(
    "@prelude//apple/swift:swift_toolchain_types.bzl",
    "SwiftObjectFormat",
    "SwiftToolchainInfo",
)
load("@prelude//apple/swift:swift_types.bzl", "SwiftVersion")
load("@prelude//cxx:cxx_toolchain_types.bzl", "CxxPlatformInfo", "CxxToolchainInfo")
load("@prelude//utils:cmd_script.bzl", "cmd_script")

def _xcrun(actions: AnalysisActions, tool: str) -> RunInfo:
    return RunInfo(args = cmd_script(actions, tool, cmd_args("xcrun", tool)))

def _system_apple_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    providers = [
        DefaultInfo(),
        AppleToolchainInfo(
            actool = _xcrun(ctx.actions, "actool"),
            architecture = ctx.attrs.architecture,
            codesign = _xcrun(ctx.actions, "codesign"),
            codesign_allocate = _xcrun(ctx.actions, "codesign_allocate"),
            compile_resources_locally = False,
            copy_scene_kit_assets = _xcrun(ctx.actions, "copySceneKitAssets"),
            cxx_platform_info = CxxPlatformInfo(name = ctx.attrs.sdk_name + "-" + ctx.attrs.architecture),
            cxx_toolchain_info = ctx.attrs.cxx_toolchain[CxxToolchainInfo],
            dsymutil = _xcrun(ctx.actions, "dsymutil"),
            dwarfdump = _xcrun(ctx.actions, "dwarfdump"),
            extra_linker_outputs = [],
            ibtool = _xcrun(ctx.actions, "ibtool"),
            installer = ctx.label,
            installer_tool = RunInfo(),  # no-op
            libtool = _xcrun(ctx.actions, "libtool"),
            lipo = _xcrun(ctx.actions, "lipo"),
            merge_index_store = ctx.attrs._merge_index_store[RunInfo],
            momc = _xcrun(ctx.actions, "momc"),
            platform_path = ctx.attrs.platform_path,
            sdk_name = ctx.attrs.sdk_name,
            sdk_path = ctx.attrs.sdk_path,
            xcode_version = ctx.attrs.xcode_version,
            xctest = _xcrun(ctx.actions, "xctest"),
        ),
    ]

    if ctx.attrs.swift_toolchain:
        providers.append(ctx.attrs.swift_toolchain[SwiftToolchainInfo])

    return providers

system_apple_toolchain = rule(
    impl = _system_apple_toolchain_impl,
    attrs = {
        "architecture": attrs.string(default = "arm64"),
        "cxx_toolchain": attrs.toolchain_dep(default = "toolchains//:cxx"),
        "platform_path": attrs.string(),
        "sdk_name": attrs.string(default = "macosx"),
        "sdk_path": attrs.string(),
        "swift_toolchain": attrs.option(attrs.toolchain_dep(), default = None),
        "xcode_version": attrs.string(default = "15.0"),

        # prelude deps
        "_merge_index_store": attrs.default_only(
            attrs.dep(
                providers = [RunInfo],
                default = "prelude//apple/tools/index:merge_index_store",
            ),
        ),
    },
    is_toolchain_rule = True,
)

def _system_swift_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    return [
        DefaultInfo(),
        SwiftToolchainInfo(
            architecture = ctx.attrs.architecture,
            compiler = (cmd_args(ctx.attrs._swiftc_wrapper[RunInfo])
                .add(_xcrun(ctx.actions, "swiftc"))),
            compiler_flags = ctx.attrs.swiftc_flags,
            mk_swift_comp_db = ctx.attrs._make_swift_comp_db[RunInfo],
            mk_swift_interface = (cmd_args(ctx.attrs._swiftc_wrapper[RunInfo])
                .add(ctx.attrs._make_swift_interface[RunInfo])),
            object_format = SwiftObjectFormat("object"),
            platform_path = None,
            provide_swift_debug_info = True,
            resource_dir = None,
            sdk_module_path_prefixes = {},
            sdk_path = ctx.attrs.sdk_path,
            sdk_debug_info = None,
            serialized_diags_to_json = None,
            supports_explicit_module_debug_serialization = False,
            supports_incremental_file_hashing = False,
            supports_modulemaps_with_hmaps = False,
            supports_relative_resource_dir = False,
            swift_ide_test_tool = None,
            swift_stdlib_tool = _xcrun(ctx.actions, "swift-stdlib-tool"),
            swift_stdlib_tool_flags = ctx.attrs.swift_stdlib_tool_flags,
            swift_experimental_features = ctx.attrs.swift_experimental_features,
            swift_upcoming_features = ctx.attrs.swift_upcoming_features,
            uncompiled_clang_sdk_modules_deps = {},
            uncompiled_swift_sdk_modules_deps = {},
            use_depsfiles = False,
            uses_content_based_paths = False,
        ),
    ]

system_swift_toolchain = rule(
    impl = _system_swift_toolchain_impl,
    attrs = {
        "architecture": attrs.string(default = "arm64"),
        "sdk_path": attrs.string(),
        "swiftc_flags": attrs.list(attrs.arg(), default = []),
        "swift_stdlib_tool_flags": attrs.list(attrs.arg(), default = []),
        "swift_experimental_features": attrs.dict(
            key = attrs.enum(SwiftVersion),
            value = attrs.list(attrs.string()),
            sorted = False,
            default = SWIFT_VERSION_FEATURE_MAP,
        ),
        "swift_upcoming_features": attrs.dict(
            key = attrs.enum(SwiftVersion),
            value = attrs.list(attrs.string()),
            sorted = False,
            default = SWIFT_VERSION_FEATURE_MAP,
        ),

        # prelude deps
        "_make_swift_comp_db": attrs.default_only(
            attrs.exec_dep(
                providers = [RunInfo],
                default = "prelude//apple/tools:make_swift_comp_db",
            ),
        ),
        "_make_swift_interface": attrs.default_only(
            attrs.exec_dep(
                providers = [RunInfo],
                default = "prelude//apple/tools:make_swift_interface",
            ),
        ),
        "_swiftc_wrapper": attrs.default_only(
            attrs.exec_dep(
                providers = [RunInfo],
                default = "prelude//apple/tools:swift_exec",
            ),
        ),
    },
    is_toolchain_rule = True,
)

def _no_binary_impl(ctx: AnalysisContext) -> list[Provider]:
    return [DefaultInfo(), RunInfo()]

no_binary = rule(
    impl = _no_binary_impl,
    attrs = {},
)
