{
  description = "SSH AuthorizedKeysCommand querying GitHub";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    inclusive.url = "github:input-output-hk/nix-inclusive";
    statix.url = "github:nerdypepper/statix";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    crystal.url = "github:manveru/crystal-flake";
    tullia.url = "github:input-output-hk/tullia";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux" "aarch64-darwin"];

      imports = [
        inputs.flake-parts.flakeModules.easyOverlay
        inputs.treefmt-nix.flakeModule
        inputs.tullia.flakePartsModules.default
      ];

      perSystem = {
        pkgs,
        final,
        config,
        self',
        inputs',
        ...
      }: {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with final; [
            config.treefmt.package
            statix
            watchexec
            crystal
            crystalline
            treefmt-crystal
          ];

          shellHook = ''
            ln -sf ${config.treefmt.build.configFile} treefmt.toml
          '';
        };

        packages = let
          version = "0.0.2";
          pname = "auth-keys-hub";
          format = "crystal";
          src = inputs.inclusive.lib.inclusive ./. [./src/auth-keys-hub.cr];
        in {
          default = self'.packages.auth-keys-hub;

          auth-keys-hub = final.crystal.buildCrystalPackage {
            inherit pname version format src;
            crystalBinaries.auth-keys-hub = {
              src = "src/auth-keys-hub.cr";
              options = ["--release"];
            };
          };

          auth-keys-hub-static = final.crystal.buildCrystalPackage {
            inherit pname version format src;
            doCheck = false;

            CRYSTAL_LIBRARY_PATH = pkgs.lib.makeLibraryPath (with final.pkgsStatic; [
              boehmgc
              libevent
              musl
              openssl
              pcre2
              zlib
            ]);

            crystalBinaries.auth-keys-hub = {
              src = "src/auth-keys-hub.cr";
              options = ["--release" "--no-debug" "--static"];
            };
          };
        };

        overlayAttrs = {
          inherit (inputs'.statix.packages) statix;
          inherit (self'.packages) auth-keys-hub;
          inherit (inputs'.crystal.packages) crystal crystalline treefmt-crystal;
        };

        formatter = pkgs.writeShellApplication {
          name = "treefmt";
          runtimeInputs = [config.treefmt.package];
          text = ''
            exec treefmt
          '';
        };

        treefmt = {
          programs.alejandra.enable = true;
          settings.formatter.crystal = {
            includes = ["*.cr"];
            excludes = [];
            command = "treefmt-crystal";
            options = [];
          };
          projectRootFile = "flake.nix";
        };

        tullia = {
          tasks = {
            build = {config, ...}: {
              preset = {
                nix.enable = true;
                github.ci = builtins.mapAttrs (_: pkgs.lib.mkDefault) {
                  enable = config.actionRun.facts != {};
                  repository = "input-output-hk/auth-keys-hub";
                  remote = config.preset.github.lib.readRepository "GitHub Push or PR" "";
                  revision = config.preset.github.lib.readRevision "GitHub Push or PR" "";
                };
              };

              nomad.driver = "exec";

              memory = 1024 * 8;
              nomad.resources.cpu = 3000;
              command.text = ''
                set -x
                nix build -L ".#packages.x86_64-linux.auth-keys-hub"
                nix build -L ".#packages.x86_64-linux.auth-keys-hub-static"
                nix build -L ".#packages.aarch64-darwin.auth-keys-hub"
              '';
            };
          };

          actions."auth-keys-hub/ci" = {
            task = "build";
            io = ''
              let github = {
                #input: "GitHub Push or PR"
                #repo: "input-output-hk/auth-keys-hub"
              }

              #lib.merge
              #ios: [
                #lib.io.github_push & github & {#default_branch: true},
                #lib.io.github_pr   & github,
              ]
            '';
          };
        };
      };

      flake = { config, ... }: {
        hydraJobs = builtins.mapAttrs (_: v: removeAttrs v ["default"]) config.packages;

        nixosModules.auth-keys-hub = {
          config,
          pkgs,
          lib,
          ...
        }: let
          cfg = config.programs.auth-keys-hub;
        in {
          options = {
            programs.auth-keys-hub = {
              enable = lib.mkEnableOption "auth-keys-hub";

              package = lib.mkOption {
                type = lib.types.package;
                default = pkgs.auth-keys-hub;
                description = "The derivation to use for /bin/auth-keys-hub";
              };

              user = lib.mkOption {
                type = lib.types.str;
                default = "auth-keys-hub";
                description = "The user executing the AuthorizedKeysCommand";
              };

              group = lib.mkOption {
                type = lib.types.str;
                default = "auth-keys-hub";
                description = "The group of the user executing the AuthorizedKeysCommand";
              };

              dataDir = lib.mkOption {
                type = lib.types.str;
                default = "/run/auth-keys-hub";
                description = "Directory used to cache the authorized_keys file";
              };

              ttl = lib.mkOption {
                type = lib.types.str;
                default = "1h";
                description = "how often to fetch new keys, format is 1d2h3m4s";
              };

              gitlab = {
                host = lib.mkOption {
                  type = lib.types.str;
                  default = "gitlab.com";
                  description = "Change this when using self hosted GitLab";
                };

                users = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [];
                  description = "List of GitLab user names that are allowed to login";
                };

                groups = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [];
                  description = "List of GitLab groups that are allowed to login";
                };

                tokenFile = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Read the GitLab token from this file, required when groups are used";
                };
              };

              github = {
                host = lib.mkOption {
                  type = lib.types.str;
                  default = "github.com";
                  description = "Change this when using GitHub Enterprise";
                };

                users = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [];
                  description = "List of GitHub user names that are allowed to login";
                };

                teams = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [];
                  description = "list of org/team that are allowed access (e.g. acme/ops)";
                };

                tokenFile = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Read the GitHub token from this file, required when org/team is used";
                };
              };
            };
          };

          config = lib.mkIf cfg.enable (let
            join = builtins.concatStringsSep ",";

            flags = lib.cli.toGNUCommandLine {} {
              inherit (cfg) ttl;
              dir = cfg.dataDir;

              github-host = cfg.github.host;
              github-users = join cfg.github.users;
              github-teams = join cfg.github.teams;
              github-token-file = cfg.github.tokenFile;

              gitlab-host = cfg.gitlab.host;
              gitlab-users = join cfg.gitlab.users;
              gitlab-groups = join cfg.gitlab.groups;
              gitlab-token-file = cfg.gitlab.tokenFile;
            };
          in {
            assertions = [
              {
                assertion = cfg.github.teams == [] || cfg.github.tokenFile != null;
                message = "programs.auth-keys-hub.github.teams requires tokenFile to be set as well";
              }
            ];

            users.users.${cfg.user} = {
              description = "auth-keys-hub user";
              isSystemUser = true;
              inherit (cfg) group;
            };

            users.groups.${cfg.group} = {};

            systemd.tmpfiles.rules = ["d ${cfg.dataDir} 0700 ${cfg.user} ${cfg.group} - -"];

            environment.etc."ssh/auth-keys-hub" = {
              mode = "0755";
              text = ''
                #!${pkgs.bash}/bin/bash
                exec ${cfg.package}/bin/auth-keys-hub ${lib.escapeShellArgs flags}
              '';
            };

            services.openssh = {
              authorizedKeysCommand = "/etc/ssh/auth-keys-hub";
              authorizedKeysCommandUser = cfg.user;
            };
          });
        };
      };
    };
}
