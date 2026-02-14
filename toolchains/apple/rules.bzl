# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is dual-licensed under either the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree or the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree. You may select, at your option, one of the
# above-listed licenses.

# NOTE: vendored apple_binary and apple_library rule declarations. Some fields
# (notably, target_sdk_version_transition) are removed because they require
# Meta-internal config// constraints.

load("@prelude//:attrs_validators.bzl", "validation_common")
load("@prelude//:validation_deps.bzl", "VALIDATION_DEPS_ATTR_NAME", "VALIDATION_DEPS_ATTR_TYPE")
load("@prelude//apple:apple_binary.bzl", "apple_binary_impl")
load("@prelude//apple:apple_common.bzl", "apple_common")
load("@prelude//apple:apple_library.bzl", "AppleSharedLibraryMachOFileType", "apple_library_impl")
load("@prelude//apple:apple_platforms.bzl", "APPLE_PLATFORMS_KEY")
load(
    "@prelude//apple:apple_rules_impl_utility.bzl",
    "APPLE_ARCHIVE_OBJECTS_LOCALLY_OVERRIDE_ATTR_NAME",
    "get_apple_xctoolchain_attr",
    "get_apple_xctoolchain_bundle_id_attr",
    "get_skip_swift_incremental_outputs_attrs",
    "get_swift_incremental_file_hashing_attrs",
    "get_swift_incremental_logging_attrs",
    "get_swift_incremental_remote_outputs_attrs",
)
load("@prelude//apple:apple_toolchain_types.bzl", "AppleToolsInfo")
load("@prelude//apple/swift:swift_incremental_support.bzl", "SwiftCompilationMode")
load("@prelude//apple/swift:swift_types.bzl", "SwiftMacroPlugin", "SwiftVersion")
load("@prelude//cxx:headers.bzl", "CPrecompiledHeaderInfo", "HeaderMode")
load("@prelude//cxx:link_groups_types.bzl", "LINK_GROUP_MAP_ATTR")
load(
    "@prelude//decls:common.bzl",
    "CxxRuntimeType",
    "CxxSourceType",
    "HeadersAsRawHeadersMode",
    "LinkableDepType",
    "buck",
)
load("@prelude//decls:cxx_common.bzl", "cxx_common")
load("@prelude//decls:native_common.bzl", "native_common")
load("@prelude//linking:execution_preference.bzl", "link_execution_preference_attr")
load("@prelude//linking:link_info.bzl", "LinkOrdering")
load("@prelude//linking:types.bzl", "Linkage")
load("@prelude//transitions:constraint_overrides.bzl", "constraint_overrides")
load("@prelude//utils:buckconfig.bzl", "read_bool")

def _apple_tools_arg():
    return {
        "_apple_tools": attrs.dep(
            default = "toolchains//apple:apple-tools",
            providers = [AppleToolsInfo],
        ),
    }

apple_binary = rule(
    impl = apple_binary_impl,
    attrs = (
        cxx_common.srcs_arg() |
        apple_common.headers_arg() |
        {
            "entitlements_file": attrs.option(attrs.source(), default = None),
        } |
        apple_common.apple_tools_arg() |
        apple_common.apple_toolchain_arg() |
        apple_common.exported_headers_arg() |
        apple_common.header_path_prefix_arg() |
        apple_common.frameworks_arg() |
        cxx_common.preprocessor_flags_arg() |
        cxx_common.exported_preprocessor_flags_arg(
            exported_preprocessor_flags_type = attrs.list(attrs.arg(), default = []),
        ) |
        cxx_common.compiler_flags_arg() |
        cxx_common.linker_extra_outputs_arg() |
        cxx_common.linker_flags_arg() |
        cxx_common.exported_linker_flags_arg() |
        native_common.link_style() |
        native_common.link_group_public_deps_label() |
        apple_common.target_sdk_version() |
        apple_common.extra_xcode_sources() |
        apple_common.extra_xcode_files() |
        apple_common.serialize_debugging_options_arg() |
        apple_common.uses_explicit_modules_arg() |
        apple_common.apple_sanitizer_compatibility_arg() |
        apple_common.executable_name_arg() |
        apple_common.info_plist_substitutions_arg() |
        cxx_common.supported_platforms_regex_arg() |
        buck.contacts_arg() |
        apple_common.default_host_platform_arg() |
        apple_common.default_platform_arg() |
        buck.labels_arg() |
        buck.licenses_arg() |
        apple_common.defaults_arg() |
        apple_common.deps_arg() |
        apple_common.devirt_enabled_arg() |
        apple_common.diagnostics_arg() |
        apple_common.enable_cxx_interop_arg() |
        cxx_common.exported_header_style_arg() |
        apple_common.fat_lto_arg() |
        cxx_common.header_namespace_arg() |
        cxx_common.include_directories_arg() |
        apple_common.libraries_arg() |
        apple_common.link_group_arg() |
        apple_common.minimum_os_version_arg() |
        apple_common.modular_arg() |
        apple_common.module_name_arg() |
        apple_common.module_requires_cxx_arg() |
        cxx_common.public_include_directories_arg() |
        cxx_common.public_system_include_directories_arg() |
        apple_common.sdk_modules_arg() |
        native_common.soname() |
        apple_common.static_library_basename_arg() |
        apple_common.stripped_default_arg() |
        apple_common.swift_module_skip_function_bodies_arg() |
        apple_common.swift_package_name_arg() |
        apple_common.thin_lto_arg() |
        apple_common.use_submodules_arg() |
        apple_common.uses_cxx_explicit_modules_arg() |
        apple_common.uses_modules_arg() |
        {
            "application_extension": attrs.bool(default = False),
            "binary_linker_flags": attrs.list(attrs.arg(), default = []),
            "bridging_header": attrs.option(attrs.source(), default = None),
            "can_be_asset": attrs.option(attrs.bool(), default = None),
            "cxx_runtime_type": attrs.option(attrs.enum(CxxRuntimeType), default = None),
            "dist_thin_lto_codegen_flags": attrs.list(attrs.arg(), default = []),
            "enable_distributed_thinlto": attrs.bool(default = False),
            "enable_library_evolution": attrs.option(attrs.bool(), default = None),
            "exported_lang_preprocessor_flags": attrs.dict(
                key = attrs.enum(CxxSourceType),
                value = attrs.list(attrs.arg()),
                sorted = False,
                default = {},
            ),
            "focused_list_target": attrs.option(attrs.dep(), default = None),
            "force_static": attrs.option(attrs.bool(), default = None),
            "headers_as_raw_headers_mode": attrs.option(
                attrs.enum(HeadersAsRawHeadersMode),
                default = None,
            ),
            "info_plist": attrs.option(attrs.source(), default = None),
            "lang_compiler_flags": attrs.dict(
                key = attrs.enum(CxxSourceType),
                value = attrs.list(attrs.arg()),
                sorted = False,
                default = {},
            ),
            "lang_preprocessor_flags": attrs.dict(
                key = attrs.enum(CxxSourceType),
                value = attrs.list(attrs.arg()),
                sorted = False,
                default = {},
            ),
            "link_execution_preference": link_execution_preference_attr(),
            "link_group_map": LINK_GROUP_MAP_ATTR,
            "link_ordering": attrs.option(attrs.enum(LinkOrdering.values()), default = None),
            "link_whole": attrs.option(attrs.bool(), default = None),
            "post_linker_flags": attrs.list(attrs.arg(), default = []),
            "precompiled_header": attrs.option(
                attrs.dep(providers = [CPrecompiledHeaderInfo]),
                default = None,
            ),
            "prefer_stripped_objects": attrs.bool(default = False),
            "preferred_linkage": attrs.enum(Linkage.values(), default = "any"),
            "prefix_header": attrs.option(attrs.source(), default = None),
            "raw_headers": attrs.set(attrs.source(), sorted = True, default = []),
            "reexport_all_header_dependencies": attrs.option(attrs.bool(), default = None),
            "sanitizer_runtime_enabled": attrs.option(attrs.bool(), default = None),
            "stripped": attrs.option(attrs.bool(), default = None),
            "supports_merged_linking": attrs.option(attrs.bool(), default = None),
            "swift_compilation_mode": attrs.enum(SwiftCompilationMode.values(), default = "wmo"),
            "swift_compiler_flags": attrs.list(attrs.arg(), default = []),
            "swift_interface_compilation_enabled": attrs.bool(default = False),
            "swift_version": attrs.option(attrs.enum(SwiftVersion), default = None),
            "_apple_xctoolchain": get_apple_xctoolchain_attr(),
            "_apple_xctoolchain_bundle_id": get_apple_xctoolchain_bundle_id_attr(),
            "_enable_library_evolution": attrs.bool(default = False),
            "_swift_enable_testing": attrs.default_only(attrs.bool(default = False)),
            VALIDATION_DEPS_ATTR_NAME: VALIDATION_DEPS_ATTR_TYPE,
        } |
        buck.allow_cache_upload_arg() |
        validation_common.attrs_validators_arg() |
        constraint_overrides.attributes |
        get_skip_swift_incremental_outputs_attrs() |
        {
            APPLE_PLATFORMS_KEY: attrs.dict(
                key = attrs.string(),
                value = attrs.dep(),
                sorted = False,
                default = {},
            ),
        } |
        _apple_tools_arg()
    ),
)

apple_library = rule(
    impl = apple_library_impl,
    attrs = (
        cxx_common.srcs_arg() |
        apple_common.headers_arg() |
        apple_common.exported_headers_arg() |
        apple_common.header_path_prefix_arg() |
        cxx_common.header_namespace_arg() |
        apple_common.frameworks_arg() |
        cxx_common.preprocessor_flags_arg() |
        cxx_common.exported_preprocessor_flags_arg(
            exported_preprocessor_flags_type = attrs.list(attrs.arg(), default = []),
        ) |
        cxx_common.compiler_flags_arg() |
        cxx_common.linker_extra_outputs_arg() |
        cxx_common.linker_flags_arg() |
        cxx_common.exported_linker_flags_arg() |
        apple_common.target_sdk_version() |
        native_common.preferred_linkage(
            preferred_linkage_type = attrs.option(attrs.enum(Linkage.values()), default = None),
        ) |
        native_common.link_style() |
        native_common.link_whole(link_whole_type = attrs.option(attrs.bool(), default = None)) |
        cxx_common.reexport_all_header_dependencies_arg() |
        cxx_common.exported_deps_arg() |
        cxx_common.raw_headers_arg() |
        cxx_common.include_directories_arg() |
        cxx_common.public_include_directories_arg() |
        cxx_common.public_system_include_directories_arg() |
        cxx_common.raw_headers_as_headers_mode_arg() |
        apple_common.extra_xcode_sources() |
        apple_common.extra_xcode_files() |
        apple_common.serialize_debugging_options_arg() |
        apple_common.uses_explicit_modules_arg() |
        apple_common.meta_apple_library_validation_enabled_arg() |
        apple_common.executable_name_arg() |
        apple_common.info_plist_substitutions_arg() |
        cxx_common.supported_platforms_regex_arg() |
        apple_common.apple_tools_arg() |
        apple_common.apple_toolchain_arg() |
        validation_common.attrs_validators_arg() |
        buck.contacts_arg() |
        apple_common.default_host_platform_arg() |
        apple_common.default_platform_arg() |
        buck.labels_arg() |
        buck.licenses_arg() |
        apple_common.defaults_arg() |
        apple_common.deps_arg() |
        apple_common.devirt_enabled_arg() |
        apple_common.diagnostics_arg() |
        apple_common.enable_cxx_interop_arg() |
        cxx_common.exported_header_style_arg() |
        apple_common.fat_lto_arg() |
        apple_common.libraries_arg() |
        apple_common.link_group_arg() |
        apple_common.minimum_os_version_arg() |
        apple_common.modular_arg() |
        apple_common.module_name_arg() |
        apple_common.module_requires_cxx_arg() |
        apple_common.sdk_modules_arg() |
        native_common.soname() |
        apple_common.static_library_basename_arg() |
        apple_common.stripped_default_arg() |
        apple_common.swift_module_skip_function_bodies_arg() |
        apple_common.swift_package_name_arg() |
        apple_common.thin_lto_arg() |
        apple_common.use_submodules_arg() |
        apple_common.uses_cxx_explicit_modules_arg() |
        apple_common.uses_modules_arg() |
        {
            "bridging_header": attrs.option(attrs.source(), default = None),
            "can_be_asset": attrs.option(attrs.bool(), default = None),
            "cxx_runtime_type": attrs.option(attrs.enum(CxxRuntimeType), default = None),
            "dist_thin_lto_codegen_flags": attrs.list(attrs.arg(), default = []),
            "enable_distributed_thinlto": attrs.bool(default = False),
            "enable_library_evolution": attrs.option(attrs.bool(), default = None),
            "exported_lang_preprocessor_flags": attrs.dict(
                key = attrs.enum(CxxSourceType),
                value = attrs.list(attrs.arg()),
                sorted = False,
                default = {},
            ),
            "exported_post_linker_flags": attrs.list(attrs.arg(), default = []),
            "focused_list_target": attrs.option(attrs.dep(), default = None),
            "force_static": attrs.option(attrs.bool(), default = None),
            "header_mode": attrs.option(attrs.enum(HeaderMode.values()), default = None),
            "headers_as_raw_headers_mode": attrs.option(
                attrs.enum(HeadersAsRawHeadersMode),
                default = None,
            ),
            "info_plist": attrs.option(attrs.source(), default = None),
            "lang_compiler_flags": attrs.dict(
                key = attrs.enum(CxxSourceType),
                value = attrs.list(attrs.arg()),
                sorted = False,
                default = {},
            ),
            "lang_preprocessor_flags": attrs.dict(
                key = attrs.enum(CxxSourceType),
                value = attrs.list(attrs.arg()),
                sorted = False,
                default = {},
            ),
            "link_execution_preference": link_execution_preference_attr(),
            "link_group_map": LINK_GROUP_MAP_ATTR,
            "link_ordering": attrs.option(attrs.enum(LinkOrdering.values()), default = None),
            "post_linker_flags": attrs.list(attrs.arg(), default = []),
            "precompiled_header": attrs.option(
                attrs.dep(providers = [CPrecompiledHeaderInfo]),
                default = None,
            ),
            "preferred_linkage": attrs.enum(Linkage.values(), default = "any"),
            "prefix_header": attrs.option(attrs.source(), default = None),
            "public_framework_headers": attrs.named_set(
                attrs.source(),
                sorted = True,
                default = [],
            ),
            "shared_library_macho_file_type": attrs.enum(
                AppleSharedLibraryMachOFileType.values(),
                default = "dylib",
            ),
            "stripped": attrs.option(attrs.bool(), default = None),
            "supports_header_symlink_subtarget": attrs.bool(default = False),
            "supports_merged_linking": attrs.option(attrs.bool(), default = None),
            "supports_shlib_interfaces": attrs.bool(default = True),
            "swift_compilation_mode": attrs.enum(SwiftCompilationMode.values(), default = "wmo"),
            "swift_compiler_flags": attrs.list(attrs.arg(), default = []),
            "swift_interface_compilation_enabled": attrs.bool(default = True),
            "swiftinterface_subtarget_enabled": attrs.bool(
                default = read_bool("apple", "swiftinterface_subtarget_enabled", default = False, root_cell = True),
            ),
            "swift_macro_deps": attrs.list(
                attrs.plugin_dep(kind = SwiftMacroPlugin),
                default = [],
            ),
            "swift_version": attrs.option(attrs.enum(SwiftVersion), default = None),
            "use_archive": attrs.option(attrs.bool(), default = None),
            "_apple_xctoolchain": get_apple_xctoolchain_attr(),
            "_apple_xctoolchain_bundle_id": get_apple_xctoolchain_bundle_id_attr(),
            "_enable_library_evolution": attrs.bool(default = False),
            "_swift_enable_testing": attrs.bool(default = False),
            "uses_experimental_content_based_path_hashing": attrs.bool(default = False),
            APPLE_ARCHIVE_OBJECTS_LOCALLY_OVERRIDE_ATTR_NAME: attrs.option(
                attrs.bool(),
                default = None,
            ),
            VALIDATION_DEPS_ATTR_NAME: VALIDATION_DEPS_ATTR_TYPE,
        } |
        buck.allow_cache_upload_arg() |
        get_swift_incremental_file_hashing_attrs() |
        get_swift_incremental_logging_attrs() |
        get_swift_incremental_remote_outputs_attrs() |
        get_skip_swift_incremental_outputs_attrs() |
        {
            APPLE_PLATFORMS_KEY: attrs.dict(
                key = attrs.string(),
                value = attrs.dep(),
                sorted = False,
                default = {},
            ),
        } |
        _apple_tools_arg()
    ),
    uses_plugins = [SwiftMacroPlugin],
)
