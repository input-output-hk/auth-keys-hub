# auth-keys-hub


auth-keys-hub is a command-line tool to automatically fetch the authorized keys
for GitHub users and teams. It's designed to be executed via the
`AuthorizedKeysCommand` configuration in OpenSSH. It fetches the public keys of
specified GitHub users or a team within an organization and grants them access.

## Features

- Retrieve public keys of individual GitHub users or a team within an organization
- When only users are configured, no GitHub token is required
- Automatically updates the `authorized_keys` file when it becomes outdated
- Will still be able to work with stale data in case of a GitHub outage
- Supports command-line arguments and environment variables for configuration
- Integrates with OpenSSH's `AuthorizedKeysCommand` configuration

## Warning

* Please note that this will grant access to ANY user on the machine, as long as that user exists!
  That means there is no additional verification needed to become root!
  While we may provide a way to explicitly map machine users to github users in the future,
  this hasn't been a requirement for our use-case and thus not implemented.

* The code in this project has not been audited by any third party yet.

* For the org/team functionality, the GitHub API is queried.
  While we can obtain up to 100 user names per query, given large enough teams and
  use of the same API key across a lot of machines, this may end up exhausting your quota.

* Refreshes happen every hour by default, but can be configured using the `--ttl` and `--force` flags.
  Depending on that, there may be some time between removing a user from a team and it actually taking effect.

## Building

The project has no dependencies other than the
[Crystal](https://crystal-lang.org/) compiler and its standard library.

At the time of writing, it works with Crystal 1.8.1 and LLVM 11.1.0.

Building has only been done on `x86_64-linux`, so feel free to open a PR for
supporting any other platforms.

### Crystal

A production version can be built with:

    crystal build --release ./src/auth-keys-hub.cr

Please note that this will produce a dynamically linked executable, and thus has runtime dependencies.

### Nix

Build the dynamically linked version:

    nix build .#auth-keys-hub

It's also easy to build a statically linked version for lightweight deployment with musl:

    nix build .#auth-keys-hub-static

## Usage

### NixOS

Add this repo to your flake inputs:

    inputs.auth-keys-hub.url = "github:input-output-hk/auth-keys-hub";

Then import the module into your configuration and set your desired values.
Please read the relevant code in flake.nix to see the full list of supported options.

For example, allow the GitHub user `alice` to log into the machine,
and also any user in the `bobs` team of the `acme` organization:

    {
      imports = [
        inputs.auth-keys-hub.nixosModules.auth-keys-hub
      ];

      programs.auth-keys-hub = {
        enable = true;
        github = {
          users = ["alice"];
          teams = ["acme/bobs"];  
          tokenFile = ./tokens;
        }
      };
    }

For managing the `tokenFile` we recommend solutions like
[sops-nix](https://github.com/Mic92/sops-nix) or
[agenix](https://github.com/ryantm/agenix), but also take a look at the
[Comparison of secret managing schemes](https://nixos.wiki/wiki/Comparison_of_secret_managing_schemes)
in the NixOS Wiki.

### Manual

Please be aware of the limitations placed on the command and read the relevant
sections of the `sshd_config(5)` manpage. In particular:

  * The program must be owned by root, not writable by group or others and specified by an absolute path.
  * If `AuthorizedKeysCommand` is specified but `AuthorizedKeysCommandUser` is not, then `sshd(8)` will refuse to start.

1. Configure OpenSSH to use `auth-keys-hub` as the `AuthorizedKeysCommand`:

Add the following line to your `/etc/ssh/sshd_config` file:

    AuthorizedKeysCommand /path/to/auth-keys-hub --users <your_github_username>
    AuthorizedKeysCommandUser <username>

Replace `/path/to/auth-keys-hub` with the path to the
`auth-keys-hub` script, and `<username>` with the user that will
execute the command. Then, restart the SSH service:

    sudo systemctl restart sshd

2. Run the `auth-keys-hub` script with the desired options:

For a list of available arguments:

    auth-keys-hub --help

## License

This project is licensed under the Apache License, Version 2.0.
