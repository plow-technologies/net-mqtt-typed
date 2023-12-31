{
  inputs.haskellNix.url = "github:input-output-hk/haskell.nix";
  inputs.nixpkgs.follows = "haskellNix/nixpkgs-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.devour-flake.url = "github:srid/devour-flake";
  inputs.devour-flake.flake = false;
  outputs = inputs @ { self, nixpkgs, flake-utils, haskellNix, ... }:
    let
      supportedSystems = [
        "x86_64-linux"
        #"aarch64-linux"
        #"x86_64-darwin"
        #"aarch64-darwin"
      ];
    in
      flake-utils.lib.eachSystem supportedSystems (system:
      let
        overlays = [ haskellNix.overlay
          (final: prev: builtins.mapAttrs (name: compiler-nix-name:
              (final.haskell-nix.cabalProject' {
                inherit compiler-nix-name;
                src = ./.;
                name = "net-mqtt-typed";
                shell.tools.cabal = "latest";
                shell.exactDeps = false;
              })) {
                hsProject884 = "ghc884";
                hsProject924 = "ghc924";
                hsProject981 = "ghc981";
              })
          (final: prev: {
            devour-flake = final.callPackage inputs.devour-flake {};
          })
        ];
        pkgs = import nixpkgs { inherit system overlays; inherit (haskellNix) config; };
        flake884 = pkgs.hsProject884.flake {};
        flake924 = pkgs.hsProject924.flake {};
        flake981 = pkgs.hsProject981.flake {};

        addPrefix = prefix: pkgs.lib.mapAttrs' (name: value: {
          inherit value;
          name = "${prefix}${name}";
        });
      in {
        legacyPackages = pkgs;
        devShells = flake981.devShells //
          (addPrefix "ghc884-" flake884.devShells) //
          (addPrefix "ghc924-" flake924.devShells) //
          (addPrefix "ghc981-" flake981.devShells);
        packages = {
          default = flake981.packages."net-mqtt-typed-pubsub:exe:net-mqtt-typed-demo";
          } //
          (addPrefix "ghc884-" flake884.packages)  //
          (addPrefix "ghc924-" flake924.packages)  //
          (addPrefix "ghc981-" flake981.packages);
        apps.buildAll = flake-utils.lib.mkApp {
          drv = pkgs.writeShellApplication {
            name = "nix-build-all";
            runtimeInputs = [
              pkgs.nix
              pkgs.devour-flake
            ];
            text = ''
              # Make sure that flake.lock is sync
              nix flake lock --no-update-lock-file

              # Do a full nix build (all outputs)
              # This uses https://github.com/srid/devour-flake
              devour-flake . "$@"
            '';
          };
        };
      });

  # --- Flake Local Nix Configuration ----------------------------
  nixConfig = {
    # This sets the flake to use the IOG nix cache.
    # Nix should ask for permission before using it,
    # but remove it here if you do not want it to.
    extra-substituters = ["https://cache.iog.io"];
    extra-trusted-public-keys = ["hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="];
    allow-import-from-derivation = "true";
  };
}
