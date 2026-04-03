{ config, pkgs, lib, ... }:

let
  cfg = config.claude-os.nvidia;
in
{
  options.claude-os.nvidia = {
    enable = lib.mkEnableOption "NVIDIA GPU support with CUDA";
  };

  config = lib.mkIf cfg.enable {
    # NVIDIA proprietary driver
    hardware.nvidia = {
      open = false;
      modesetting.enable = true;
      nvidiaSettings = true;
    };

    # Enable 32-bit support (required by NVIDIA docker integration)
    hardware.graphics.enable32Bit = true;

    services.xserver.videoDrivers = [ "nvidia" ];

    environment.systemPackages = with pkgs; [
      cudaPackages.cudatoolkit
      cudaPackages.cudnn
      nvtopPackages.full
      pciutils
    ];

    environment.variables = {
      CUDA_PATH = "${pkgs.cudaPackages.cudatoolkit}";
    };

    # Docker with NVIDIA GPU support
    virtualisation.docker = {
      enable = true;
      enableNvidia = true;
    };

    # Override ollama to use CUDA-accelerated package
    services.ollama.package = lib.mkForce pkgs.ollama-cuda;
  };
}
