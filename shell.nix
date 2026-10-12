{ pkgs ? import <nixpkgs> {} }:
pkgs.mkShell {
  packages = with pkgs; [ neovim stylua luaPackages.luacheck ];
}
