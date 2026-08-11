{
  description = "zed-pkg organization automation and SOPS secret tooling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    ores-sops.url = "github:ORESoftware/ores-sops/791739c60a42fd43d5879f9f088628253179d466";
  };

  outputs = { nixpkgs, ores-sops, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            packages = [
              ores-sops.packages.${system}.default
              pkgs.age
              pkgs.git
              pkgs.just
              pkgs.sops
            ];
            shellHook = ores-sops.lib.shellHook;
          };
        });

      formatter = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.nixfmt-rfc-style);
    };
}
