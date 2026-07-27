{
  description = "KOReader plugin for interacting with eReolen.dk";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    ereolenWrapper-flake.url = "github:xdHampus/ereolenWrapper/main";
    utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, ereolenWrapper-flake, utils, ... }@inputs:
    utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        inherit (pkgs) lib;
        ereolenWrapperLua = ereolenWrapper-flake.packages.${system}.ereolenWrapperLua;
        ereolen-kopluginDrv = pkgs.callPackage ./default.nix {
          inherit ereolenWrapperLua;
        };

        # The same Lua with the ARM wrapper, ready to copy onto a device. Only
        # on x86_64-linux, which is where the cross-toolchain release exists.
        koboDrv = pkgs.callPackage ./kobo.nix {
          ereolenWrapperKobo = ereolenWrapper-flake.packages.${system}.kobo;
        };
      in {
        devShells.default = pkgs.mkShell rec {
          name = "ereolen.koplugin";
          packages = [
            ereolenWrapperLua
            pkgs.lua5_1
            pkgs.koreader
          ];
        };
        packages = {
          default = ereolen-kopluginDrv;
          ereolen-koplugin = ereolen-kopluginDrv;
        } // lib.optionalAttrs (system == "x86_64-linux") {
          kobo = koboDrv;
        };
      });
}
