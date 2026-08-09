{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
    zls-overlay.url = "github:zigtools/zls/0.16.0";
    zls-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {
    self,
    nixpkgs,
    zig-overlay,
    zls-overlay,
    ...
  }: let
    forAllSystems = nixpkgs.lib.genAttrs [
      "aarch64-linux"
      "x86_64-linux"
    ];
  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      # gclient 包装 (自建, 见 nix/pkgs/depot_tools/default.nix)
      depot-tools = pkgs.callPackage ./nix/pkgs/depot_tools {};
    });
    devShells = forAllSystems (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = zig-overlay.packages.${system}."0.16.0";
        zls = zls-overlay.packages.${system}.zls;
      in {
        default = pkgs.callPackage ./nix/devshell.nix {
          inherit zig zls;
          depot-tools = self.packages.${system}.depot-tools;
        };
      }
    );
  };
}
