ProtobufPluginInfo = provider(
    fields = {
        "extensions": provider_field(list[str]),
        "language": provider_field(str),
        "plugin_wrapper": provider_field(Artifact),
    },
)

ProtobufToolchainInfo = provider(
    fields = {
        "plugins": provider_field(list[ProtobufPluginInfo]),
        "protoc_wrapper": provider_field(Artifact),
    },
)

def _protobuf_plugin_impl(ctx: AnalysisContext) -> list[Provider]:
    language = ctx.attrs.language
    if language == None:
        if ctx.label.name.startswith("protoc-gen-"):
            language = ctx.label.name.removeprefix("protoc-gen-")
        else:
            fail('Language was not provided and plugin name is not in the format "protoc-gen-LANG"')

    wrapper = ctx.actions.write(
        ctx.actions.declare_output(
            "plugin-{}-wrapper.sh".format(language),
        ),
        cmd_args([
            "#!/usr/bin/env sh",
            cmd_args("exec", ctx.attrs.plugin[RunInfo].args, '"$@"', delimiter = " "),
        ]),
        is_executable = True,
        with_inputs = True,
    )

    return [
        DefaultInfo(),
        ProtobufPluginInfo(
            extensions = ctx.attrs.extensions or [".pb.{}".format(language)],
            language = language,
            plugin_wrapper = wrapper,
        ),
    ]

protobuf_plugin = rule(
    impl = _protobuf_plugin_impl,
    attrs = {
        "extensions": attrs.list(
            attrs.string(),
            default = [],
            doc = """
            The extensions of files produced by this plugin.

            If the plugin converts "foo.proto" -> "foo_bar.pb.baz", the extension would
            be "_bar.pb.baz".
            """,
        ),
        "language": attrs.option(
            attrs.string(),
            default = None,
            doc = "The language this plugin builds for.",
        ),
        "plugin": attrs.exec_dep(
            doc = 'The plugin executable. This will be named something like "protoc-gen-LANG".',
            providers = [RunInfo],
        ),
    },
)

def _protobuf_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    plugins = [p[ProtobufPluginInfo] for p in ctx.attrs.plugins]
    protoc = cmd_args([
        ctx.attrs.protoc[RunInfo].args,
        [cmd_args("--plugin=protoc-gen-{}".format(p.language), p.plugin_wrapper, delimiter = "=") for p in plugins],
    ])

    wrapper = ctx.actions.write(
        ctx.actions.declare_output("protoc-wrapper.sh"),
        cmd_args([
            "#!/usr/bin/env sh",
            "LANG=$1",
            "OUTPUT=$2",
            "shift 2",
            'mkdir -p "$OUTPUT"',
            cmd_args([protoc, '"--${LANG}_out=$OUTPUT"', '"$@"'], delimiter = " "),
        ]),
        is_executable = True,
        with_inputs = True,
    )

    return [
        DefaultInfo(),
        ProtobufToolchainInfo(
            plugins = plugins,
            protoc_wrapper = wrapper,
        ),
    ]

protobuf_toolchain = rule(
    impl = _protobuf_toolchain_impl,
    attrs = {
        "plugins": attrs.list(
            attrs.exec_dep(providers = [ProtobufPluginInfo]),
            default = [],
            doc = "The language plugins protoc will build with.",
        ),
        "protoc": attrs.exec_dep(
            doc = "The protoc binary.",
            providers = [RunInfo],
        ),
    },
    is_toolchain_rule = True,
)

def _protobuf_library_impl(ctx: AnalysisContext) -> list[Provider]:
    protobuf_toolchain = ctx.attrs._protobuf_toolchain[ProtobufToolchainInfo]

    plugin_candidates = [p for p in protobuf_toolchain.plugins if p.language == ctx.attrs.language]
    if len(plugin_candidates) == 0:
        fail("No protoc plugin named '{}'".format(ctx.attrs.language))
    plugin = plugin_candidates[0]

    output = ctx.actions.declare_output(ctx.label.name, dir = True)
    default_outputs = [
        output.project(name, hide_prefix = True) for name in [src.basename.removesuffix(".proto") + ext for src in ctx.attrs.srcs for ext in plugin.extensions]
    ]

    cmd = cmd_args([
        protobuf_toolchain.protoc_wrapper,
        ctx.attrs.language,
        output.as_output(),
        # anchor each source at its own directory so protoc sees basenames as
        # the canonical names and generated files land at the root of $OUT
        [cmd_args(src, format = "--proto_path={}", parent = 1) for src in ctx.attrs.srcs],
        [cmd_args("--{}_opt".format(ctx.attrs.language), opt, delimiter = "=") for opt in ctx.attrs.options],
        ctx.attrs.srcs,
    ])

    ctx.actions.run(cmd, category = "protoc_compile", identifier = ctx.label.name)

    return [
        DefaultInfo(
            default_outputs = default_outputs,
            sub_targets = {out.short_path: [DefaultInfo(out)] for out in default_outputs},
        ),
    ]

protobuf_library = rule(
    impl = _protobuf_library_impl,
    attrs = {
        "language": attrs.string(
            doc = "The languages to compile a protobuf implementations for.",
        ),
        "options": attrs.list(
            attrs.arg(),
            default = [],
            doc = "Options to pass to the protoc plugin.",
        ),
        "srcs": attrs.list(
            attrs.source(),
            default = [],
            doc = "The source protobuf files.",
        ),
        "_protobuf_toolchain": attrs.default_only(
            attrs.toolchain_dep(
                default = "toolchains//:protobuf",
                providers = [ProtobufToolchainInfo],
            ),
        ),
    },
)
