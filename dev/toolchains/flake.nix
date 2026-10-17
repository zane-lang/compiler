{
  description = "Portable upstream Zig distribution for Devbox and release archives";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  outputs = { self, nixpkgs }: {
    packages.x86_64-linux.zig =
      let
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        source = builtins.fromJSON (builtins.readFile ./zig.json);
      in pkgs.stdenvNoCC.mkDerivation {
        pname = "zig-standalone";
        inherit (source) version;
        src = pkgs.fetchurl { inherit (source) url sha256; };
        unpackPhase = ''
          tar --no-same-owner -xf $src --strip-components=1
        '';
        dontConfigure = true;
        dontBuild = true;
        # Zig is already static. Keep it and its libraries relocatable.
        dontFixup = true;
        installPhase = ''
          mkdir -p $out/bin
          cp zig LICENSE $out/
          cp -r lib $out/lib
          ln -s ../zig $out/bin/zig
        '';
      };
  };
}
