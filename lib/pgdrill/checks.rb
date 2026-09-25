require "time"

module Pgdrill
  Finding = Struct.new(:severity, :check, :message) do
    def to_h = { "severity" => severity.to_s, "check" => check, "message" => message }
  end

  # Pure comparison of a production baseline against the restored snapshot.
  module Checks
    DEFAULTS = {
      row_tolerance: 0.05,      # exact counts may drift this much (writes after backup)
      estimate_tolerance: 0.25, # planner estimates are coarse
      lag_tolerance: 300,       # seconds the restored data may trail the baseline
      max_age: nil              # seconds; optional "is the backup recent at all" gate
    }.freeze

    module_function

    def run(restore:, restored:, baseline: nil, now: Time.now.utc, config: Config.empty, **opts)
      o = DEFAULTS.merge(opts)
      return [Finding.new(:critical, "restore", "backup did not restore: #{restore[:error]}")] unless restore[:ok]

      findings = []
      findings.concat(schema(baseline, restored)) if baseline
      findings.concat(rows(baseline, restored, o, config)) if baseline
      findings.concat(custom(restored["custom"]))
      findings.concat(freshness(baseline, restored, now, o))
      findings.concat(sequences(baseline, restored))
      findings.concat(amcheck(restored["amcheck"]))
      findings.concat(production_notes(baseline)) if baseline
      findings
    end

    def verdict(findings)
      return "FAIL" if findings.any? { _1.severity == :critical }
      return "WARN" if findings.any? { _1.severity == :warning }
      "PASS"
    end

    def schema(baseline, restored)
      missing = baseline["schema"] - restored["schema"]
      return [] if missing.empty?
      tables = missing.filter_map { _1[/\Acolumn (\S+)\.[^.\s]+ /, 1] }.uniq
      detail = tables.any? ? "tables affected: #{tables.first(5).join(', ')}#{tables.size > 5 ? ', …' : ''}" : "e.g. #{missing.first}"
      [Finding.new(:critical, "schema", "#{missing.size} schema objects from production are missing (#{detail})")]
    end

    # An empty table where production has rows always fails, whatever the tolerance; only
    # ignore_tables skips a table entirely.
    def rows(baseline, restored, o, config = Config.empty)
      baseline["tables"].filter_map do |t, b|
        next if config.ignored?(t)
        r = restored["tables"][t] or next
        prod, got = b["rows"].to_i, r["rows"].to_i
        next unless prod.positive?
        if got.zero?
          Finding.new(:critical, "rows", "#{t}: restored 0 rows, production has #{prod}")
        else
          tol = config.table_tolerance[t] ||
                (b["method"] == "estimate" ? config.estimate_tolerance || o[:estimate_tolerance] : config.row_tolerance || o[:row_tolerance])
          off = (prod - got).abs.to_f / prod
          Finding.new(:warning, "rows", "#{t}: restored #{got} rows vs #{prod} in production (#{(off * 100).round(1)}% off)") if off > tol
        end
      end
    end

    def freshness(baseline, restored, now, o)
      f = []
      got = Baseline.newest(restored)
      if baseline && (want = Baseline.newest(baseline)) && got && (lag = want - got) > o[:lag_tolerance]
        f << Finding.new(:critical, "freshness",
                         "restored data ends #{Duration.human(lag)} before production's newest data (#{got.iso8601} vs #{want.iso8601})")
      end
      if o[:max_age]
        if got.nil?
          f << Finding.new(:warning, "freshness", "no timestamp columns found, cannot judge backup age")
        elsif (age = now - got) > o[:max_age]
          f << Finding.new(:critical, "freshness", "newest restored data is #{Duration.human(age)} old (limit #{Duration.human(o[:max_age])})")
        end
      end
      f
    end

    def custom(results)
      Array(results).reject { _1["ok"] }.map { Finding.new(:critical, "custom", "#{_1['name']}: #{_1['detail']}") }
    end

    def behind?(s) =s["max_id"].to_i.positive? && (s["last_value"].nil? || s["last_value"] < s["max_id"])

    def sequences(baseline, restored)
      prod = baseline ? baseline["sequences"].to_h { [[_1["seq"], _1["col"]], _1] } : {}
      restored["sequences"].filter_map do |s|
        next unless behind?(s)
        p = prod[[s["seq"], s["col"]]]
        # already this far behind in production: a production problem, reported separately, not a backup failure
        next if p && behind?(p) && p["last_value"].to_i <= s["last_value"].to_i
        msg = "#{s['seq']} is at #{s['last_value'] || 'unset'} but #{s['col']} goes up to #{s['max_id']}: the next INSERT will fail"
        msg += " (production: #{p['last_value'] || 'unset'})" if p
        Finding.new(baseline ? :critical : :warning, "sequences", msg)
      end
    end

    def amcheck(a)
      return [] unless a
      return [Finding.new(:info, "amcheck", "skipped: #{a['reason']}")] unless a["available"]
      a["corrupt"].map { Finding.new(:critical, "amcheck", "index corruption: #{_1}") } +
        a["skipped"].first(3).map { Finding.new(:info, "amcheck", "could not check #{_1}") }
    end

    def production_notes(baseline)
      f = []
      pre = baseline["sequences"].select { behind?(_1) }
      if pre.any?
        f << Finding.new(:info, "production",
                         "#{pre.size} sequence(s) are already behind their column in production, e.g. #{pre.first['seq']} (not a backup problem, but inserts may fail there)")
      end
      if (u = baseline["unreadable_tables"]).any?
        f << Finding.new(:info, "production", "#{u.size} table(s) were not readable by the baseline role and were not compared, e.g. #{u.first}")
      end
      f
    end
  end
end
