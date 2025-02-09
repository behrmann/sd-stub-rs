{
  description = "systemd-stub reimplemented in Rust";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable-small";
    nixpkgs-test.url = "github:RaitoBezarius/nixpkgs/simplified-qemu-boot-disks";

    flake-parts.url = "github:hercules-ci/flake-parts";

    pre-commit-hooks-nix = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    # We only have this input to pass it to other dependencies and
    # avoid having multiple versions in our dependencies.
    flake-utils.url = "github:numtide/flake-utils";

    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-overlay.follows = "rust-overlay";
      inputs.flake-utils.follows = "flake-utils";
    };

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs = inputs@{ self, nixpkgs, nixpkgs-test, crane, rust-overlay, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } ({ moduleWithSystem, ... }: {
      imports = [
        # Derive the output overlay automatically from all packages that we define.
        inputs.flake-parts.flakeModules.easyOverlay

        # Formatting and quality checks.
        inputs.pre-commit-hooks-nix.flakeModule
      ];

      systems = [
        "x86_64-linux"

        # Not actively tested, but may work:
        # "aarch64-linux"
      ];

      perSystem = { config, system, pkgs, ... }:
        let
          pkgs = import nixpkgs {
            system = system;
            overlays = [
              rust-overlay.overlays.default
            ];
          };

          testPkgs = import nixpkgs-test { system = "x86_64-linux"; };

          rust-nightly = pkgs.rust-bin.fromRustupToolchainFile ./rust/rust-toolchain.toml;
          craneLib = crane.lib.x86_64-linux.overrideToolchain rust-nightly;

          # Build attributes for a Rust application.
          buildRustApp =
            { src
            , target ? null
            , doCheck ? true
            , extraArgs ? { }
            }:
            let
              commonArgs = {
                inherit src;
                CARGO_BUILD_TARGET = target;
                inherit doCheck;
              } // extraArgs;

              cargoArtifacts = craneLib.buildDepsOnly commonArgs;
            in
            {
              package = craneLib.buildPackage (commonArgs // {
                inherit cargoArtifacts;
              });

              clippy = craneLib.cargoClippy (commonArgs // {
                inherit cargoArtifacts;
                cargoClippyExtraArgs = "-- --deny warnings";
              });
            };

          stubCrane = buildRustApp {
            src = craneLib.cleanCargoSource ./rust;
            target = "x86_64-unknown-uefi";
            doCheck = false;
          };
        in
        {
          packages.default = stubCrane.package;

          checks = {
            clippy = stubCrane.clippy;
          };

          pre-commit = {
            check.enable = true;

            settings.hooks = {
              nixpkgs-fmt.enable = true;
              typos.enable = true;
            };
          };

          devShells.default = pkgs.mkShell {
            shellHook = ''
              ${config.pre-commit.installationScript}
            '';

            packages =
              [
                pkgs.uefi-run
                pkgs.openssl
                pkgs.sbsigntool
                pkgs.efitools
                pkgs.python39Packages.ovmfvartool
                pkgs.qemu
                pkgs.nixpkgs-fmt
                pkgs.statix
              ];

            inputsFrom = [
              config.packages.default
            ];
          };
        };
    });
}
