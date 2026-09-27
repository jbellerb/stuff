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
        configuration = ConfigurationInfo(
            constraints = updated_constraints,
            values = platform.configuration.values,
        ),
        label = "wasm_transition",
    )

wasm_transition = transition(
    impl = _wasm_transition_impl,
    refs = {
        "cpu": "config//cpu/constraints:cpu",
        "os": "config//os/constraints:os",
        "wasi": "config//os/constraints:wasi",
        "wasm32": "config//cpu/constraints:wasm32",
    },
)
