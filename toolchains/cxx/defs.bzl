load(
    "@prelude//cxx:cxx_toolchain_types.bzl",
    "CxxInternalTools",
    "CxxPlatformInfo",
    "CxxToolchainInfo",
    "ObjcCompilerInfo",
    "ObjcxxCompilerInfo",
)
load("@prelude//decls:common.bzl", "buck")
load("@prelude//linking:link_info.bzl", "LinkOrdering")
load(
    "@prelude//toolchains:cxx.bzl",
    "CxxToolsInfo",
    prelude_system_cxx_toolchain = "system_cxx_toolchain",
)

# NOTE: this is nearly identical to system_cxx_toolchain, except it also sets
# up the ObjC/ObjC++ compilers for Apple platforms

_COMPILER_FIELDS = [
    "compiler",
    "compiler_flags",
    "compiler_type",
    "preprocessor_flags",
    "supports_content_based_paths",
    "supports_two_phase_compilation",
]

_TOOLCHAIN_FIELDS = [
    "archiver",
    "c_flags",
    "compiler",
    "compiler_type",
    "cpp_dep_tracking_mode",
    "cvtres_compiler",
    "cvtres_flags",
    "cxx_compiler",
    "cxx_flags",
    "internal_tools",
    "link_flags",
    "link_ordering",
    "link_style",
    "linker",
    "post_link_flags",
    "rc_compiler",
    "rc_flags",
    "supports_content_based_paths",
    "_cxx_tools_info",
    "_target_os_type",
]

def _system_cxx_toolchain_impl(ctx: AnalysisContext) -> Promise:
    def wrap(providers: ProviderCollection) -> list[Provider]:
        cxx = providers[CxxToolchainInfo]
        platform_name = providers[CxxPlatformInfo].name

        base = {k: getattr(cxx, k, None) for k in dir(cxx)}

        # copy ObjC/ObjC++ compiler info from C/C++ compilers
        base["objc_compiler_info"] = ObjcCompilerInfo(
            **{k: getattr(base["c_compiler_info"], k, None) for k in _COMPILER_FIELDS}
        )
        base["objcxx_compiler_info"] = ObjcxxCompilerInfo(
            **{k: getattr(base["cxx_compiler_info"], k, None) for k in _COMPILER_FIELDS}
        )

        if ctx.attrs.minimum_os_version:
            base["minimum_os_version"] = ctx.attrs.minimum_os_version

        # the prelude sets the OS name to "macos", but the Apple target triple
        # map expects the SDK name "macosx"
        platform_name = platform_name.replace("macos-", "macosx-", 1)

        return [
            DefaultInfo(),
            CxxToolchainInfo(**base),
            CxxPlatformInfo(name = platform_name),
        ]

    attrs = {}
    for name in _TOOLCHAIN_FIELDS:
        attrs[name] = getattr(ctx.attrs, name)

    return (ctx.actions.anon_target(prelude_system_cxx_toolchain, attrs)
        .promise
        .map(wrap))

system_cxx_toolchain = rule(
    impl = _system_cxx_toolchain_impl,
    attrs = {
        "archiver": attrs.option(attrs.string(), default = None),
        "c_flags": attrs.list(attrs.arg(), default = []),
        "compiler": attrs.option(attrs.string(), default = None),
        "compiler_type": attrs.option(attrs.string(), default = None),
        "cpp_dep_tracking_mode": attrs.string(default = "makefile"),
        "cvtres_compiler": attrs.option(attrs.string(), default = None),
        "cvtres_flags": attrs.list(attrs.arg(), default = []),
        "cxx_compiler": attrs.option(attrs.string(), default = None),
        "cxx_flags": attrs.list(attrs.arg(), default = []),
        "internal_tools": attrs.default_only(
            attrs.exec_dep(
                providers = [CxxInternalTools],
                default = "prelude//cxx/tools:internal_tools",
            ),
        ),
        "link_flags": attrs.list(attrs.arg(), default = []),
        "link_ordering": attrs.option(
            attrs.enum(LinkOrdering.values()),
            default = None,
        ),
        "link_style": attrs.string(default = "shared"),
        "linker": attrs.option(attrs.string(), default = None),
        "post_link_flags": attrs.list(attrs.arg(), default = []),
        "rc_compiler": attrs.option(attrs.string(), default = None),
        "rc_flags": attrs.list(attrs.arg(), default = []),
        "supports_content_based_paths": attrs.bool(default = False),
        "_cxx_tools_info": attrs.exec_dep(
            providers = [CxxToolsInfo],
            default = "prelude//toolchains/msvc:msvc_tools" if host_info().os.is_windows else "prelude//toolchains/cxx/clang:path_clang_tools",
        ),
        "_target_os_type": buck.target_os_type_arg(),

        # Apple-specific attrs
        "minimum_os_version": attrs.option(attrs.string(), default = None),
    },
    is_toolchain_rule = True,
)
