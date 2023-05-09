require "http/client"
require "json"
require "log"
require "option_parser"
require "uri"

def parse_time_span(input)
  match = /^((?<d>\d+)d)?((?<h>\d+)h)?((?<m>\d+)m)?((?<s>\d+)s)?$/.match(input)
  raise "invalid timespan" unless match
  Time::Span.new(
    days: match["d"]?.try &.to_i || 0,
    hours: match["h"]?.try &.to_i || 0,
    minutes: match["m"]?.try &.to_i || 0,
    seconds: match["s"]?.try &.to_i || 0,
  )
end

struct AuthKeysHub
  alias User = GitHubUser

  struct GitHubUser
    include JSON::Serializable

    @[JSON::Field(key: "login")]
    property login : String

    def initialize(@login)
    end

    def to_s
      login
    end

    def <=>(other)
      login <=> other.login
    end

    def keys(config) : Array(String)
      client = HTTP::Client.new(uri: URI.parse("https://#{config.github_host}"))
      client.read_timeout = 5.seconds
      response = client.get("/#{login}.keys")
      if response.status == HTTP::Status::OK
        (response.body.split("\n") - [""]).map { |line| "#{line} #{login}" }
      else
        [] of String
      end
    end
  end

  property users = [] of User
  property dir = Path.new("/tmp")
  property github_host = "github.com"
  property github_teams = [] of String
  property github_token : String?
  property force = false
  property ttl = Time::Span.new(hours: 1)

  def file
    dir / "authorized_keys"
  end

  def github_teams_configured?
    github_teams.any? && github_token
  end

  def outdated?
    info = File.info?(file)
    return true unless info
    (Time.utc - info.modification_time) > ttl
  end

  def update
    File.delete?(file) if force
    return unless outdated?

    update_github_teams if github_teams_configured?
    update_keys
  end

  def update_github_teams
    github_teams.each { |org_team|
      org, team = org_team.split("/")
      update_github_team(org, team)
    }
  end

  def update_github_team(org, team)
    params = URI::Params.encode({"per_page" => "100", "page" => "1"})
    uri = URI.new("https", "api.#{github_host}", path: "/orgs/#{org}/teams/#{team}/members", query: params)

    client = HTTP::Client.new(uri: uri)
    client.read_timeout = 5.seconds
    client.before_request do |request|
      request.headers = HTTP::Headers{
        "Accept"               => "application/vnd.github+json",
        "Accept-Encoding"      => "gzip, deflate",
        "Authorization"        => "bearer #{github_token}",
        "Host"                 => uri.host.not_nil!,
        "User-Agent"           => "auth-keys-hub",
        "X-GitHub-Api-Version" => "2022-11-28",
      }
    end

    update_github_team_page(client, uri)
  end

  def update_github_team_page(client, uri)
    response = client.get(uri.request_target)
    users.concat Array(GitHubUser).from_json(response.body)

    case response.headers["Link"]?
    when /<(?<url>[^>]+)>; rel="next"/
      update_github_team_page(client, URI.parse($~.try(&.["url"])))
    end
  rescue ex
    Log.error(exception: ex) do
      if response
        response.inspect
      else
        "Failed to fetch #{uri}"
      end
    end
  end

  def update_keys
    users.sort!
    users.uniq!
    Log.debug { "Updating #{file} file for #{users.join(", ")}" }

    channel = Channel(Array(String)).new

    users.each do |user|
      spawn name: user.to_s do
        begin
          channel.send(user.keys(self))
        rescue ex
          channel.send([] of String)
        end
      end
    end

    File.open("#{file}.tmp", "w+") do |fd|
      users.each do |_name|
        channel.receive.each do |line|
          fd.puts(line)
        end
      end
    end

    File.rename("#{file}.tmp", file)
  rescue ex
    STDERR.puts(ex)
  end

  def set_github_users(value)
    self.users = value.split(",").map { |s| GitHubUser.new(login: s.strip) }
  end
end

akh = AuthKeysHub.new

OptionParser.parse do |parser|
  parser.banner = "Usage: auth-keys-hub [arguments]"
  parser.on("--github-users=NAMES", "GitHub user names, comma separated") { |value| akh.set_github_users(value) }
  parser.on("--github-host=HOST", "GitHub Host (e.g. github.com)") { |value| akh.github_host = value }
  parser.on("--github-teams=TEAMS", "GitHub team names, including organization name, comma separated (e.g. acme/ops) ") { |value| akh.github_teams = value.split(",").map(&.strip) }
  parser.on("--github-token-file=PATH", "File containing the GitHub token") { |value| akh.github_token = File.read(value).strip }
  parser.on("--dir=PATH", "Directory for storing tempoary files") { |value| akh.dir = Path.new(value) }
  parser.on("--ttl=TIMESPAN", "Interval before refresh (e.g. 1d2h3h4s)") { |value| akh.ttl = parse_time_span(value) }
  parser.on("--version", "Show only version information") { puts "auth-keys-hub 0.0.1"; exit }
  parser.on("--force", "Delete authorized_keys first") { akh.force = true }
  parser.on("--debug", "Some logging useful for debugging") { Log.setup(Log::Severity::Debug) }
  parser.on("-h", "--help", "Show this help") { puts parser; exit }
  parser.invalid_option do |flag|
    STDERR.puts "ERROR: #{flag} is not a valid option."
    STDERR.puts parser
    exit 1
  end
end

Log.setup_from_env(
  default_level: :error,
  backend: Log::IOBackend.new(STDERR),
)

begin
  akh.update
rescue ex
  Log.error(exception: ex) { "Failed to update authorized_keys" }
end

puts File.read(akh.file)
