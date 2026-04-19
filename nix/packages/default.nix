{
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) findFirst licenses;

  binPackage =
    name: path: meta:
    let
      info = fromTOML (builtins.readFile path);
      platform = findFirst (
        b: b.platform == pkgs.stdenv.hostPlatform.system
      ) (throw "Unsupported platform") info.bin;
    in
    pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
      pname = "${name}-bin";
      version = info.version;

      src = pkgs.fetchurl { inherit (platform) url hash; };
      sourceRoot = ".";

      nativeBuildInputs = with pkgs; [ zstd ];

      unpackPhase = ''
        runHook preUnpack
        unzstd "$src" -o ${name}
        chmod +x ${name}
        runHook postUnpack
      '';

      postInstall = ''
        mkdir -p "$out/bin"
        mv ${name} "$out/bin/${name}"
      '';

      meta = {
        mainProgram = name;
        platforms = map (b: b.platform) info.bin;
        sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
      }
      // meta;
    });

in
{
  buck2 = binPackage "buck2" ./buck2.toml {
    license = [
      licenses.asl20
      licenses.mit
    ];
  };

  reindeer = binPackage "reindeer" ./reindeer.toml {
    license = [ licenses.mit ];
  };

  rust-project = binPackage "rust-project" ./rust-project.toml {
    license = [
      licenses.asl20
      licenses.mit
    ];
  };
}
