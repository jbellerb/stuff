load("//tools/installer:defs.bzl", "install")

_target_regex = regex(
    "^(:?[-.0-9a-z_A-Z]*\\/\\/[-./0-9a-z_A-Z]+)?:[-.0-9a-z_A-Z]+$",
)

def _separate_targets(patterns: list[str]):  # -> tuple[list[str], list[str]]:
    globs = []
    targets = []
    for pattern in patterns:
        if _target_regex.match(pattern):
            targets.append(pattern)
        else:
            globs.append(pattern)

    return globs, targets

def dotfiles(files: dict[str, list[str]], name: str = "install"):
    srcs = {}

    for dest, patterns in files.items():
        dest_prefix = dest.rstrip("/") + "/"
        globs, targets = _separate_targets(patterns)
        for file in native.glob(globs):
            _, _, basename = file.rpartition("/")
            target_name = file.replace("/", "-").replace(".", "_")

            srcs[dest_prefix + basename] = ":{}".format(target_name)

            native.export_file(
                name = target_name,
                src = file,
                visibility = ["PUBLIC"],
            )
        for target in targets:
            _, _, targetname = target.rpartition(":")
            srcs[dest_prefix + targetname] = target

    install(
        name = name,
        srcs = srcs,
        visibility = ["PUBLIC"],
    )
