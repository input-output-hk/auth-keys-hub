require "http/client"
require "json"
require "log"
require "option_parser"
require "uri"

class User
  include JSON::Serializable

  @[JSON::Field(key: "login")]
  property login : String
end

class Key
  include JSON::Serializable

  @[JSON::Field(key: "id")]
  property id : Int64

  @[JSON::Field(key: "key")]
  property key : String
end

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
  property users = [] of String
  property dir = Path.new("/tmp")
  property github_host = "github.com"
  property teams = [] of String
  property token : String?
  property force = false
  property ttl = Time::Span.new(hours: 1)
  property keys = {} of String => Array(String)

  def file
    dir / "authorized_keys"
  end

  def teams_configured?
    teams.any? && token
  end

  def outdated?
    info = File.info?(file)
    return true unless info
    (Time.utc - info.modification_time) > ttl
  end

  def update
    File.delete?(file) if force
    return unless outdated?

    update_teams if teams_configured?
    update_keys
  end

  def update_teams
    teams.each { |org_team|
      org, team = org_team.split("/")
      update_team(org, team)
    }
  end

  def update_team(org, team)
    params = URI::Params.encode({"per_page" => "100", "page" => "1"})
    uri = URI.new("https", "api.#{github_host}", path: "/orgs/#{org}/teams/#{team}/members", query: params)

    client = HTTP::Client.new(uri: uri)
    client.read_timeout = 5.seconds
    client.before_request do |request|
      request.headers = HTTP::Headers{
        "Accept"               => "application/vnd.github+json",
        "Accept-Encoding"      => "gzip, deflate",
        "Authorization"        => "bearer #{token}",
        "Host"                 => uri.host.not_nil!,
        "User-Agent"           => "auth-keys-hub",
        "X-GitHub-Api-Version" => "2022-11-28",
      }
    end

    update_team_page(client, uri)
  end

  def update_team_page(client, uri)
    response = client.get(uri.request_target)
    users.concat Array(User).from_json(response.body).map(&.login)

    case response.headers["Link"]?
    when /<(?<url>[^>]+)>; rel="next"/
      update_team_page(client, URI.parse($~.try(&.["url"])))
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

    channel = Channel(String?).new

    users.each do |name|
      spawn name: name do
        client = HTTP::Client.new(uri: URI.parse("https://#{github_host}"))
        client.read_timeout = 5.seconds
        response = client.get("/#{name}.keys")
        if response.status == HTTP::Status::OK
          channel.send(response.body.gsub(/\n+/, " #{name}\n"))
        else
          channel.send(nil)
        end
      end
    end

    File.open("#{file}.tmp", "w+") do |fd|
      users.each do |_name|
        if (value = channel.receive) && !value.empty?
          fd.puts(value.strip)
        end
      end
    end

    File.rename("#{file}.tmp", file)
  rescue ex
    STDERR.puts(ex)
  end
end

akh = AuthKeysHub.new

OptionParser.parse do |parser|
  parser.banner = "Usage: auth-keys-hub [arguments]"
  parser.on("--users=NAMES", "GitHub user names, comma separated") { |value|
    akh.users = value.split(",").map { |s| s.strip }.sort.uniq
  }
  parser.on("--github-host=HOST", "GitHub Host (e.g. github.com)") { |value| akh.github_host = value }
  parser.on("--teams=TEAMS", "GitHub team names, including organization name, comma separated (e.g. acme/ops) ") { |value| akh.teams = value.split(",").map(&.strip) }
  parser.on("--token-file=PATH", "File containing the GitHub token") { |value| akh.token = File.read(value).strip }
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
