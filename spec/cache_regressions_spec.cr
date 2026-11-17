require "./support/cache_fixture"

include CacheRegression

describe "cache refresh CLI regressions" do
  {"github", "gitlab"}.each do |provider|
    describe provider do
      it "preserves the cache on partial key timeouts and retries immediately after recovery" do
        CacheRegression.with_fixture do |test|
          stamp = test.seed
          test.api.keys(provider, "alice")
          {"bob", "carol"}.each do |user|
            test.api.timeout(test.api.keys(provider, user))
          end
          result = test.run(provider: provider, users: "alice,bob,carol")
          test.preserved(result, stamp)
          {"bob", "carol"}.each do |user|
            result.stderr.should contain("Failed to fetch keys for #{user}")
            test.api.keys(provider, user)
          end
          recovered = test.run(provider: provider, users: "alice,bob,carol")
          recovered.success!
          recovered.stdout.should eq(CacheRegression.expected("alice", "bob", "carol"))
          test.mtime.should be > stamp
          before = test.api.requests.dup
          fresh = test.run(provider: provider, users: "alice,bob,carol")
          fresh.success!
          fresh.stdout.should eq(recovered.stdout)
          test.api.requests.should eq(before)
        end
      end

      {401, 403, 404, 429, 500}.each do |status|
        it "does not publish partial keys after HTTP #{status}" do
          CacheRegression.with_fixture do |test|
            stamp = test.seed
            test.api.keys(provider, "alice")
            test.api.keys(provider, "bob", status: status)
            result = test.run(provider: provider)
            test.preserved(result, stamp)
            result.stderr.should contain("HTTP #{status}")
          end
        end
      end

      {"1", "2"}.each do |page|
        it "preserves the cache when membership page #{page} fails and retries after recovery" do
          CacheRegression.with_fixture do |test|
            stamp = test.seed
            test.api.keys(provider, "explicit")
            test.api.keys(provider, "alice")
            test.api.members(provider, ["alice"], next_page: "2")
            test.api.members(provider, [] of String, page: page, status: 503)
            result = test.run(provider: provider, users: "explicit", membership: true)
            test.preserved(result, stamp)
            result.stderr.should contain("page=#{page}")
            test.api.members(provider, ["alice"], next_page: "2")
            test.api.members(provider, [] of String, page: "2")
            recovered = test.run(provider: provider, users: "explicit", membership: true)
            recovered.success!
            recovered.stdout.should eq(CacheRegression.expected("alice", "explicit"))
          end
        end
      end

      it "preserves the cache when a later membership page times out" do
        CacheRegression.with_fixture do |test|
          stamp = test.seed
          path = test.api.members(provider, ["alice"], next_page: "2")
          test.api.timeout(path, "2")
          test.api.keys(provider, "explicit")
          test.preserved(test.run(provider: provider, users: "explicit", membership: true), stamp)
        end
      end

      it "treats malformed membership JSON as failure" do
        CacheRegression.with_fixture do |test|
          stamp = test.seed
          path = test.api.members(provider, [] of String)
          test.api.respond(path, body: "not json")
          test.preserved(test.run(provider: provider, membership: true), stamp)
        end
      end

      it "publishes membership removals including an authoritative empty snapshot" do
        CacheRegression.with_fixture do |test|
          test.seed
          test.api.members(provider, ["alice"], next_page: "2")
          test.api.members(provider, ["bob"], page: "2")
          test.api.keys(provider, "alice")
          test.api.keys(provider, "bob")
          result = test.run(provider: provider, users: "", membership: true)
          result.success!
          result.stdout.should eq(CacheRegression.expected("alice", "bob"))
          test.api.members(provider, ["alice"])
          result = test.run(provider: provider, users: "", membership: true, extra: ["--force"])
          result.success!
          result.stdout.should eq(CacheRegression.expected("alice"))
          test.api.members(provider, [] of String)
          result = test.run(provider: provider, users: "", membership: true, extra: ["--force", "--fallback", FALLBACK])
          result.success!
          result.stdout.should eq("#{FALLBACK}\n")
          File.read(test.cache).should eq("")
          before = test.api.requests.dup
          without_fallback = test.run(provider: provider, users: "", membership: true)
          without_fallback.success!
          without_fallback.stdout.should eq("")
          test.api.requests.should eq(before)
        end
      end

      it "publishes key removals including an authoritative empty snapshot" do
        CacheRegression.with_fixture do |test|
          test.seed
          test.api.keys(provider, "alice", keys: [] of String)
          test.api.keys(provider, "bob")
          result = test.run(provider: provider)
          result.success!
          result.stdout.should eq(CacheRegression.expected("bob"))
          test.api.keys(provider, "bob", keys: [] of String)
          result = test.run(provider: provider, extra: ["--force", "--fallback", FALLBACK])
          result.success!
          result.stdout.should eq("#{FALLBACK}\n")
          File.read(test.cache).should eq("")
        end
      end

      it "serves fallback with successful and fresh caches, applying fallback configuration changes immediately" do
        CacheRegression.with_fixture do |test|
          test.seed
          test.api.keys(provider, "alice")
          result = test.run(provider: provider, users: "alice", extra: ["--fallback", FALLBACK])
          result.success!
          result.stdout.should eq("#{FALLBACK}\n" + CacheRegression.expected("alice"))
          File.read(test.cache).should eq(CacheRegression.expected("alice"))
          stamp = test.mtime
          before = test.api.requests.dup

          fresh = test.run(provider: provider, users: "alice", extra: ["--fallback", FALLBACK])
          fresh.success!
          fresh.stdout.should eq(result.stdout)

          replacement = "#{CacheRegression.key("replacement")} synthetic-recovery"
          changed = test.run(provider: provider, users: "alice", extra: ["--fallback", replacement])
          changed.success!
          changed.stdout.should eq("#{replacement}\n" + CacheRegression.expected("alice"))

          removed = test.run(provider: provider, users: "alice")
          removed.success!
          removed.stdout.should eq(CacheRegression.expected("alice"))
          File.read(test.cache).should eq(CacheRegression.expected("alice"))
          test.mtime.should eq(stamp)
          test.api.requests.should eq(before)
        end
      end

      {false, true}.each do |membership|
        {false, true}.each do |fallback|
          it "handles no-cache failure and recovery (membership=#{membership}, fallback=#{fallback})" do
            CacheRegression.with_fixture do |test|
              test.api.keys(provider, "alice")
              test.api.keys(provider, "bob", status: 500)
              test.api.members(provider, [] of String, status: 500)
              extra = fallback ? ["--fallback", FALLBACK] : [] of String
              result = test.run(provider: provider, membership: membership, extra: extra)
              result.status.exit_code.should eq(fallback ? 0 : 1), result.stderr
              result.stdout.should eq(fallback ? "#{FALLBACK}\n" : "")
              File.exists?(test.cache).should be_false
              test.temporary_files.should be_empty
              test.api.keys(provider, "bob")
              test.api.members(provider, [] of String)
              result = test.run(provider: provider, membership: membership, extra: extra)
              result.success!
              result.stdout.should eq((fallback ? "#{FALLBACK}\n" : "") + CacheRegression.expected("alice", "bob"))
              File.read(test.cache).should eq(CacheRegression.expected("alice", "bob"))
            end
          end
        end
      end

      {nil, ""}.each do |token|
        it "fails refresh for a #{token.nil? ? "missing" : "empty"} required token" do
          CacheRegression.with_fixture do |test|
            stamp = test.seed
            if token
              File.write(test.token, token)
            else
              File.delete(test.token)
            end
            test.api.keys(provider, "alice")
            result = test.run(provider: provider, users: "alice", membership: true)
            test.preserved(result, stamp)
          end
        end
      end
    end
  end

  it "treats malformed GitLab key JSON as failure" do
    CacheRegression.with_fixture do |test|
      stamp = test.seed
      test.api.keys("gitlab", "alice")
      path = test.api.keys("gitlab", "bob")
      test.api.respond(path, body: "not json")
      test.preserved(test.run(provider: "gitlab"), stamp)
    end
  end

  it "fetches all GitLab key pages, rejecting failures and applying later removals" do
    CacheRegression.with_fixture do |test|
      stamp = test.seed
      test.api.keys("gitlab", "alice", next_page: "2")
      test.api.keys("gitlab", "alice", page: "2", status: 503)
      test.preserved(test.run(provider: "gitlab", users: "alice"), stamp)
      test.api.keys("gitlab", "alice", page: "2", keys: [CacheRegression.key("second")])
      result = test.run(provider: "gitlab", users: "alice")
      result.success!
      result.stdout.should eq(CacheRegression.expected("alice") + "#{CacheRegression.key("second")} alice\n")
      test.api.keys("gitlab", "alice")
      result = test.run(provider: "gitlab", users: "alice", extra: ["--force"])
      result.success!
      result.stdout.should eq(CacheRegression.expected("alice"))
    end
  end

  it "revokes upstream access but retains configured fallback when no users match the SSH login" do
    CacheRegression.with_fixture do |test|
      test.seed
      result = test.run(users: "alice:other", extra: ["--fallback", FALLBACK])
      result.success!
      result.stdout.should eq("#{FALLBACK}\n")
      File.read(test.cache).should eq("")
      test.api.requests.should be_empty
    end
  end

  it "attributes out-of-order results to the correct user" do
    CacheRegression.with_fixture do |test|
      test.seed
      test.api.keys("github", "bob")
      test.api.routes[{"/alice.keys", "1"}] = -> {
        # Release Alice only after the CLI has consumed Bob's result.
        CacheRegression.wait_until("Bob's result was not consumed first") do
          File.read(test.directory / "log").includes?("Fetched keys for bob")
        end
        CacheRegression.response(503, "failure")
      }
      result = test.run
      result.success!
      result.stderr.should contain("Failed to fetch keys for alice")
      result.stderr.should contain("Fetched keys for bob")
      result.stderr.should_not contain("Failed to fetch keys for bob")
      result.stderr.should_not contain("Fetched keys for alice")
      result.stdout.should eq(OLD)
    end
  end

  it "serves fallback alongside a preserved cache on forced refresh failure, without diagnostics on stdout" do
    CacheRegression.with_fixture do |test|
      File.write(test.cache, OLD)
      stamp = test.mtime
      test.api.keys("github", "alice", status: 500)
      result = test.run(users: "alice", extra: ["--force", "--fallback", FALLBACK, "--debug"])
      test.preserved(result, stamp, fallback: FALLBACK)
    end
  end

  it "serves fallback for a successful empty result without caching the fallback" do
    CacheRegression.with_fixture do |test|
      test.api.keys("github", "alice", keys: [] of String)
      result = test.run(users: "alice", extra: ["--fallback", FALLBACK])
      result.success!
      result.stdout.should eq("#{FALLBACK}\n")
      File.exists?(test.cache).should be_true
      File.read(test.cache).should eq("")
    end
  end

  it "serves fallback while preserving an authoritative empty cache during outage" do
    CacheRegression.with_fixture do |test|
      stamp = test.seed("")
      test.api.keys("github", "alice", status: 503)
      result = test.run(users: "alice", extra: ["--fallback", FALLBACK])
      test.preserved(result, stamp, content: "", fallback: FALLBACK)
    end
  end

  {false, true}.each do |fallback|
    it "handles an unreadable cache (fallback=#{fallback})" do
      CacheRegression.with_fixture do |test|
        # Reading a directory fails without relying on permissions or running as
        # an unprivileged user. Its fresh mtime also avoids a refresh first.
        Dir.mkdir(test.cache)
        extra = fallback ? ["--fallback", FALLBACK] : [] of String
        result = test.run(extra: extra)
        result.status.exit_code.should eq(fallback ? 0 : 1), result.stderr
        result.stdout.should eq(fallback ? "#{FALLBACK}\n" : "")
        result.stderr.should contain("Failed to read cache")
        File.directory?(test.cache).should be_true
        test.api.requests.should be_empty
      end
    end
  end

  {200, 503}.each do |status|
    it "serves fallback despite failed file logging (key response HTTP #{status})" do
      CacheRegression.with_fixture do |test|
        Dir.mkdir(test.directory / "log")
        test.api.keys("github", "alice", status: status)
        result = test.run(users: "alice", extra: ["--fallback", FALLBACK])
        result.success!
        keys = status == 200 ? CacheRegression.expected("alice") : ""
        result.stdout.should eq("#{FALLBACK}\n" + keys)
        result.stderr.should contain("Failed to initialize file logging")
        if status == 200
          File.read(test.cache).should eq(keys)
        else
          File.exists?(test.cache).should be_false
        end
      end
    end
  end

  it "serves fallback when the cache directory is unavailable" do
    CacheRegression.with_fixture do |test|
      missing = test.directory / "nonexistent"
      result = test.run(extra: ["--dir", missing.to_s, "--fallback", FALLBACK])
      result.success!
      result.stdout.should eq("#{FALLBACK}\n")
      result.stderr.should contain("Failed to initialize file logging")
      File.exists?(missing).should be_false
      test.api.requests.should be_empty
    end
  end

  it "rechecks TTL under the lock when six processes refresh concurrently" do
    CacheRegression.with_fixture do |test|
      test.seed
      test.api.keys("github", "alice")
      File.open("#{test.cache}.lock", "a") do |lock|
        lock.flock_exclusive do
          6.times { test.start(users: "alice") }
          # All processes must pass the initial TTL check before any can refresh.
          CacheRegression.wait_until("Refreshes did not reach the lock") do
            test.commands.none?(&.done?).should be_true
            log = test.directory / "log"
            File.exists?(log) && File.read(log).scan(/Waiting to refresh/).size == 6
          end
          test.api.requests.should be_empty
        end
      end
      test.commands.each do |command|
        result = command.wait
        result.success!
        result.stdout.should eq(CacheRegression.expected("alice"))
      end
      test.api.requests[{"/alice.keys", "1"}].should eq(1)
      test.temporary_files.should be_empty
    end
  end

  it "publishes only complete snapshots during concurrent forced refreshes" do
    CacheRegression.with_fixture do |test|
      test.seed
      snapshots = Array.new(6) do |version|
        Array.new(1500) { |index| "#{CacheRegression.key("v#{version}k#{index}")} alice\n" }.sort.join
      end
      index = 0
      test.api.routes[{"/alice.keys", "1"}] = -> {
        snapshot = snapshots[index]
        index += 1
        CacheRegression.response(body: snapshot.lines.map(&.chomp(" alice")).join('\n'))
      }
      # A stale shared temporary path must not be used or removed by refreshes.
      stale = test.directory / "authorized_keys_root.tmp"
      File.write(stale, "unrelated old temporary file")
      allowed = [OLD] + snapshots
      observed = Set(String).new
      6.times { test.start(users: "alice", extra: ["--force"]) }
      deadline = CacheRegression.monotonic_now + 25.seconds
      until test.commands.all?(&.done?)
        observed << File.read(test.cache)
        raise "Concurrent refreshes did not finish" if CacheRegression.monotonic_now >= deadline
        sleep 1.millisecond
      end
      test.commands.each do |command|
        result = command.wait
        result.success!
        snapshots.should contain(result.stdout)
      end
      observed.each { |snapshot| allowed.should contain(snapshot) }
      File.read(test.cache).should eq(snapshots.last)
      test.api.requests[{"/alice.keys", "1"}].should eq(6)
      File.read(stale).should eq("unrelated old temporary file")
      test.temporary_files.should eq([stale.to_s])
    end
  end
end
