load("//haskell/lib/pkgs:ghc-9.10.3-aarch64-apple-darwin.toml", darwin_pkgs = "value")
load("//haskell/lib/pkgs:ghc-9.10.3-x86_64-ubuntu20_04-linux.toml", ubuntu_pkgs = "value")
load("//haskell/lib/pkgs:ghc-9.10.3.20260403-wasm32-unknown-wasi.toml", wasi_pkgs = "value")

BOOT_MANIFESTS = {
    "ghc-9.10.3-x86_64-ubuntu20_04-linux": ubuntu_pkgs,
    "ghc-9.10.3-aarch64-apple-darwin": darwin_pkgs,
    "ghc-9.10.3.20260403-wasm32-unknown-wasi": wasi_pkgs,
}
