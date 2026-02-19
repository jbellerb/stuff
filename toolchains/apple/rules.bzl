load("@prelude//apple:apple_rules_decls.bzl", "apple_rules")
load("@prelude//apple:apple_toolchain_types.bzl", "AppleToolsInfo")

# override some of the attrs since their default values select based on
# Meta-internal constraints
apple_common_attrs = {
    "_enable_library_evolution": attrs.bool(default = False),
    "enable_distributed_thinlto": attrs.bool(default = False),
    "_apple_tools": attrs.dep(
        default = "toolchains//apple:apple-tools",
        providers = [AppleToolsInfo],
    ),
}

apple_binary = rule(
    impl = apple_rules.apple_binary.impl,
    attrs = (
        apple_rules.apple_binary.attrs |
        apple_common_attrs
    ),
)

apple_library = rule(
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
