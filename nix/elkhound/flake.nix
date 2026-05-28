{
  description = "elkhound parser generator - WeiDUorg/elkhound at pinned commit";

  # Pinned to the same nixpkgs commit devbox uses, so no second download is needed.
  # To update: bump the rev, then run `nix flake update` and update devbox.json.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/01fbdeef22b76df85ea168fbfe1bfd9e63681b30";

  outputs = { self, nixpkgs }:
    let
      # The exact same commit that vcpkg-ports/elkhound-runtime/portfile.cmake pins.
      # Both must be kept in sync when upgrading.
      src = {
        owner  = "WeiDUorg";
        repo   = "elkhound";
        rev    = "b8f5589de119c89b36b1fc21d2f51c4a942ee3a8";
        hash   = "sha256-8kktKhGY71zsNDAPKxUPBhy39N7m+P4tWmpbWxK7HhI=";
      };

      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.elkhound.overrideAttrs (_old: {
            src = pkgs.fetchFromGitHub src;
          });
        }
      );
    };
}
