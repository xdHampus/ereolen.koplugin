{
  description = "KOReader plugin for interacting with eReolen.dk";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-master.url = "github:NixOS/nixpkgs/master";
    ereolenWrapper-flake.url = "github:xdHampus/ereolenWrapper/main";
    utils.url = "github:numtide/flake-utils";
    utils.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nixpkgs-master, ereolenWrapper-flake, utils, ... }@inputs:
    utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { config.allowUnfree = true; inherit system; };
        pkgsUnstable = import nixpkgs-master { config.allowUnfree = true; inherit system; };       
        ereolen-kopluginDrv = pkgs.callPackage ./default.nix {
			ereolenWrapperLua = ereolenWrapper-flake.packages.${system}.ereolenWrapperLua;
        };
      in {
        devShell = pkgs.mkShell rec {
          name = "ereolen.koplugin";
          packages = with pkgs; [
			ereolenWrapper-flake.packages.${system}.ereolenWrapperLua
          ];
        };
		defaultPackage = ereolen-kopluginDrv;
        packages = {
          ereolen-koplugin = ereolen-kopluginDrv;
        };
      });
}
