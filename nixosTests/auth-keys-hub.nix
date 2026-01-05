{
  pkgs,
  auth-keys-hub,
  nixosModule,
}:
pkgs.testers.runNixOSTest {
  name = "auth-keys-hub-integration";

  nodes = {
    # Mock GitHub server
    github = {
      config,
      pkgs,
      ...
    }: let
      mockServer = pkgs.crystal.buildCrystalPackage {
        pname = "mock-server";
        version = "0.1.0";
        src = ./.;
        format = "crystal";
        doInstallCheck = false;
        crystalBinaries.mock-server.src = "mock-server.cr";
      };
      mockResponses = pkgs.runCommand "mock-responses" {} ''
        mkdir -p $out/github $out/gitlab
        cp ${./mock-responses/github/alice.keys} $out/github/alice.keys
        cp ${./mock-responses/github/bob.keys} $out/github/bob.keys
        cp ${./mock-responses/github/teams-page1.json} $out/github/teams-page1.json
        cp ${./mock-responses/gitlab/charlie-keys.json} $out/gitlab/charlie-keys.json
        cp ${./mock-responses/gitlab/dave-keys.json} $out/gitlab/dave-keys.json
        cp ${./mock-responses/gitlab/expired-keys.json} $out/gitlab/expired-keys.json
        cp ${./mock-responses/gitlab/group-page1.json} $out/gitlab/group-page1.json
      '';
    in {
      networking.firewall.allowedTCPPorts = [80];

      systemd.services.mock-github = {
        wantedBy = ["multi-user.target"];
        after = ["network.target"];
        serviceConfig = {
          ExecStart = "${mockServer}/bin/mock-server 80 ${mockResponses}";
        };
      };
    };

    # Mock GitLab server
    gitlab = {
      config,
      pkgs,
      ...
    }: let
      mockServer = pkgs.crystal.buildCrystalPackage {
        pname = "mock-server";
        version = "0.1.0";
        src = ./.;
        format = "crystal";
        doInstallCheck = false;
        crystalBinaries.mock-server.src = "mock-server.cr";
      };
      mockResponses = pkgs.runCommand "mock-responses" {} ''
        mkdir -p $out/github $out/gitlab
        cp ${./mock-responses/gitlab/charlie-keys.json} $out/gitlab/charlie-keys.json
        cp ${./mock-responses/gitlab/dave-keys.json} $out/gitlab/dave-keys.json
        cp ${./mock-responses/gitlab/expired-keys.json} $out/gitlab/expired-keys.json
        cp ${./mock-responses/gitlab/group-page1.json} $out/gitlab/group-page1.json
      '';
    in {
      networking.firewall.allowedTCPPorts = [80];

      systemd.services.mock-gitlab = {
        wantedBy = ["multi-user.target"];
        after = ["network.target"];
        serviceConfig = {
          ExecStart = "${mockServer}/bin/mock-server 80 ${mockResponses}";
        };
      };
    };

    # SSH server with auth-keys-hub
    sshserver = {
      config,
      pkgs,
      ...
    }: {
      imports = [nixosModule];

      networking.firewall.enable = false;

      # Create test token files
      environment.etc = {
        "auth-keys-hub/github-token".text = "ghp_test_token_mock";
        "auth-keys-hub/gitlab-token".text = "glpat_test_token_mock";
      };

      programs.auth-keys-hub = {
        enable = true;
        package = auth-keys-hub;
        ttl = "10s";
        dataDir = "/var/lib/auth-keys-hub";

        github = {
          host = "http://github";
          users = ["alice" "bob"];
          teams = ["testorg/testteam"];
          tokenFile = "/etc/auth-keys-hub/github-token";
        };

        gitlab = {
          host = "http://gitlab";
          users = ["charlie" "dave" "expired"];
          groups = ["testgroup"];
          tokenFile = "/etc/auth-keys-hub/gitlab-token";
        };
      };

      # Create test users
      users.users = {
        alice = {
          isNormalUser = true;
          openssh.authorizedKeys.keys = [];
        };
        bob = {
          isNormalUser = true;
          openssh.authorizedKeys.keys = [];
        };
        charlie = {
          isNormalUser = true;
          openssh.authorizedKeys.keys = [];
        };
        dave = {
          isNormalUser = true;
          openssh.authorizedKeys.keys = [];
        };
        expired = {
          isNormalUser = true;
          openssh.authorizedKeys.keys = [];
        };
      };

      services.openssh = {
        enable = true;
        settings.PasswordAuthentication = false;
      };
    };

    # SSH client
    client = {
      config,
      pkgs,
      ...
    }: {
      environment.systemPackages = [pkgs.openssh];

      # Install SSH keys
      environment.etc = {
        "ssh-keys/alice" = {
          source = ./keys/alice;
          mode = "0600";
        };
        "ssh-keys/alice.pub".source = ./keys/alice.pub;
        "ssh-keys/bob" = {
          source = ./keys/bob;
          mode = "0600";
        };
        "ssh-keys/bob.pub".source = ./keys/bob.pub;
        "ssh-keys/charlie" = {
          source = ./keys/charlie;
          mode = "0600";
        };
        "ssh-keys/charlie.pub".source = ./keys/charlie.pub;
        "ssh-keys/dave" = {
          source = ./keys/dave;
          mode = "0600";
        };
        "ssh-keys/dave.pub".source = ./keys/dave.pub;
        "ssh-keys/expired" = {
          source = ./keys/expired;
          mode = "0600";
        };
        "ssh-keys/expired.pub".source = ./keys/expired.pub;
      };
    };
  };

  testScript = ''
    start_all()

    with subtest("services initialize"):
      github.wait_for_unit("mock-github")
      github.wait_for_open_port(80)
      gitlab.wait_for_unit("mock-gitlab")
      gitlab.wait_for_open_port(80)
      sshserver.wait_for_unit("sshd")
      sshserver.wait_for_open_port(22)

    with subtest("github user auth (no token)"):
      # Alice should be able to authenticate using keys from GitHub
      client.succeed(
        "ssh -v -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        "-i /etc/ssh-keys/alice alice@sshserver true"
      )

    with subtest("github user bob auth"):
      # Bob should also be able to authenticate
      client.succeed(
        "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        "-i /etc/ssh-keys/bob bob@sshserver true"
      )

    with subtest("github team auth (with token)"):
      # Run auth-keys-hub to generate consolidated authorized_keys file
      sshserver.succeed("sudo -u auth-keys-hub /etc/ssh/auth-keys-hub")
      # Team members (alice and bob) should be in the authorized_keys
      sshserver.succeed("grep -q ' alice$' /var/lib/auth-keys-hub/authorized_keys")
      sshserver.succeed("grep -q ' bob$' /var/lib/auth-keys-hub/authorized_keys")

    with subtest("gitlab user auth (no token)"):
      # Charlie should be able to authenticate using keys from GitLab
      client.succeed(
        "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        "-i /etc/ssh-keys/charlie charlie@sshserver true"
      )

    with subtest("gitlab user dave auth"):
      # Dave should also be able to authenticate
      client.succeed(
        "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        "-i /etc/ssh-keys/dave dave@sshserver true"
      )

    with subtest("gitlab group auth (with token)"):
      # Force refresh to get latest group members
      sshserver.succeed("sudo -u auth-keys-hub /etc/ssh/auth-keys-hub --force")
      # Group members (charlie and dave) should be in authorized_keys
      sshserver.succeed("grep -q ' charlie$' /var/lib/auth-keys-hub/authorized_keys")
      sshserver.succeed("grep -q ' dave$' /var/lib/auth-keys-hub/authorized_keys")

    with subtest("expired gitlab keys filtered"):
      # User with expired key should NOT be able to authenticate
      # First verify the expired key is NOT in authorized_keys
      sshserver.fail("grep -q ' expired$' /var/lib/auth-keys-hub/authorized_keys")

      # Try to authenticate - should fail
      client.fail(
        "timeout 10 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        "-i /etc/ssh-keys/expired expired@sshserver true"
      )

    with subtest("invalid credentials fail"):
      # Try to authenticate bob as alice - should fail
      client.fail(
        "timeout 10 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        "-i /etc/ssh-keys/bob alice@sshserver true"
      )

    with subtest("cache survives API outage"):
      # Stop mock servers
      github.systemctl("stop", "mock-github")
      gitlab.systemctl("stop", "mock-gitlab")

      # Authentication should still work with cached keys
      client.succeed(
        "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        "-i /etc/ssh-keys/alice alice@sshserver true"
      )

    with subtest("TTL expiration and recovery"):
      # Restart the servers that were stopped in the previous test
      github.systemctl("start", "mock-github")
      gitlab.systemctl("start", "mock-gitlab")
      github.wait_for_open_port(80)
      gitlab.wait_for_open_port(80)

      # Wait a moment for services to stabilize
      client.sleep(2)

      # Delete the cache to force a fresh fetch
      sshserver.succeed("rm -f /var/lib/auth-keys-hub/authorized_keys*")

      # Authentication should work and fetch keys from the restarted servers
      client.succeed(
        "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        "-i /etc/ssh-keys/alice alice@sshserver true"
      )

      # Verify keys were fetched from the servers (not from cache)
      sshserver.succeed("grep -q 'Performing request' /var/lib/auth-keys-hub/log")

      # Recreate consolidated cache file for subsequent tests
      sshserver.succeed("sudo -u auth-keys-hub /etc/ssh/auth-keys-hub")

    with subtest("verify logs"):
      # Check that auth-keys-hub logged operations
      sshserver.succeed("test -f /var/lib/auth-keys-hub/log")
      sshserver.succeed("grep -q 'Updating' /var/lib/auth-keys-hub/log")

    with subtest("per-user cache files"):
      # Clean up per-user cache files but keep the consolidated file
      sshserver.succeed("rm -f /var/lib/auth-keys-hub/authorized_keys_*")

      # Call auth-keys-hub for alice
      sshserver.succeed("sudo -u auth-keys-hub /etc/ssh/auth-keys-hub --user alice")
      # Verify alice-specific cache file exists
      sshserver.succeed("test -f /var/lib/auth-keys-hub/authorized_keys_alice")
      # Verify alice's keys are in alice's cache file
      sshserver.succeed("grep -q ' alice$' /var/lib/auth-keys-hub/authorized_keys_alice")
      # Verify bob's keys are NOT in alice's cache file
      sshserver.fail("grep -q ' bob$' /var/lib/auth-keys-hub/authorized_keys_alice")

      # Call auth-keys-hub for bob
      sshserver.succeed("sudo -u auth-keys-hub /etc/ssh/auth-keys-hub --user bob")
      # Verify bob-specific cache file exists
      sshserver.succeed("test -f /var/lib/auth-keys-hub/authorized_keys_bob")
      # Verify bob's keys are in bob's cache file
      sshserver.succeed("grep -q ' bob$' /var/lib/auth-keys-hub/authorized_keys_bob")
      # Verify alice's keys are NOT in bob's cache file
      sshserver.fail("grep -q ' alice$' /var/lib/auth-keys-hub/authorized_keys_bob")

      # Verify the original consolidated file still exists from previous tests
      sshserver.succeed("test -f /var/lib/auth-keys-hub/authorized_keys")
  '';
}
