require "spec"
require "file_utils"
require "../src/auth-keys-hub"

describe "parse_time_span" do
  it "parses hours correctly" do
    parse_time_span("1h").should eq Time::Span.new(hours: 1)
  end

  it "parses minutes correctly" do
    parse_time_span("30m").should eq Time::Span.new(minutes: 30)
  end

  it "parses seconds correctly" do
    parse_time_span("45s").should eq Time::Span.new(seconds: 45)
  end

  it "parses days correctly" do
    parse_time_span("2d").should eq Time::Span.new(days: 2)
  end

  it "parses combined format" do
    span = parse_time_span("1d2h3m4s")
    span.should eq Time::Span.new(days: 1, hours: 2, minutes: 3, seconds: 4)
  end

  it "handles empty components" do
    span = parse_time_span("1d3m")
    span.should eq Time::Span.new(days: 1, minutes: 3)
  end

  it "raises on invalid format" do
    expect_raises(Exception, "invalid timespan") do
      parse_time_span("invalid")
    end
  end
end

describe AuthKeysHub do
  describe "#file" do
    it "returns generic path without login_user" do
      akh = AuthKeysHub.new
      akh.dir = Path.new("/tmp/test")
      akh.file.should eq Path.new("/tmp/test/authorized_keys")
    end

    it "returns user-specific path with login_user" do
      akh = AuthKeysHub.new
      akh.dir = Path.new("/tmp/test")
      akh.login_user = "alice"
      akh.file.should eq Path.new("/tmp/test/authorized_keys_alice")
    end
  end

  describe "#allowed_for_user?" do
    it "allows any user when login_user is nil" do
      akh = AuthKeysHub.new
      akh.allowed_for_user?("alice").should be_true
      akh.allowed_for_user?("bob").should be_true
    end

    it "only allows matching user when login_user is set" do
      akh = AuthKeysHub.new
      akh.login_user = "alice"
      akh.allowed_for_user?("alice").should be_true
      akh.allowed_for_user?("bob").should be_false
    end
  end

  describe "#outdated?" do
    it "returns true when file does not exist" do
      akh = AuthKeysHub.new
      akh.dir = Path.new("/tmp/nonexistent-#{Random.rand(10000)}")
      akh.outdated?.should be_true
    end

    it "returns true when file is older than ttl" do
      test_dir = Path.new("/tmp/test-akh-#{Random.rand(10000)}")
      Dir.mkdir_p(test_dir)
      begin
        akh = AuthKeysHub.new
        akh.dir = test_dir
        akh.ttl = Time::Span.new(seconds: 1)

        File.write(akh.file, "test")
        sleep 2.seconds

        akh.outdated?.should be_true
      ensure
        FileUtils.rm_rf(test_dir)
      end
    end
  end

  describe "#github_teams_configured?" do
    it "returns falsy without teams" do
      akh = AuthKeysHub.new
      akh.github_teams = [] of String
      akh.github_token = "token"
      akh.github_teams_configured?.should be_falsey
    end

    it "returns falsy without token" do
      akh = AuthKeysHub.new
      akh.github_teams = ["org/team"]
      akh.github_token = nil
      akh.github_teams_configured?.should be_falsey
    end

    it "returns truthy with both teams and token" do
      akh = AuthKeysHub.new
      akh.github_teams = ["org/team"]
      akh.github_token = "token"
      akh.github_teams_configured?.should be_truthy
    end
  end

  describe "#gitlab_groups_configured?" do
    it "returns falsy without groups" do
      akh = AuthKeysHub.new
      akh.gitlab_groups = [] of String
      akh.gitlab_token = "token"
      akh.gitlab_groups_configured?.should be_falsey
    end

    it "returns falsy without token" do
      akh = AuthKeysHub.new
      akh.gitlab_groups = ["group"]
      akh.gitlab_token = nil
      akh.gitlab_groups_configured?.should be_falsey
    end

    it "returns truthy with both groups and token" do
      akh = AuthKeysHub.new
      akh.gitlab_groups = ["group"]
      akh.gitlab_token = "token"
      akh.gitlab_groups_configured?.should be_truthy
    end
  end

  describe "#update_users" do
    it "adds simple users" do
      akh = AuthKeysHub.new
      akh.update_users(["alice", "bob"], AuthKeysHub::GitHubUser)
      akh.users.size.should eq 2
      akh.users[0].to_s.should eq "alice"
      akh.users[1].to_s.should eq "bob"
    end

    it "filters users by login_user constraint" do
      akh = AuthKeysHub.new
      akh.login_user = "dev"
      akh.update_users(["alice:dev", "bob:admin"], AuthKeysHub::GitHubUser)
      akh.users.size.should eq 1
      akh.users[0].to_s.should eq "alice"
    end

    it "accepts users without constraint when no login_user" do
      akh = AuthKeysHub.new
      akh.update_users(["alice", "bob:admin"], AuthKeysHub::GitHubUser)
      akh.users.size.should eq 2
    end
  end
end

describe AuthKeysHub::GitHubUser do
  it "creates user with login" do
    user = AuthKeysHub::GitHubUser.new("torvalds")
    user.login.should eq "torvalds"
    user.to_s.should eq "torvalds"
  end

  it "compares users by login" do
    user1 = AuthKeysHub::GitHubUser.new("alice")
    user2 = AuthKeysHub::GitHubUser.new("bob")
    (user1 <=> user2).should eq -1
    (user2 <=> user1).should eq 1
  end
end

describe AuthKeysHub::GitlabUser do
  it "creates user with username" do
    user = AuthKeysHub::GitlabUser.new("alice")
    user.username.should eq "alice"
    user.to_s.should eq "alice"
  end

  it "compares users by username" do
    user1 = AuthKeysHub::GitlabUser.new("alice")
    user2 = AuthKeysHub::GitlabUser.new("bob")
    (user1 <=> user2).should eq -1
    (user2 <=> user1).should eq 1
  end
end

describe AuthKeysHub::GitlabUserKey do
  it "considers key viable when not expired" do
    key = AuthKeysHub::GitlabUserKey.from_json(%(
      {
        "title": "test",
        "key": "ssh-rsa AAAA...",
        "usage_type": "auth",
        "expires_at": "#{(Time.utc + 1.day).to_rfc3339}"
      }
    ))
    key.viable?.should be_true
  end

  it "considers key non-viable when expired" do
    key = AuthKeysHub::GitlabUserKey.from_json(%(
      {
        "title": "test",
        "key": "ssh-rsa AAAA...",
        "usage_type": "auth",
        "expires_at": "#{(Time.utc - 1.day).to_rfc3339}"
      }
    ))
    key.viable?.should be_false
  end

  it "considers key viable when expires_at is null" do
    key = AuthKeysHub::GitlabUserKey.from_json(%(
      {
        "title": "test",
        "key": "ssh-rsa AAAA...",
        "usage_type": "auth",
        "expires_at": null
      }
    ))
    key.viable?.should be_true
  end
end

describe "read_file" do
  it "reads existing file and strips whitespace" do
    test_file = "/tmp/test-read-#{Random.rand(10000)}"
    File.write(test_file, "  content  \n")
    begin
      read_file(test_file).should eq "content"
    ensure
      File.delete(test_file)
    end
  end

  it "returns nil for non-existent file" do
    read_file("/tmp/nonexistent-#{Random.rand(10000)}").should be_nil
  end
end
