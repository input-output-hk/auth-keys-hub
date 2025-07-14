{
  description = "SSH AuthorizedKeysCommand querying GitHub";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    inclusive.url = "github:input-output-hk/nix-inclusive";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux" "x86_64-darwin" "aarch64-darwin" "aarch64-linux"];

      imports = [
        inputs.treefmt-nix.flakeModule
      ];

      perSystem = {
        config,
        pkgs,
        lib,
        inputs',
        system,
        ...
      }: {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            crystal
            crystalline
            watchexec
            statix
            just
            pkg-config
            openssl
            pcre
          ];

          shellHook = ''
            ln -sf ${config.treefmt.build.configFile} treefmt.toml
          '';
        };

        packages = {
          default = config.packages.auth-keys-hub;

          auth-keys-hub = pkgs.crystal.buildCrystalPackage rec {
            version = "0.1.0";
            pname = "auth-keys-hub";
            format = "crystal";
            src = inputs.inclusive.lib.inclusive ./. [src/auth-keys-hub.cr];

            nativeBuildInputs = [
              pkgs.pkg-config
            ];

            buildInputs = [pkgs.openssl];

            doInstallCheck = false;

            crystalBinaries.auth-keys-hub = {
              src = "src/auth-keys-hub.cr";
              options = ["--release"];
            };

            meta.mainProgram = pname;
          };
        };

        treefmt = {
          programs.alejandra.enable = true;
          settings.formatter.crystal = {
            includes = ["*.cr"];
            excludes = [];
            command = "${pkgs.crystal}/bin/crystal";
            options = ["tool" "format"];
          };
          projectRootFile = "flake.nix";
        };
      };

      flake = {
        config,
        lib,
        pkgs,
        ...
      }: let
        commonModule = {
          config,
          lib,
          ...
        }: let
          cfg = config.programs.auth-keys-hub;
        in {
          options.programs.auth-keys-hub = {
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

            fallback = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Key used in case of failure";
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

            flags = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              readOnly = true;
              default = let
                cfg = config.programs.auth-keys-hub;

                join = list:
                  if list == []
                  then null
                  else builtins.concatStringsSep "," list;
              in
                lib.cli.toGNUCommandLine {} {
                  github-host = cfg.github.host;
                  github-teams = join cfg.github.teams;
                  github-token-file = cfg.github.tokenFile;
                  github-users = join cfg.github.users;

                  gitlab-groups = join cfg.gitlab.groups;
                  gitlab-host = cfg.gitlab.host;
                  gitlab-token-file = cfg.gitlab.tokenFile;
                  gitlab-users = join cfg.gitlab.users;

                  dir = cfg.dataDir;
                  inherit (cfg) ttl fallback;
                };
            };
          };

          config = lib.mkIf cfg.enable {
            assertions = [
              # Prevent lockout from misconfigured github teams
              {
                assertion = cfg.github.teams != [] -> cfg.github.tokenFile != null;
                message = "programs.auth-keys-hub.github.teams requires tokenFile to be set as well";
              }
              # Prevent lockout from misconfigured gitlab groups
              {
                assertion = cfg.gitlab.groups != [] -> cfg.gitlab.tokenFile != null;
                message = "programs.auth-keys-hub.gitlab.groups requires tokenFile to be set as well";
              }
              # Prevent lockouts from not configuring any keys, ex: fail2ban breaking existing conns on a subsequent ssh attempt
              {
                assertion = ! (cfg.github.teams == [] && cfg.github.users == [] && cfg.gitlab.groups == [] && cfg.gitlab.users == []);
                message = "programs.auth-keys-hub requires declaring at least one github or gitlab user, group or team to avoid unintentional lockouts";
              }
            ];

            warnings =
              # Prevent lockout from local or upstream token breakage
              lib.optional ((cfg.github.teams != [] && cfg.github.users == []) || (cfg.gitlab.groups != [] && cfg.gitlab.users == []))
              "programs.auth-keys-hub recommends declaring at least 1 github or gitlab user when github teams or gitlab groups are used"
              ++
              # Prevent lockout from other edge cases, ex: a) removal of auth-keys-hub module without setting up keys; b) bugs; c) tail events, etc
              lib.optional (
                builtins.all (l: l == []) (map (user: config.users.users.${user}.openssh.authorizedKeys.keys) (builtins.attrNames config.users.users))
                && builtins.all (l: l == []) (map (user: config.users.users.${user}.openssh.authorizedKeys.keyFiles) (builtins.attrNames config.users.users))
              ) "programs.auth-keys-hub recommends declaring at least 1 authorized key or key file via users.users.*.openssh.authorizedKeys attributes";
          };
        };
      in {
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
          imports = [commonModule];

          config = lib.mkIf cfg.enable {
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
                #!${lib.getExe pkgs.dash}
                exec ${lib.getExe cfg.package} ${lib.escapeShellArgs cfg.flags} "$@"
              '';
            };

            services.openssh = {
              authorizedKeysCommand = "/etc/ssh/auth-keys-hub --user %u";
              authorizedKeysCommandUser = cfg.user;
            };
          };
        };

        darwinModules.auth-keys-hub = {
          config,
          pkgs,
          lib,
          ...
        }: let
          cfg = config.programs.auth-keys-hub;
        in {
          imports = [commonModule];

          config = lib.mkIf cfg.enable {
            assertions = [
              {
                assertion = builtins.elem "auth-keys-hub" config.users.knownUsers;
                message = "set users.knownUsers to enable the auth-keys-hub user";
              }
              {
                assertion = builtins.elem "auth-keys-hub" config.users.knownGroups;
                message = "set users.knownGroups to enable the auth-keys-hub group";
              }
            ];

            users = {
              users.${cfg.user} = {
                description = "auth-keys-hub user";
                isHidden = true;
                uid = lib.mkDefault 503;
                gid = lib.mkDefault config.users.groups.${cfg.group}.gid;
              };

              groups.${cfg.group} = {
                description = "auth-keys-hub group";
                gid = lib.mkDefault 503;
              };
            };

            environment.etc = {
              # Needs to be lexicographically ordered before `101-authorized-keys.conf` by nix-darwin.
              "ssh/sshd_config.d/100-auth-keys-hub.conf".text = ''
                # Cannot call the script directly on systems where /nix/store has too open permissions,
                # which could be the case when it is a symlink or on another disk, for example.
                AuthorizedKeysCommand /bin/sh /etc/${config.environment.etc."ssh/auth-keys-hub".target} %u
                AuthorizedKeysCommandUser ${cfg.user}
              '';

              "ssh/auth-keys-hub".source = pkgs.writeScript "auth-keys-hub" ''
                #!${lib.getExe pkgs.dash}

                [ "$#" -eq 1 ] || {
                  echo >&2 "$0: error: Expected only one argument (the target user) but got $#."
                  exit 1
                }

                # As we are overriding the `AuthorizedKeysCommand` set by nix-darwin
                # (since https://github.com/nix-darwin/nix-darwin/pull/976)
                # we need to do its job as well to avoid breaking the implementation of
                # `users.users.<name>.openssh.authorizedKeys`.
                # For nix-darwin installations since before that PR
                # this directory does not exist, let's just ignore it then.
                cat /etc/ssh/nix_authorized_keys.d/"$1" || :

                export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
                exec ${lib.getExe cfg.package} ${lib.escapeShellArgs cfg.flags} --user "$1" 2>/dev/null
              '';
            };

            system.activationScripts.preActivation.text = ''
              # prepare auth-keys-hub data directory
              mkdir -p ${lib.escapeShellArg cfg.dataDir}
              chown ${toString config.users.users.${cfg.user}.uid}:${toString config.users.groups.${cfg.group}.gid} ${lib.escapeShellArg cfg.dataDir}
              chmod 0700 ${lib.escapeShellArg cfg.dataDir}
            '';
          };
        };
      };
    };
}
