require "http/client"
require "json"
require "log"
require "option_parser"
require "uri"
require "time"

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
  struct GitlabUserKey
    include JSON::Serializable

    property title : String
    property key : String
    property usage_type : String
    property expires_at : Time?

    def viable?
      if expires_at = self.expires_at
        expires_at > Time.utc
      else
        true
      end
    end
  end

  struct GitlabUser
    include JSON::Serializable

    @[JSON::Field(key: "username")]
    property username : String

    def initialize(@username)
    end

    def to_s
      username
    end

    def <=>(other)
      to_s <=> other.to_s
    end

    # fetch keys from gitlab
    def keys(config, channel) : Array(String)
      base_uri = config.parse_gitlab_uri
      client = HTTP::Client.new(uri: base_uri)
      client.read_timeout = 5.seconds
      response = client.get("/api/v4/users/#{username}/keys")
      unless response.status == HTTP::Status::OK
        Log.warn { "Response for gitlab user #{username} was not OK" }
        return [] of String
      end
      Array(GitlabUserKey).from_json(response.body).select(&.viable?).compact.map { |key|
        "#{key.key} #{username}"
      }
    end
  end

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
      to_s <=> other.to_s
    end

    def keys(config, channel) : Array(String)
      base_uri = config.parse_github_uri
      client = HTTP::Client.new(uri: base_uri)
      client.connect_timeout = 5.seconds
      client.write_timeout = 5.seconds
      client.read_timeout = 5.seconds
      response = client.get("/#{login}.keys")
      unless response.status == HTTP::Status::OK
        Log.warn { "Response for github user #{login} was not OK" }
        return [] of String
      end
      (response.body.split("\n") - [""]).map { |line| "#{line} #{login}" }
    end
  end

  alias User = GitHubUser | GitlabUser

  property fallback_key : String?
  property login_user : String?
  property users = [] of User
  property dir = Path.new("/tmp")

  property github_host = "github.com"
  property github_users = [] of String
  property github_teams = [] of String
  property github_token : String?

  property gitlab_host = "gitlab.com"
  property gitlab_users = [] of String
  property gitlab_token : String?
  property gitlab_groups = [] of String

  property force = false
  property ttl = Time::Span.new(hours: 1)

  # Parse GitHub host, supporting both bare hostnames and full URLs
  def parse_github_uri : URI
    if github_host.includes?("://")
      URI.parse(github_host)
    else
      URI.parse("https://#{github_host}")
    end
  end

  # Parse GitLab host, supporting both bare hostnames and full URLs
  def parse_gitlab_uri : URI
    if gitlab_host.includes?("://")
      URI.parse(gitlab_host)
    else
      URI.parse("https://#{gitlab_host}")
    end
  end

  def file
    if login_user
      dir / "authorized_keys_#{login_user}"
    else
      dir / "authorized_keys"
    end
  end

  def github_teams_configured?
    github_teams.any? && github_token
  end

  def gitlab_groups_configured?
    gitlab_groups.any? && gitlab_token
  end

  def allowed_for_user?(name)
    login_user ? name == login_user : true
  end

  def outdated?
    info = File.info?(file)
    return true unless info
    (Time.utc - info.modification_time) > ttl
  end

  def update
    File.delete?(file) if force
    return unless outdated?

    update_users(github_users, GitHubUser)
    update_github_teams if github_teams_configured?

    update_users(gitlab_users, GitlabUser)
    update_gitlab_groups if gitlab_groups_configured?

    update_keys
  end

  def update_users(list, klass)
    self.users += list.map { |s|
      parts = s.strip.split(":")
      case parts.size
      when 1
        klass.new(parts[0])
      when 2
        klass.new(parts[0]) if allowed_for_user?(parts[1])
      end
    }.compact
  end

  def update_github_teams
    github_teams.each { |org_team|
      org, team = org_team.split("/")
      parts = team.split(":")
      if parts.size == 2
        update_github_team(org, parts[0]) if allowed_for_user?(parts[1])
      else
        update_github_team(org, team)
      end
    }
  end

  def update_github_team(org, team)
    params = URI::Params.encode({"per_page" => "100", "page" => "1"})
    base_uri = parse_github_uri
    api_host = base_uri.scheme == "https" && base_uri.host == "github.com" ? "api.github.com" : base_uri.host.not_nil!
    uri = URI.new(base_uri.scheme, api_host, base_uri.port, "/orgs/#{org}/teams/#{team}/members", params)

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
    unless response.status == HTTP::Status::OK
      Log.warn { "Response for #{uri.request_target} was not OK" }
      return
    end
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

  def update_gitlab_groups
    gitlab_groups.each { |group|
      parts = group.split(":")
      if parts.size == 2
        update_gitlab_group(parts[0]) if allowed_for_user?(parts[1])
      else
        update_gitlab_group(group)
      end
    }
  end

  def update_gitlab_group(group)
    base_uri = parse_gitlab_uri
    uri = URI.new(base_uri.scheme, base_uri.host, base_uri.port, "/api/v4/groups/#{group}/members/all")

    client = HTTP::Client.new(uri: uri)
    client.read_timeout = 5.seconds
    client.before_request do |request|
      request.headers["PRIVATE-TOKEN"] = gitlab_token.not_nil!
    end

    update_gitlab_group_page(client, uri)
  end

  def update_gitlab_group_page(client, uri, page = 1)
    params = URI::Params.encode({"per_page" => "100", "page" => page.to_s, "state" => "active"})
    uri.query = params
    response = client.get(uri.request_target)
    unless response.status == HTTP::Status::OK
      Log.warn { "Response from #{uri.request_target} was not OK" }
      return
    end

    users.concat Array(GitlabUser).from_json(response.body)

    if (next_page = response.headers["x-next-page"]?) && next_page != ""
      update_gitlab_group_page(client, uri, next_page.to_i)
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

  def parallel_keys(channel, user)
    result = user.keys(self, channel)
  rescue ex
    Log.error(exception: ex) { "Failed to fetch key for #{user}" }
  ensure
    if result
      channel.send(result)
    elsif ex
      channel.send(ex)
    end
  end

  def update_keys
    users.sort!
    users.uniq!

    if users.empty?
      Log.debug { "No users matching this login name" }
      File.delete?(file)
      return
    end

    Log.debug { "Updating #{file} file for #{users.inspect}" }

    channel = Channel(Array(String) | Exception).new

    users.each do |user|
      spawn parallel_keys(channel, user), name: user.inspect
    end

    success = 0

    File.open("#{file}.tmp", "w+") do |fd|
      users.each do |user|
        case recv = channel.receive
        in Array(String)
          recv.each do |line|
            success += 1
            fd.puts(line)
          end
        in Exception
          Log.error(exception: recv) { "Updating keys for #{user}" }
        end
      end
    end

    channel.close

    if success == 0
      Log.warn { "No user keys found." }

      if fallback = fallback_key
        File.write("#{file}.tmp", fallback)
        Log.warn { "Using fallback key: #{fallback.inspect}" }
      else
        Log.warn { "Will not update." }
        return
      end
    end

    File.rename("#{file}.tmp", file)
  rescue ex
    Log.error(exception: ex) { "Updating keys" }
  end

  def output
    return unless File.file?(file)

    # File is already filtered to contain only keys for this Unix user
    puts File.read(file)
  end
end

def read_file(file)
  File.read(file).strip
rescue ex
  Log.error(exception: ex) { "reading file #{file}" }
  nil
end
