load("@prelude//:rules_impl.bzl", "categorized_extra_attributes")
load("@prelude//decls:haskell_rules.bzl", "haskell_rules")
load("@prelude//haskell:haskell.bzl", "haskell_binary_impl")
load("@prelude//transitions:utils.bzl", "transition_utils")

def _wasm_transition_impl(platform: PlatformInfo, refs: struct) -> PlatformInfo:
    cpu = refs.cpu[ConstraintSettingInfo].label
    os = refs.os[ConstraintSettingInfo].label

    updated_constraints = transition_utils.filtered_platform_constraints(
        platform,
        [cpu, os],
    )
    updated_constraints[cpu] = refs.wasm32[ConstraintValueInfo]
    updated_constraints[os] = refs.wasi[ConstraintValueInfo]

    return PlatformInfo(
        label = "wasm_transition",
        configuration = ConfigurationInfo(
            constraints = updated_constraints,
            values = platform.configuration.values,
        ),
    )

wasm_transition = transition(
    impl = _wasm_transition_impl,
    refs = {
        "cpu": "config//cpu/constraints:cpu",
        "wasm32": "config//cpu/constraints:wasm32",
        "os": "config//os/constraints:os",
        "wasi": "config//os/constraints:wasi",
    },
)

haskell_wasm_binary = rule(
    impl = haskell_binary_impl,
    attrs = (
        haskell_rules.haskell_binary.attrs |
        categorized_extra_attributes["haskell"]["haskell_binary"] |
        {"link_style": attrs.string(default = "static")}
    ),
    cfg = wasm_transition,
    doc = """
    A `haskell_wasm_binary()` rule represents a group of Haskell sources and
    deps which build a WebAssembly executable. It applies the WebAssembly
    platform transition automatically, so the binary and its dependencies are
    built for WebAssembly regardless of the target platform.
    """,
)
