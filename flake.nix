{
  description = "Claude-OS: AI-native operating system with Claude as the primary interface";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
    let
      # Helper to build a claude-os NixOS configuration for a given arch
      mkClaudeOS = { system, enableGpu ? false }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            ./modules/base
            ./modules/state
            ./modules/shell-agent

            # Enable QEMU VM build support
            ({ modulesPath, ... }: {
              imports = [ "${modulesPath}/virtualisation/qemu-vm.nix" ];
              virtualisation = {
                memorySize = 4096;
                cores = 4;
                diskSize = 20480;
                graphics = false; # Headless — SSH in
                forwardPorts = [
                  { from = "host"; host.port = 2222; guest.port = 22; }
                ];
              };
            })

            # Per-arch overrides
            ({ ... }: {
              nixpkgs.config.allowUnfree = true;
            })

            # Phase 2: Master agent + MCP servers
            ./modules/master-agent
            ./modules/mcp-servers

            # Phase 3+:
            # ./modules/capability-manager
            # ./modules/skills
            # ./modules/memory
            # ./modules/awareness
          ]
          # GPU module only for x86_64 (NVIDIA/CUDA)
          ++ nixpkgs.lib.optionals enableGpu [
            # ./modules/gpu
          ];
        };
    in
    {
      # === NixOS Configurations ===

      # Development target: aarch64-linux (fast builds on arm64 Mac)
      nixosConfigurations.claude-os-dev = mkClaudeOS {
        system = "aarch64-linux";
        enableGpu = false;
      };

      # Production target: x86_64-linux (NVIDIA/CUDA support)
      nixosConfigurations.claude-os = mkClaudeOS {
        system = "x86_64-linux";
        enableGpu = true;
      };

      # === Packages ===

      # Dev VM (aarch64-linux) — fast local testing
      packages.aarch64-linux.vm = self.nixosConfigurations.claude-os-dev.config.system.build.vm;
      packages.aarch64-linux.default = self.packages.aarch64-linux.vm;

      # Production VM (x86_64-linux) — full GPU stack
      packages.x86_64-linux.vm = self.nixosConfigurations.claude-os.config.system.build.vm;
      packages.x86_64-linux.default = self.packages.x86_64-linux.vm;

      # === Dev Shells ===

      devShells.aarch64-darwin.default = let
        pkgs = import nixpkgs { system = "aarch64-darwin"; };
      in pkgs.mkShell {
        packages = with pkgs; [ qemu ];
      };

      devShells.x86_64-darwin.default = let
        pkgs = import nixpkgs { system = "x86_64-darwin"; };
      in pkgs.mkShell {
        packages = with pkgs; [ qemu ];
      };
    };
}
