require "json"
require "open3"
require "uri"

module Pgdrill
  # Talks to Postgres through psql so pgdrill has no native gem dependencies.
  # Credentials travel via libpq environment variables, never argv, so they
  # don't show up in `ps` output.
  class Db
    class QueryError < Error; end

    attr_reader :label

    def initialize(url, label: nil, read_only: false, statement_timeout: nil)
      @env = self.class.env_for(url)
      @label = label || "#{@env['PGHOST']}:#{@env['PGPORT']}/#{@env['PGDATABASE']}"
      opts = []
      opts << "-c default_transaction_read_only=on" if read_only
      opts << "-c statement_timeout=#{statement_timeout}" if statement_timeout
      @env["PGOPTIONS"] = opts.join(" ") unless opts.empty?
    end

    def self.env_for(url)
      uri = URI.parse(url)
      raise Error, "unsupported URL scheme: #{uri.scheme}" unless %w[postgres postgresql].include?(uri.scheme)

      params = URI.decode_www_form(uri.query.to_s).to_h
      env = {
        "PGHOST" => uri.host || "127.0.0.1",
        "PGPORT" => (uri.port || 5432).to_s,
        "PGUSER" => uri.user ? URI.decode_www_form_component(uri.user) : ENV.fetch("PGUSER", "postgres"),
        "PGDATABASE" => uri.path.to_s.delete_prefix("/").then { _1.empty? ? "postgres" : URI.decode_www_form_component(_1) },
        "PGTZ" => "UTC",
        "PGAPPNAME" => "pgdrill",
        "PGCONNECT_TIMEOUT" => "10"
      }
      env["PGPASSWORD"] = URI.decode_www_form_component(uri.password) if uri.password
      env["PGSSLMODE"] = params["sslmode"] if params["sslmode"]
      env
    end

    def env = @env.dup

    def with_database(name) = dup.tap { _1.instance_variable_set(:@env, @env.merge("PGDATABASE" => name)) }

    SEP = "\x1f" # field separator for unaligned output; can't appear in normal values

    # First column of the first row, or nil for no rows / NULL. For user-written check queries.
    def first_value(sql, timeout: "10min")
      line = exec("set statement_timeout = '#{timeout}';\n#{sql}").lines.first&.chomp
      v = line&.split(SEP, 2)&.first
      v.nil? || v.empty? ? nil : v
    end

    def exec(sql)
      out, err, st = Open3.capture3(@env, "psql", "-X", "-q", "-At", "-F", SEP, "-v", "ON_ERROR_STOP=1", "-c", sql)
      raise QueryError, err.lines.grep(/ERROR|FATAL|error/).first.to_s.strip.then { _1.empty? ? err.strip : _1 } unless st.success?
      out.strip
    end

    # setup runs in the same session first (e.g. creating pg_temp helpers); -q hides its command tags.
    def rows(sql, setup: nil)
      JSON.parse(exec("#{setup}\nselect coalesce(json_agg(x), '[]'::json) from (#{sql}) x"))
    end

    def value(sql) = exec(sql)
  end
end
