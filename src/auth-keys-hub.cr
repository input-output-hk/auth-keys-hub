require "./auth-keys-hub/core"

# Ensure no errors go to stdout.
# When wrapped by a custom script in sshd's `AuthorizedKeysCommand`,
# the user must be able to suppress all log messages by redirecting stderr.
Log.setup_from_env(
  default_level: :debug,
  backend: Log::IOBackend.new(io: STDERR, dispatcher: Log::DispatchMode::Sync),
)

akh = AuthKeysHub.new

OptionParser.parse do |parser|
  parser.banner = "Usage: auth-keys-hub [arguments]"

  parser.on("--github-host=HOST", "GitHub Host (e.g. github.com)") { |value| akh.github_host = value }
  parser.on("--github-teams=TEAMS", "GitHub team names, including organization name, comma separated (e.g. acme/ops) ") { |value| akh.github_teams = value.split(",").map(&.strip) }
  parser.on("--github-token-file=PATH", "File containing the GitHub token") { |value| akh.github_token = read_file(value) }
  parser.on("--github-users=NAMES", "GitHub user names, comma separated") { |value| akh.github_users = value.split(",") }

  parser.on("--gitlab-groups=TEAMS", "GitLab group or project names, comma separated") { |value| akh.gitlab_groups = value.split(",").map(&.strip) }
  parser.on("--gitlab-host=HOST", "GitLab Host (e.g. gitlab.com)") { |value| akh.gitlab_host = value }
  parser.on("--gitlab-token-file=PATH", "File containing the GitLab token") { |value| akh.gitlab_token = read_file(value) }
  parser.on("--gitlab-users=NAMES", "GitLab user names, comma separated") { |value| akh.gitlab_users = value.split(",") }

  parser.on("--dir=PATH", "Directory for storing temporary files") { |value| akh.dir = Path.new(value) }
  parser.on("--fallback=KEY", "Recovery key always served independently of the cache") { |value| akh.fallback_key = value }
  parser.on("--ttl=TIMESPAN", "Interval before refresh (e.g. 1d2h3h4s)") { |value| akh.ttl = parse_time_span(value) }
  parser.on("--user=LOGINNAME", "User requested by SSH connection") { |value| akh.login_user = value }

  parser.on("--version", "Show only version information") { puts "auth-keys-hub 0.1.0"; exit }
  parser.on("--force", "Refresh even when the cache is fresh") { akh.force = true }
  parser.on("--debug", "Some logging useful for debugging") { Log.setup(Log::Severity::Debug, Log::IOBackend.new(io: STDERR, dispatcher: Log::DispatchMode::Sync)) }
  parser.on("-h", "--help", "Show this help") { puts parser; exit }

  parser.invalid_option do |flag|
    STDERR.puts "ERROR: #{flag} is not a valid option."
    STDERR.puts parser
    exit 1
  end
end

log = nil
begin
  begin
    log = File.open(akh.dir / "log", "a")
    Log.setup_from_env(
      default_level: :debug,
      backend: Log::IOBackend.new(io: IO::MultiWriter.new(STDERR, log), dispatcher: Log::DispatchMode::Sync),
    )
  rescue ex
    STDERR.puts "Failed to initialize file logging; using stderr: #{ex.message}"
  end

  akh.update
rescue ex
  # Even an unexpected refresh/logging exception must not suppress recovery access.
  STDERR.puts "Failed to refresh #{akh.file}: #{ex.message}"
ensure
  begin
    log.try &.close
  rescue ex
    STDERR.puts "Failed to close log file: #{ex.message}"
  end
end

# Output does not depend on file logging, and fallback makes the command succeed
# even if the cache cannot be read. sshd ignores keys from a command that fails.
exit 1 unless akh.output
