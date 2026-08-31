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
    zigDepsForPkgs = pkgs:
      pkgs.callPackage ./deps.nix {
        # Flutter embedder ZIP 是平铺归档；zon2nix 目前无法在生成的 deps.nix 中表达该布局。
        fetchzip = args:
          pkgs.fetchzip (args
            // nixpkgs.lib.optionalAttrs
              (nixpkgs.lib.hasSuffix "/linux-x64-embedder.zip" args.url)
              { stripRoot = false; });
      };
    zigDepsFor = system: zigDepsForPkgs nixpkgs.legacyPackages.${system};
  in {
    lib = {
      mkFushell = {
        pkgs,
        engineArtifacts,
        zigDeps ? zigDepsForPkgs pkgs,
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
      fixtureRevision = pkgs.flutter.engineVersion;
      fixtureEngine = mode:
        pkgs.writeText "fushell-fixture-engine-${mode}.so" ''
          fixture-${mode}
          ${fixtureRevision}
        '';
      fixtureArtifacts = {
        revision = fixtureRevision;
        debug = fixtureEngine "debug";
        profile = fixtureEngine "profile";
        release = fixtureEngine "release";
      };
      fixturePackage = engineArtifacts:
        self.lib.mkFushell {
          inherit pkgs engineArtifacts;
          zigDeps = zigDepsFor system;
          version = "fixture";
        };
      missingRevision = builtins.tryEval (
        (fixturePackage (removeAttrs fixtureArtifacts [ "revision" ])).drvPath
      );
      malformedRevision = builtins.tryEval (
        (fixturePackage (fixtureArtifacts // { revision = "INVALID"; })).drvPath
      );
      mismatchedRevision = builtins.tryEval (
        (fixturePackage (fixtureArtifacts // { revision = "0000000000000000000000000000000000000000"; })).drvPath
      );
    in {
      fushell-fixture = fixturePackage fixtureArtifacts;

      engine-artifact-contract =
        assert !missingRevision.success;
        assert !malformedRevision.success;
        assert !mismatchedRevision.success;
        pkgs.runCommand "fushell-engine-artifact-contract" {} ''
          bash ${./nix/validate-engine-artifacts.sh} \
            ${pkgs.lib.escapeShellArg fixtureRevision} \
            ${pkgs.lib.escapeShellArg (toString fixtureArtifacts.debug)} \
            ${pkgs.lib.escapeShellArg (toString fixtureArtifacts.profile)} \
            ${pkgs.lib.escapeShellArg (toString fixtureArtifacts.release)}

          if bash ${./nix/validate-engine-artifacts.sh} \
            ${pkgs.lib.escapeShellArg fixtureRevision} \
            "$TMPDIR/missing-debug.so" \
            ${pkgs.lib.escapeShellArg (toString fixtureArtifacts.profile)} \
            ${pkgs.lib.escapeShellArg (toString fixtureArtifacts.release)} \
            >"$TMPDIR/missing.log" 2>&1; then
            echo "error: missing debug artifact unexpectedly passed validation" >&2
            exit 1
          fi
          grep -qF "debug" "$TMPDIR/missing.log"
          grep -qF "$TMPDIR/missing-debug.so" "$TMPDIR/missing.log"

          invalidProfile=${pkgs.writeText "fushell-invalid-profile-engine.so" "wrong revision"}
          if bash ${./nix/validate-engine-artifacts.sh} \
            ${pkgs.lib.escapeShellArg fixtureRevision} \
            ${pkgs.lib.escapeShellArg (toString fixtureArtifacts.debug)} \
            "$invalidProfile" \
            ${pkgs.lib.escapeShellArg (toString fixtureArtifacts.release)} \
            >"$TMPDIR/mismatch.log" 2>&1; then
            echo "error: mismatched profile artifact unexpectedly passed validation" >&2
            exit 1
          fi
          grep -qF "profile" "$TMPDIR/mismatch.log"
          grep -qF ${pkgs.lib.escapeShellArg fixtureRevision} "$TMPDIR/mismatch.log"
          grep -qF "$invalidProfile" "$TMPDIR/mismatch.log"
          touch "$out"
        '';
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
