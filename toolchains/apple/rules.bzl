load("@prelude//apple:apple_code_signing_types.bzl", "CodeSignConfiguration")
load("@prelude//apple:apple_rules_decls.bzl", "apple_rules")
load("@prelude//apple:apple_toolchain_types.bzl", "AppleToolsInfo")
load("@prelude//utils:clear_platform.bzl", "clear_platform_transition")
load("//apple/third-party/prelude/apple:apple_test.bzl", "apple_test_impl")

def _fix_platforms(**kwargs):
    if "default_target_platform" not in kwargs:
        kwargs["default_target_platform"] = read_root_config(
            "cxx",
            "default_platform",
            "prelude//platforms:default",
        )
    return kwargs

# override some of the attrs since their default values select based on
# Meta-internal constraints
apple_common_attrs = {
    "_enable_library_evolution": attrs.bool(default = False),
    "enable_distributed_thinlto": attrs.bool(default = False),
    "_apple_tools": attrs.dep(
        default = "//apple:apple-tools",
        providers = [AppleToolsInfo],
    ),
}

_apple_info_plist = rule(
    impl = apple_rules.apple_info_plist.impl,
    attrs = (
        apple_rules.apple_info_plist.attrs |
        apple_common_attrs
    ),
)

_apple_binary = rule(
    impl = apple_rules.apple_binary.impl,
    attrs = (
        apple_rules.apple_binary.attrs |
        apple_common_attrs
    ),
)

_apple_library = rule(
    impl = apple_rules.apple_library.impl,
    attrs = (
        apple_rules.apple_library.attrs |
        apple_common_attrs |
        {
            "_swift_enable_testing": attrs.bool(default = False),
        }
    ),
    uses_plugins = apple_rules.apple_library.uses_plugins,
)

_apple_test = rule(
    impl = apple_test_impl,
    attrs = (
        apple_rules.apple_test.attrs |
        apple_common_attrs |
        {
            "extension": attrs.string(default = "xctest"),
            "_fast_adhoc_signing_enabled_default": attrs.bool(default = True),
            "_skip_adhoc_resigning_scrubbed_frameworks_default": attrs.bool(default = False),
            "_strict_provisioning_profile_search_default": attrs.bool(default = True),
            "entitlements_verification_check_enabled": attrs.bool(default = False),
            "versioned_macos_bundle": attrs.bool(default = False),
            "_watch_simulator": attrs.transition_dep(cfg = clear_platform_transition, default = "//apple:no_apple_simulators"),
            "_provisioning_profiles": attrs.dep(default = "//apple:no_binary"),
            "_iphone_unbooted_simulator": attrs.transition_dep(cfg = clear_platform_transition, default = "//apple:no_apple_simulators"),
            "_iphone_booted_simulator": attrs.transition_dep(cfg = clear_platform_transition, default = "//apple:no_apple_simulators"),
            "_ipad_simulator": attrs.transition_dep(cfg = clear_platform_transition, default = "//apple:no_apple_simulators"),
            "privacy_manifest": attrs.option(attrs.source(), default = None),
            "copy_public_framework_headers": attrs.option(attrs.bool(), default = None),
            "_code_signing_configuration": attrs.enum(CodeSignConfiguration.values(), default = "none"),
            "_apple_xctoolchain": attrs.toolchain_dep(default = "//:apple-default"),
        }
    ),
    uses_plugins = apple_rules.apple_library.uses_plugins,
)

def apple_info_plist(**kwargs):
    _apple_info_plist(**kwargs)

def apple_binary(**kwargs):
    kwargs = _fix_platforms(**kwargs)
    _apple_binary(**kwargs)

def apple_library(**kwargs):
    kwargs = _fix_platforms(**kwargs)
    _apple_library(**kwargs)

def apple_test(**kwargs):
    kwargs = _fix_platforms(**kwargs)

    if kwargs.get("swift_testing"):
        swift_compat_lib_path = read_root_config(
            "apple",
            "swift_compat_lib_path",
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx",
        )
        kwargs["linker_flags"] = [
            "-Wl,-rpath," + swift_compat_lib_path,
        ] + kwargs.get("linker_flags", [])

    _apple_test(**kwargs)
