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
    def keys(config) : Array(String)
      client = config.http_client(config.parse_gitlab_uri)
      keys = [] of String
      page = "1"
      begin
        loop do
          params = URI::Params.encode({"per_page" => "100", "page" => page})
          response = client.get("/api/v4/users/#{username}/keys?#{params}")
          unless response.status == HTTP::Status::OK
            raise "GitLab keys for #{username}: HTTP #{response.status_code}"
          end
          keys.concat Array(GitlabUserKey).from_json(response.body).select(&.viable?).map { |key|
            "#{key.key} #{username}"
          }
          next_page = response.headers["x-next-page"]?
          break if next_page.nil? || next_page.empty?
          raise "Invalid GitLab keys pagination for #{username}" unless next_page.to_i > page.to_i
          page = next_page
        end
        keys
      ensure
        client.close
      end
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

    def keys(config) : Array(String)
      client = config.http_client(config.parse_github_uri)
      begin
        response = client.get("/#{login}.keys")
        unless response.status == HTTP::Status::OK
          raise "GitHub keys for #{login}: HTTP #{response.status_code}"
        end
        (response.body.split("\n") - [""]).map { |line| "#{line} #{login}" }
      ensure
        client.close
      end
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

  def http_client(uri)
    client = HTTP::Client.new(uri: uri)
    client.connect_timeout = 5.seconds
    client.write_timeout = 5.seconds
    client.read_timeout = 5.seconds
    client
  end

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
    return unless force || outdated?

    Log.debug { "Waiting to refresh #{file}" }
    # Keep this inode: deleting the lock file would let waiters lock different files.
    File.open("#{file}.lock", "a", perm: 0o600) do |lock|
      lock.flock_exclusive do
        # Another process may have completed the refresh while we waited.
        return unless force || outdated?
        self.users = [] of User
        update_users(github_users, GitHubUser)
        update_github_teams
        update_users(gitlab_users, GitlabUser)
        update_gitlab_groups
        update_keys
      end
    end
  rescue ex
    Log.error(exception: ex) { "Failed to refresh #{file}; preserving existing cache" }
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
    raise "GitHub team #{org}/#{team} requires a token" if github_token.nil? || github_token.try(&.empty?)
    params = URI::Params.encode({"per_page" => "100", "page" => "1"})
    base_uri = parse_github_uri
    api_host = base_uri.scheme == "https" && base_uri.host == "github.com" ? "api.github.com" : base_uri.host.not_nil!
    uri = URI.new(base_uri.scheme, api_host, base_uri.port, "/orgs/#{org}/teams/#{team}/members", params)

    client = http_client(uri)
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
  ensure
    client.try &.close
  end

  def update_github_team_page(client, uri)
    response = client.get(uri.request_target)
    unless response.status == HTTP::Status::OK
      raise "GitHub membership #{uri.request_target}: HTTP #{response.status_code}"
    end
    users.concat Array(GitHubUser).from_json(response.body)

    case response.headers["Link"]?
    when /<(?<url>[^>]+)>; rel="next"/
      update_github_team_page(client, URI.parse($~.try(&.["url"])))
    end
  rescue ex
    raise Exception.new("Failed to fetch GitHub membership #{uri.request_target}", cause: ex)
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
    raise "GitLab group #{group} requires a token" if gitlab_token.nil? || gitlab_token.try(&.empty?)
    base_uri = parse_gitlab_uri
    uri = URI.new(base_uri.scheme, base_uri.host, base_uri.port, "/api/v4/groups/#{group}/members/all")

    client = http_client(uri)
    client.before_request do |request|
      request.headers["PRIVATE-TOKEN"] = gitlab_token.not_nil!
    end

    update_gitlab_group_page(client, uri)
  ensure
    client.try &.close
  end

  def update_gitlab_group_page(client, uri, page = 1)
    params = URI::Params.encode({"per_page" => "100", "page" => page.to_s, "state" => "active"})
    uri.query = params
    response = client.get(uri.request_target)
    unless response.status == HTTP::Status::OK
      raise "GitLab membership #{uri.request_target}: HTTP #{response.status_code}"
    end

    users.concat Array(GitlabUser).from_json(response.body)

    if (next_page = response.headers["x-next-page"]?) && next_page != ""
      raise "Invalid GitLab membership pagination" unless next_page.to_i > page
      update_gitlab_group_page(client, uri, next_page.to_i)
    end
  rescue ex
    raise Exception.new("Failed to fetch GitLab membership #{uri.request_target}", cause: ex)
  end

  alias KeyResult = Tuple(User, Array(String) | Exception)

  def parallel_keys(channel, user)
    result = begin
      user.keys(self)
    rescue ex
      ex
    end
    channel.send({user, result})
  end

  def update_keys
    users.sort!
    users.uniq!
    Log.debug { "Updating #{file} file for #{users.inspect}" }

    channel = Channel(KeyResult).new
    users.each do |user|
      spawn parallel_keys(channel, user), name: user.inspect
    end

    keys = [] of String
    failed = false
    # Drain every result, even after failure, so no worker remains blocked.
    users.size.times do
      user, result = channel.receive
      case result
      in Array(String)
        Log.debug { "Fetched keys for #{user.to_s}" }
        keys.concat(result)
      in Exception
        failed = true
        Log.error(exception: result) { "Failed to fetch keys for #{user.to_s}" }
      end
    end
    channel.close
    raise "One or more key requests failed" if failed

    # An empty successful snapshot is authoritative and revokes old access.
    # A unique file in the cache directory keeps rename atomic on this filesystem.
    temporary = File.tempfile(file.basename, ".tmp", dir: dir.to_s)
    begin
      keys.sort.each { |key| temporary.puts(key) }
      temporary.flush
      temporary.fsync
      temporary.close
      File.rename(temporary.path, file)
    ensure
      temporary.close
      File.delete?(temporary.path)
    end
  end

  # Fallback is independently configured access, always served and never cached.
  # Emit it before reading the cache so a cache failure cannot suppress it.
  def output(io : IO = STDOUT) : Bool
    served_fallback = false
    if fallback = fallback_key
      unless fallback.empty?
        io.puts(fallback)
        served_fallback = true
      end
    end

    begin
      return served_fallback unless File.exists?(file)

      io << File.read(file)
      true
    rescue ex
      # File logging may itself be broken; keep this error path independent.
      STDERR.puts "Failed to read cache #{file}: #{ex.message}"
      served_fallback
    end
  end
end

def read_file(file)
  File.read(file).strip
rescue ex
  Log.error(exception: ex) { "reading file #{file}" }
  nil
end
