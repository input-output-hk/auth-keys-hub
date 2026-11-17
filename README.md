# auth-keys-hub

auth-keys-hub is a command-line tool to automatically fetch the authorized keys
for users of [GitHub](https://github.com) and [GitLab](https://gitlab.com).
It's designed to be executed via the `AuthorizedKeysCommand` configuration in
OpenSSH which thus grants them access.

## Features

- Retrieve public keys of individual GitHub and GitLab users
- Retrieve public keys of members of a GitHub team
- Retrieve public keys of members of a GitLab project or group
- When only users are configured, no GitHub or GitLab token is required
- Automatically updates the `authorized_keys` file when it becomes outdated
- Will still be able to work with stale data in case of a GitHub outage
- Supports command-line arguments and environment variables for configuration
- Integrates with OpenSSH's `AuthorizedKeysCommand` configuration
- Provide a fallback key for peace of mind 

## Warning

* If you do not specify local users in your configuration, access will be
  granted to any requested user including root!

* The code in this project has not been audited by any third party yet.

* For the org/team/project/group functionality, the GitHub or GitLab API is
  queried. While we can obtain up to 100 user names per query, given large
  enough teams and use of the same API key across a lot of machines, this may
  end up exhausting your quota.

* Refreshes happen every hour by default, but can be configured using the
  `--ttl` and `--force` flags. Depending on that, there may be some time
  between removing a user from a team and it actually taking effect. However,
  this can be used to alleviate quota issues.

* Authorized keys are written to /tmp by default. This leads to them being
  deleted on reboot on most setups.
  If that is an issue for you, change the location using the `--dir` flag.

## Building

The project has no dependencies other than the
[Crystal](https://crystal-lang.org/) compiler and its standard library.

At the time of writing, it works with Crystal 1.8.1 and LLVM 11.1.0.

Building has only been done on `x86_64-linux`, so feel free to open a PR for
supporting any other platforms.

### Crystal

A production version can be built with:

```sh
crystal build --release ./src/auth-keys-hub.cr
```

Please note that this will produce a dynamically linked executable, and thus has runtime dependencies.

### Nix

Build the dynamically linked version:

```sh
nix build .#auth-keys-hub
```

It's also easy to build a statically linked version for lightweight deployment with musl:

```sh
nix build .#auth-keys-hub-static
```

## Usage

### NixOS

Add this repo to your flake inputs:

    inputs.auth-keys-hub.url = "github:input-output-hk/auth-keys-hub";

Then import the module into your configuration and set your desired values.
Please read the relevant code in flake.nix to see the full list of supported options.

For example:

* The GitHub user `alice` may log in as the `developer` SSH user.
* The GitHub users of the `acme` organizations `admins` team may log in as any SSH user.
* The GitHub users of the `acme` organizations `developers` team may log in as the `developer` SSH user.

```nix
{
  imports = [
    inputs.auth-keys-hub.nixosModules.auth-keys-hub
  ];

  programs.auth-keys-hub = {
    enable = true;
    github = {
      users = ["alice:developer"];
      teams = ["acme/admins" "acme/developers:developer"];  
      tokenFile = ./tokens;
    }
  };
}
```

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

    AuthorizedKeysCommand /path/to/auth-keys-hub --github-users <your_github_username>
    AuthorizedKeysCommandUser <username>

Replace `/path/to/auth-keys-hub` with the path to the
`auth-keys-hub` script, and `<username>` with the user that will
execute the command. Then, restart the SSH service:

```sh
sudo systemctl restart sshd
```

2. Run the `auth-keys-hub` script with the desired options:

For a list of available arguments:

```sh
auth-keys-hub --help
```

## Cache and outage policy

A refresh publishes a cache only after every required GitHub team or GitLab group
membership page and every user's key request succeeds. Timeouts, non-200 responses,
invalid API JSON, and missing required tokens fail the refresh. GitLab key pages
are also fetched completely. Successful empty responses are authoritative: removed
members and keys are revoked, including replacement with an empty cache.

On refresh failure, an existing cache (including an empty cache) is served without
changing its contents or modification time. The default TTL remains one hour and
is measured from the last successful refresh. An expired cache remains eligible
for retry on the next invocation. This availability policy allows cached access to
continue throughout an upstream outage; revocations take effect at the next
successful refresh. `--force` bypasses the TTL without deleting the cache first.

The configured `--fallback` key is independent recovery access, emitted on every
authorization invocation alongside any cached keys. It remains available even
after a successful empty response, when no users match the SSH login, or when
refresh, cache reading, or file logging fails. This deliberately keeps the fallback
authorized until you remove it from configuration; upstream revocations only
revoke upstream keys. The fallback applies to every SSH login using that command.

Fallback is never written to the cache or used to restart its TTL. Changing or
removing it from configuration takes effect on the next invocation, even with a
fresh cache. Without a previous cache, a failed refresh emits only the fallback,
if configured, and leaves the next invocation eligible to retry.

This recovery path still requires the command to run and finish. For access that
also survives a command failing to start, hanging, or being terminated, configure
a recovery key directly in OpenSSH's `authorized_keys` as well.

The command exits 0 when it serves a readable cache (even an authoritative empty
one) or a nonempty configured fallback. Without either, it exits 1 with empty
stdout; previously a failed refresh could exit 0 without serving any keys.
Diagnostics go to stderr and, when available, the cache directory's `log` file.
Normal stdout contains only authorized keys.

Refreshes for the same cache serialize using a persistent `.lock` file and recheck
the TTL after acquiring the lock. Publication uses a unique temporary file in the
cache directory followed by atomic rename, so readers see a complete old or new
snapshot. Do not remove lock files while commands are running.

## Tests

Run the unit tests and offline CLI regressions in the development environment:

```sh
nix develop --command just test
```

Both suites use Crystal's standard `spec` runner. `crystal spec` runs all tests;
`just test-regressions` runs only the cache regressions. The regression suite builds
the CLI once, or uses `AUTH_KEYS_HUB_BINARY` when testing an existing binary.

The regression suite uses loopback mock endpoints, synthetic keys and tokens, and
the unchanged five-second read timeout. It covers partial failures, pagination,
cache mtime preservation and recovery, revocation, fallback, log attribution, and
concurrent refreshes. No live GitHub or GitLab credentials are needed. It also runs
as the `cache-regressions` flake check:

```sh
nix build .#checks.x86_64-linux.cache-regressions
nix build .#checks.x86_64-linux.nixos-integration
```

## License

This project is licensed under the Apache License, Version 2.0.
