{
  description = "SSH AuthorizedKeysCommand querying GitHub";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    inclusive.url = "github:input-output-hk/nix-inclusive";
    statix.url = "github:nerdypepper/statix";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    crystal.url = "github:manveru/crystal-flake";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux" "aarch64-darwin"];

      imports = [
        inputs.treefmt-nix.flakeModule
      ];

      perSystem = {
        config,
        pkgs,
        lib,
        inputs',
        ...
      }: {
        devShells.default = pkgs.mkShell {
          packages =
            (with inputs'; [
              crystal.packages.crystal
              crystal.packages.crystalline
              crystal.packages.treefmt-crystal
              statix.packages.statix
            ])
            ++ (with pkgs; [
              watchexec
            ]);

          shellHook = ''
            ln -sf ${config.treefmt.build.configFile} treefmt.toml
          '';
        };

        packages = let
          version = "0.0.2";
          pname = "auth-keys-hub";
          format = "crystal";
          src = inputs.inclusive.lib.inclusive ./. [src/auth-keys-hub.cr];
        in {
          default = config.packages.auth-keys-hub;

          auth-keys-hub = inputs'.crystal.packages.crystal.buildCrystalPackage {
            inherit pname version format src;
            crystalBinaries.auth-keys-hub = {
              src = "src/auth-keys-hub.cr";
              options = ["--release"];
            };
          };

          auth-keys-hub-static = inputs'.crystal.packages.crystal.buildCrystalPackage {
            inherit pname version format src;
            doCheck = false;

            CRYSTAL_LIBRARY_PATH = pkgs.lib.makeLibraryPath (with pkgs.pkgsStatic; [
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

        treefmt = {
          programs.alejandra.enable = true;
          settings.formatter.crystal = {
            includes = ["*.cr"];
            excludes = [];
            command = lib.getExe inputs'.crystal.packages.treefmt-crystal;
            options = [];
          };
          projectRootFile = "flake.nix";
        };
      };

      flake = {config, ...}: {
        hydraJobs =
          builtins.mapAttrs
          (
            system: v: let
              jobs = removeAttrs v ["default"];
            in
              jobs
              // {
                required = inputs.nixpkgs.legacyPackages.${system}.releaseTools.aggregate {
                  name = "required";
                  constituents = builtins.attrValues jobs;
                };
              }
          )
          config.packages;

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
