require "json"
require "net/http"
require "uri"

module Pgdrill
  # Posts the outcome to a webhook: Slack-compatible {"text": ...} by default, or the full
  # JSON report. A failing webhook only warns; it never changes pgdrill's exit code.
  class Notifier
    FORMATS = %w[slack json].freeze
    WHEN = %w[problems always].freeze

    def initialize(url, format: "slack", on: "problems", err: $stderr)
      raise Error, "--webhook-format must be one of #{FORMATS.join(', ')}" unless FORMATS.include?(format)
      raise Error, "--notify must be one of #{WHEN.join(', ')}" unless WHEN.include?(on)
      @uri = URI.parse(url)
      raise Error, "--webhook must be an http(s) URL" unless @uri.is_a?(URI::HTTP)
      @format, @on, @err = format, on, err
    end

    # verdict: PASS/WARN/FAIL, or ERROR when pgdrill couldn't run the drill.
    def notify(verdict:, text:, report: nil)
      return if @on == "problems" && verdict == "PASS"
      body = @format == "json" ? { "verdict" => verdict, "message" => text, "report" => report } : { "text" => text }
      res = Net::HTTP.start(@uri.host, @uri.port, use_ssl: @uri.scheme == "https", open_timeout: 10, read_timeout: 10) do |http|
        http.post(@uri.request_uri, JSON.generate(body), "Content-Type" => "application/json")
      end
      @err.puts "pgdrill: webhook to #{@uri.host} returned HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)
    rescue StandardError => e
      # the URL itself is a secret (Slack webhooks), so only the host is ever printed
      @err.puts "pgdrill: webhook to #{@uri.host} failed: #{e.class}: #{e.message}"
    end

    def self.summary(report_hash)
      where = report_hash.dig("backup", "location")
      problems = report_hash["findings"].reject { _1["severity"] == "info" }
      head = "pgdrill #{report_hash['verdict']} for #{where}"
      return "#{head}: restored in #{report_hash.dig('evidence', 'restore_seconds')}s, all checks passed" if problems.empty?
      lines = problems.first(3).map { "• #{_1['check']}: #{_1['message']}" }
      lines << "• …and #{problems.size - 3} more" if problems.size > 3
      "#{head}\n#{lines.join("\n")}"
    end
  end
end
