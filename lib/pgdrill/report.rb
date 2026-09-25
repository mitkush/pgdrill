require "json"
require "time"

module Pgdrill
  # Renders a drill result. The JSON form doubles as audit evidence: measured
  # restore time (RTO) and data age (RPO) with timestamps.
  class Report
    def initialize(backup:, baseline_source:, baseline:, restore:, restored:, findings:, options:, source: nil, now: Time.now.utc)
      @backup, @source, @baseline_source, @baseline = backup, source, baseline_source, baseline
      @restore, @restored, @findings, @options, @now = restore, restored, findings, options, now
    end

    def verdict = Checks.verdict(@findings)

    def to_h
      newest = @restored && Baseline.newest(@restored)
      base_newest = @baseline && Baseline.newest(@baseline)
      {
        "verdict" => verdict,
        "pgdrill" => VERSION,
        "ran_at" => @now.iso8601,
        "backup" => { "location" => @source ? @source.display : @backup.path, "format" => @backup.format.to_s,
                      "bytes" => @backup.size, "sha256" => @options[:sha256] ? @backup.sha256 : nil,
                      "dumped_from" => @backup.versions[:from], "pg_dump" => @backup.versions[:by],
                      "download_seconds" => @source&.dir ? @source.seconds : nil },
        "baseline" => @baseline && { "source" => @baseline_source, "captured_at" => @baseline["captured_at"],
                                     "database" => @baseline["database"] },
        "evidence" => {
          "restore_ok" => @restore[:ok],
          "restore_seconds" => @restore[:seconds],
          "newest_data" => newest&.iso8601,
          "data_age_seconds" => newest && (@now - newest).round,
          "lag_behind_baseline_seconds" => (newest && base_newest) ? (base_newest - newest).round : nil,
          "tables" => @restored&.dig("tables")&.size,
          "schema_objects" => @restored&.dig("schema")&.size,
          "indexes_checked" => @restored&.dig("amcheck", "checked"),
          "custom_checks" => @restored && { "total" => Array(@restored["custom"]).size,
                                            "passed" => Array(@restored["custom"]).count { _1["ok"] } }
        },
        "findings" => @findings.map(&:to_h)
      }
    end

    def to_json(*) = JSON.pretty_generate(to_h)

    def to_text
      out = ["pgdrill #{VERSION}", "backup    #{backup_line}", "baseline  #{baseline_line}", ""]
      check_rows.each { |label, text| out << "#{label.ljust(10)}#{text}" }
      notable = @findings.reject { _1.severity == :info }
      if notable.any?
        out << ""
        notable.first(20).each { out << "  #{_1.severity.to_s.upcase.ljust(8)} #{_1.check}: #{_1.message}" }
        out << "  … #{notable.size - 20} more (use --format json for all)" if notable.size > 20
      end
      infos = @findings.select { _1.severity == :info }
      unless infos.empty?
        out << ""
        infos.first(5).each { out << "  note     #{_1.check}: #{_1.message}" }
      end
      (out << "" << verdict).join("\n")
    end

    def to_markdown
      out = ["### pgdrill: #{verdict}", "", "| check | result |", "|---|---|"]
      check_rows.each { |label, text| out << "| #{label} | #{md(text)} |" }
      notable = @findings.reject { _1.severity == :info }
      if notable.any?
        out << "" << "**Problems**" << ""
        notable.first(30).each { out << "- **#{_1.severity.to_s.upcase}** #{_1.check}: #{md(_1.message)}" }
        out << "- … #{notable.size - 30} more in the JSON report" if notable.size > 30
      end
      notes = @findings.select { _1.severity == :info }
      if notes.any?
        out << "" << "**Notes**" << ""
        notes.first(5).each { out << "- #{_1.check}: #{md(_1.message)}" }
      end
      out << "" << "<sub>backup #{md(backup_line)} · baseline #{md(baseline_line)} · pgdrill #{VERSION}</sub>" << ""
      out.join("\n")
    end

    private

    def backup_line
      b = to_h["backup"]
      fetched = b["download_seconds"] ? ", downloaded in #{Duration.human(b['download_seconds'])}" : ""
      "#{b['location']} (#{b['format']}, #{human_bytes(b['bytes'])}, from Postgres #{b['dumped_from'] || '?'}#{fetched})"
    end

    def baseline_line
      @baseline ? "#{@baseline_source} (captured #{@baseline['captured_at']})" : "none (self-consistency checks only; pass --baseline for full checks)"
    end

    def check_rows
      e = to_h["evidence"]
      rows = [["restore", e["restore_ok"] ? "ok in #{Duration.human(e['restore_seconds'])}" : "FAILED after #{Duration.human(e['restore_seconds'])}"]]
      return rows unless e["restore_ok"]
      rows << ["schema", @baseline ? status("schema", "#{e['schema_objects']} objects match production") : "not compared (no baseline)"]
      rows << ["rows", @baseline ? status("rows", "#{e['tables']} tables within tolerance") : "#{e['tables']} table#{'s' unless e['tables'] == 1} restored"]
      rows << ["freshness", status("freshness", e["newest_data"] ? "newest data #{e['newest_data']} (#{Duration.human(e['data_age_seconds'])} old)" : "no timestamp columns found")]
      rows << ["sequences", status("sequences", "#{@restored['sequences'].size} checked")]
      rows << ["amcheck", status("amcheck", @restored.dig("amcheck", "available") ? "#{e['indexes_checked']} indexes clean" : "not run")]
      custom = Array(@restored["custom"])
      rows << ["custom", status("custom", "#{custom.size} check#{'s' unless custom.size == 1} passed")] if custom.any?
      rows
    end

    def status(check, ok_text)
      bad = @findings.select { _1.check == check && _1.severity != :info }
      return ok_text if bad.empty?
      worst = bad.any? { _1.severity == :critical } ? "FAIL" : "WARN"
      "#{worst}: #{bad.size} problem#{'s' if bad.size > 1} (see below)"
    end

    def md(s) = s.to_s.gsub("|", "\\|").gsub("<", "&lt;").gsub(">", "&gt;")

    def human_bytes(n)
      return "?" unless n
      units = %w[B KB MB GB TB]
      i = n.zero? ? 0 : [(Math.log(n) / Math.log(1024)).floor, units.size - 1].min
      "#{(n / 1024.0**i).round(1)} #{units[i]}"
    end
  end
end
