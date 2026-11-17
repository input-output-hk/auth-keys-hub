require "spec"
require "file_utils"
require "http/server"
require "json"

# Exercise the real CLI, including exit status, stdout, and process-level locks.
# A packaged binary can be supplied by Nix; otherwise compile one for this suite.
module CacheRegression
  OLD      = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOldSnapshot synthetic-old\n"
  FALLBACK = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFallback synthetic-fallback"
  BINARY   = ENV["AUTH_KEYS_HUB_BINARY"]? || File.tempname("auth-keys-hub-spec")

  def self.key(user)
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI#{user}"
  end

  def self.expected(*users)
    users.to_a.sort.map { |user| "#{key(user)} #{user}\n" }.join
  end

  # Keep the specs usable with older Crystal versions as well as the pinned one.
  def self.monotonic_now
    {% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 %}
      Time.instant
    {% else %}
      Time.monotonic
    {% end %}
  end

  def self.wait_until(message, &block : -> Bool)
    deadline = monotonic_now + 10.seconds
    until yield
      raise message if monotonic_now >= deadline
      sleep 5.milliseconds
    end
  end

  alias Response = Tuple(Int32, String, HTTP::Headers)

  def self.response(status = 200, body = "", headers = HTTP::Headers.new) : Response
    {status, body, headers}
  end

  class MockAPI
    getter routes = {} of Tuple(String, String) => Proc(Response)
    getter requests = Hash(Tuple(String, String), Int32).new(0)
    getter errors = [] of Exception
    getter url : String
    @release = Channel(Nil).new
    @stopped = Channel(Nil).new(1)
    @pending = 0

    def initialize
      @server = HTTP::Server.new do |context|
        @pending += 1
        begin
          page = context.request.query_params["page"]? || "1"
          route = {context.request.path, page}
          requests[route] += 1
          status, body, headers = if handler = routes[route]?
                                    handler.call
                                  else
                                    errors << Exception.new("Unexpected mock request: #{route}")
                                    CacheRegression.response(500, "Unexpected mock request")
                                  end
          context.response.status_code = status
          headers.each { |name, value| context.response.headers[name] = value }
          begin
            context.response.print(body)
            context.response.close
          rescue IO::Error
            # Clients deliberately disconnect before timeout responses are released.
          end
        rescue ex
          errors << ex
          context.response.status_code = 500
        ensure
          @pending -= 1
        end
      end
      address = @server.bind_tcp("127.0.0.1", 0)
      @url = "http://127.0.0.1:#{address.port}"
      spawn do
        @server.listen
      ensure
        @stopped.send(nil)
      end
    end

    def respond(path, status = 200, body = "", headers = HTTP::Headers.new, page = "1")
      routes[{path, page}] = -> { CacheRegression.response(status, body, headers) }
    end

    def timeout(path, page = "1")
      routes[{path, page}] = -> {
        # Remain silent until fixture cleanup, so the real five-second client
        # timeout fires regardless of scheduling or machine speed.
        select
        when @release.receive?
        when timeout(30.seconds)
          raise "Test did not release mock timeout"
        end
        CacheRegression.response
      }
    end

    def keys(provider, user, keys = [CacheRegression.key(user)], status = 200, page = "1", next_page : String? = nil)
      path = provider == "github" ? "/#{user}.keys" : "/api/v4/users/#{user}/keys"
      body = if provider == "github"
               keys.join('\n')
             else
               keys.map { |key| {title: "synthetic", key: key, usage_type: "auth", expires_at: nil} }.to_json
             end
      headers = HTTP::Headers.new
      headers["x-next-page"] = next_page if next_page
      respond(path, status, body, headers, page)
      path
    end

    def members(provider, users : Array(String), page = "1", status = 200, next_page : String? = nil)
      path = provider == "github" ? "/orgs/mock/teams/ops/members" : "/api/v4/groups/ops/members/all"
      field = provider == "github" ? "login" : "username"
      headers = HTTP::Headers.new
      if next_page
        if provider == "github"
          headers["Link"] = %(<#{url}#{path}?page=#{next_page}>; rel="next")
        else
          headers["x-next-page"] = next_page
        end
      end
      respond(path, status, users.map { |user| {field => user} }.to_json, headers, page)
      path
    end

    def close
      @release.close
      @server.close
      @stopped.receive
      CacheRegression.wait_until("Mock requests did not finish") { @pending == 0 }
    end
  end

  record Result, status : Process::Status, stdout : String, stderr : String do
    def success!
      status.exit_code.should eq(0), stderr
    end
  end

  class Command
    getter? done = false
    @stdout = IO::Memory.new
    @stderr = IO::Memory.new
    @finished = Channel(Nil).new(1)
    @status : Process::Status?
    @error : Exception?

    def initialize(args)
      @process = Process.new(BINARY, args, env: {"LOG_LEVEL" => "DEBUG"}, output: @stdout, error: @stderr)
      spawn do
        @status = @process.wait
      rescue ex
        @error = ex
      ensure
        @done = true
        @finished.send(nil)
      end
    end

    def wait : Result
      unless done?
        select
        when @finished.receive
        when timeout(25.seconds)
          raise "CLI timed out: #{@stderr}"
        end
      end
      if error = @error
        raise error
      end
      Result.new(@status.not_nil!, @stdout.to_s, @stderr.to_s)
    end

    def close
      @process.signal(Signal::KILL) if @process.exists?
      wait
    end
  end

  class Fixture
    getter directory = Path.new(File.tempname("auth-keys-hub-regression"))
    getter api = MockAPI.new
    getter commands = [] of Command

    def initialize
      Dir.mkdir(directory)
      File.write(token, "synthetic-test-token\n")
    end

    def cache
      directory / "authorized_keys_root"
    end

    def token
      directory / "token"
    end

    def start(provider = "github", users = "alice,bob", membership = false, extra = [] of String)
      args = ["--dir", directory.to_s, "--user", "root", "--#{provider}-host", api.url]
      args.concat ["--#{provider}-users", users] unless users.empty?
      if membership
        kind = provider == "github" ? "teams" : "groups"
        name = provider == "github" ? "mock/ops" : "ops"
        args.concat ["--#{provider}-#{kind}", name, "--#{provider}-token-file", token.to_s]
      end
      command = Command.new(args + extra)
      commands << command
      command
    end

    def run(**args)
      start(**args).wait
    end

    def seed(content = OLD)
      File.write(cache, content)
      File.touch(cache, Time.utc - 2.hours)
      mtime
    end

    def mtime
      File.info(cache).modification_time
    end

    def temporary_files
      Dir.glob((directory / "*.tmp").to_s)
    end

    def preserved(result, stamp, content = OLD, fallback : String? = nil)
      result.success!
      result.stdout.should eq((fallback ? "#{fallback}\n" : "") + content)
      File.read(cache).should eq(content)
      mtime.should eq(stamp)
      result.stderr.should contain("preserving existing cache")
      temporary_files.should be_empty
    end

    def close
      commands.each(&.close)
    ensure
      api.close
      FileUtils.rm_rf(directory)
    end
  end

  def self.with_fixture(&)
    fixture = Fixture.new
    begin
      yield fixture
    ensure
      fixture.close
      fixture.api.errors.should be_empty
    end
  end
end

Spec.before_suite do
  unless ENV.has_key?("AUTH_KEYS_HUB_BINARY")
    source = File.expand_path("../../src/auth-keys-hub.cr", __DIR__)
    status = Process.run("crystal", ["build", source, "-o", CacheRegression::BINARY], output: STDOUT, error: STDERR)
    raise "Failed to build CLI for cache regressions" unless status.success?
  end
end

Spec.after_suite do
  File.delete?(CacheRegression::BINARY) unless ENV.has_key?("AUTH_KEYS_HUB_BINARY")
end
