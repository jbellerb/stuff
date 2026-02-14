load("//tools/installer:defs.bzl", "install")

def dotfiles(files: dict[str, list[str]], name: str = "install"):
    srcs = {}

    for dest, patterns in files.items():
        for file in native.glob(patterns):
            _, _, basename = file.rpartition("/")
            dest_path = "{}/{}".format(dest.rstrip("/"), basename)
            target_name = file.replace("/", "-").replace(".", "_")

            srcs[dest_path] = ":{}".format(target_name)

            native.export_file(
                name = target_name,
                src = file,
                visibility = ["PUBLIC"],
            )

    install(
        name = name,
        srcs = srcs,
        visibility = ["PUBLIC"],
    )
