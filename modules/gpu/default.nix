{ config, pkgs, lib, ... }:

{
  imports = [
    ./ollama.nix
    ./nvidia.nix
  ];
}
