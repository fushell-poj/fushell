{
  description = "A Flutter shell for Linux";

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
    zigDepsFor = system: nixpkgs.legacyPackages.${system}.callPackage ./deps.nix {};
  in {
    lib = {
      mkFushell = {
        pkgs,
        engineArtifacts,
        zigDeps ? pkgs.callPackage ./deps.nix {},
        version ? "0.1.0",
      }:
        (pkgs.callPackage ./nix/mk-fushell.nix {
          zig = zig-overlay.packages.${pkgs.stdenv.hostPlatform.system}."0.16.0";
        }) {
          inherit engineArtifacts zigDeps version;
        };

      mkFushellApp = {
        pkgs,
        pname,
        bundle,
        version ? "0.1.0",
        executableName ? pname,
        meta ? {},
      }:
        (pkgs.callPackage ./nix/mk-fushell-app.nix {}) {
          inherit pname bundle version executableName meta;
        };
    };

    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      # gclient 包装（自建，见 nix/pkgs/depot_tools/default.nix）。
      depot-tools = pkgs.callPackage ./nix/pkgs/depot_tools {};
      zig-deps = zigDepsFor system;
      build-local = pkgs.writeShellApplication {
        name = "fushell-build-local";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.nix
        ];
        excludeShellChecks = [ "SC2016" ];
        text = builtins.readFile ./nix/build-local.sh;
      };
    });

    checks = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      fixtureEngine = mode: pkgs.writeText "fushell-fixture-engine-${mode}.so" "fixture-${mode}";
    in {
      fushell-fixture = self.lib.mkFushell {
        inherit pkgs;
        engineArtifacts = {
          debug = fixtureEngine "debug";
          profile = fixtureEngine "profile";
          release = fixtureEngine "release";
        };
        zigDeps = zigDepsFor system;
        version = "fixture";
      };
    });

    apps = forAllSystems (system: {
      build-local = {
        type = "app";
        program = "${self.packages.${system}.build-local}/bin/fushell-build-local";
        meta.description = "Import local Flutter engine artifacts into the Nix store and build Fushell";
      };
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
