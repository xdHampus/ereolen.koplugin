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
        ereolenWrapperLua = ereolenWrapper-flake.packages.${system}.ereolenWrapperLua;
        ereolen-kopluginDrv = pkgs.callPackage ./default.nix {
          inherit ereolenWrapperLua;
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
        };
      });
}
