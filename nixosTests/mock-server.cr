require "http/server"
require "json"

# Mock HTTP server for GitHub and GitLab APIs
class MockServer
  def initialize(@responses_dir : String)
  end

  def handle_request(context)
    path = context.request.path
    host = context.request.headers["Host"]? || ""

    response_data = case {host, path}
    # GitHub public keys endpoints
    when {/github/, "/alice.keys"}
      {file: "github/alice.keys", type: "text/plain"}
    when {/github/, "/bob.keys"}
      {file: "github/bob.keys", type: "text/plain"}

    # GitHub API team members (can be on same host in test environment)
    when {/github/, %r{/orgs/testorg/teams/testteam/members}}
      {file: "github/teams-page1.json", type: "application/json"}

    # GitLab API user keys
    when {/gitlab/, "/api/v4/users/charlie/keys"}
      {file: "gitlab/charlie-keys.json", type: "application/json"}
    when {/gitlab/, "/api/v4/users/dave/keys"}
      {file: "gitlab/dave-keys.json", type: "application/json"}
    when {/gitlab/, "/api/v4/users/expired/keys"}
      {file: "gitlab/expired-keys.json", type: "application/json"}

    # GitLab API group members
    when {/gitlab/, %r{/api/v4/groups/testgroup/members/all}}
      {file: "gitlab/group-page1.json", type: "application/json"}

    else
      nil
    end

    if response_data
      file_path = File.join(@responses_dir, response_data[:file])
      if File.exists?(file_path)
        context.response.content_type = response_data[:type]
        context.response.print File.read(file_path)
      else
        context.response.status = HTTP::Status::NOT_FOUND
        context.response.print "Mock file not found: #{file_path}"
      end
    else
      context.response.status = HTTP::Status::NOT_FOUND
      context.response.print "No mock response for: #{host}#{path}"
    end
  end
end

# Read port and responses directory from command line
port = (ARGV[0]? || "8080").to_i
responses_dir = ARGV[1]? || "./mock-responses"

server = MockServer.new(responses_dir)

puts "Starting mock server on port #{port}"
puts "Serving responses from: #{responses_dir}"

http_server = HTTP::Server.new do |context|
  begin
    server.handle_request(context)
  rescue ex
    context.response.status = HTTP::Status::INTERNAL_SERVER_ERROR
    context.response.print "Error: #{ex.message}"
  end
end

http_server.bind_tcp("0.0.0.0", port)
http_server.listen
