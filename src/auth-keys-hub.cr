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

def team_members(config)
  params = URI::Params.encode({"per_page" => "100", "page" => "1"})
  uri = URI.new("https", "api.github.com", path: "/orgs/#{config.org}/teams/#{config.team}/members", query: params)

  client = HTTP::Client.new(uri: uri)
  client.read_timeout = 5.seconds
  client.before_request do |request|
    request.headers = HTTP::Headers{
      "Accept"               => "application/vnd.github+json",
      "Accept-Encoding"      => "gzip, deflate",
      "Authorization"        => "bearer #{config.token}",
      "Host"                 => uri.host.not_nil!,
      "User-Agent"           => "auth-keys-hub",
      "X-GitHub-Api-Version" => "2022-11-28",
    }
  end

  team_members_collect(client, uri).sort.uniq
end

def team_members_collect(client, uri) : Array(String)
  response = client.get(uri.request_target)
  users = Array(User).from_json(response.body).map { |user| user.login }

  case response.headers["Link"]?
  when /<(?<url>[^>]+)>; rel="next"/
    users.concat(team_members_collect(client, URI.parse($~.try(&.["url"]))))
  end

  users
end

def update_users(path, names)
  Log.debug { "Updating #{path} file for #{names.join(", ")}" }

  channel = Channel(String?).new

  names.each do |name|
    spawn name: name do
      client = HTTP::Client.new(uri: URI.parse("https://github.com"))
      client.read_timeout = 5.seconds
      response = client.get("/#{name}.keys")
      if response.status == HTTP::Status::OK
        channel.send(response.body.gsub(/\n/, " #{name}\n"))
      else
        channel.send(nil)
      end
    end
  end

  File.open("#{path}.tmp", "w+") do |fd|
    names.each do |_name|
      fd.puts(channel.receive)
    end
  end

  File.rename("#{path}.tmp", path)
rescue ex
  STDERR.puts(ex)
end

def outdated?(path)
  info = File.info?(path)
  return true unless info
  (Time.utc - info.modification_time) > Time::Span.new(hours: 1)
end

struct Config
  property users = [] of String
  property dir = Path.new("/tmp")
  property org : String?
  property team : String?
  property token : String?
  property force = false

  def file
    dir / "authorized_keys"
  end
end

Log.setup_from_env(default_level: :error)

config = Config.new

OptionParser.parse do |parser|
  parser.banner = "Usage: auth-keys-hub [arguments]"
  parser.on("--users=NAMES", "GitHub user names, comma separated") { |value|
    config.users = value.split(",").map { |s| s.strip }.sort.uniq
  }
  parser.on("--org=NAME", "GitHub organization name") { |value| config.org = value }
  parser.on("--team=NAME", "GitHub team name") { |value| config.team = value }
  parser.on("--token-file=PATH", "File containing the GitHub token") { |value| config.token = File.read(value).strip }
  parser.on("--dir=PATH", "Directory for storing tempoary files") { |value| config.dir = Path.new(value) }
  parser.on("-f", "--force", "Delete authorized_keys first") { config.force = true }
  parser.on("-v", "--verbose", "Output all steps made") { Log.setup(Log::Severity::Debug) }
  parser.on("-h", "--help", "Show this help") { puts parser; exit }
  parser.invalid_option do |flag|
    STDERR.puts "ERROR: #{flag} is not a valid option."
    STDERR.puts parser
    exit 1
  end
end

File.delete?(config.file) if config.force

begin
  if config.org && config.team && config.token
    config.users.concat team_members(config)
  end

  update_users(config.file, config.users) if outdated?(config.file)
rescue ex
  Log.error(exception: ex) { "Failed to update authorized_keys" }
end

puts File.read(config.file)
