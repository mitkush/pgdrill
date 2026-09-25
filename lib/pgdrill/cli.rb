require "optparse"

module Pgdrill
  class CLI
    EXIT_OK = 0
    EXIT_FAIL = 1
    EXIT_ERROR = 2

    USAGE = <<~TXT
      Usage:
        pgdrill run BACKUP [options]        restore BACKUP into a throwaway server and verify it
        pgdrill baseline --db URL [options] record what production looks like (run right after the backup)
        pgdrill version

      Run `pgdrill run --help` or `pgdrill baseline --help` for options.
    TXT

    def self.start(argv, out: $stdout, err: $stderr) = new(out, err).call(argv)

    def initialize(out, err)
      @out, @err = out, err
    end

    def call(argv)
      cmd = argv.shift
      case cmd
      when "run" then run(argv)
      when "baseline" then baseline(argv)
      when "version", "--version", "-v" then @out.puts(VERSION) || EXIT_OK
      when nil, "help", "--help", "-h" then @out.puts(USAGE) || EXIT_OK
      else
        @err.puts "pgdrill: unknown command #{cmd.inspect}\n\n#{USAGE}"
        EXIT_ERROR
      end
    rescue Error, OptionParser::ParseError => e
      @err.puts "pgdrill: #{e.message}"
      EXIT_ERROR
    end

    private

    def baseline(argv)
      o = { output: "baseline.json", exact_row_limit: Baseline::DEFAULT_EXACT_ROW_LIMIT, statement_timeout: "30s" }
      parser = OptionParser.new do |p|
        p.banner = "Usage: pgdrill baseline --db URL [options]\n\nReads catalog metadata and small/indexed data only; safe for production and read replicas."
        p.on("--db URL", "Production or replica connection URL (or PGDRILL_DB env var)") { o[:db] = _1 }
        p.on("-o", "--output FILE", "Where to write the baseline (default baseline.json)") { o[:output] = _1 }
        p.on("--exact-row-limit N", Integer, "Count rows exactly only in tables smaller than N (default #{o[:exact_row_limit]}); larger tables use planner estimates") { o[:exact_row_limit] = _1 }
        p.on("--statement-timeout DURATION", "Per-query timeout on production (default 30s)") { o[:statement_timeout] = _1 }
      end
      parser.parse!(argv)
      url = o[:db] || ENV["PGDRILL_DB"] or raise Error, "baseline needs --db URL (or PGDRILL_DB)"
      snap = capture_baseline(url, o)
      Baseline.save(snap, o[:output])
      @out.puts "baseline written to #{o[:output]}: #{snap['tables'].size} tables, #{snap['schema'].size} schema objects, " \
                "#{snap['freshness'].size} indexed timestamp columns, #{snap['sequences'].size} sequences"
      EXIT_OK
    end

    def run(argv)
      o = { jobs: 4, format: "text", amcheck: true, lag_tolerance: Checks::DEFAULTS[:lag_tolerance],
            exact_row_limit: Baseline::DEFAULT_EXACT_ROW_LIMIT, statement_timeout: "30s" }
      parser = OptionParser.new do |p|
        p.banner = "Usage: pgdrill run BACKUP [options]\n\nBACKUP: pg_dump custom (-Fc), directory (-Fd) or tar (-Ft) archive, or plain .sql / .sql.gz"
        p.on("--baseline FILE", "Compare against a baseline written by `pgdrill baseline`") { o[:baseline] = _1 }
        p.on("--baseline-db URL", "Capture the baseline live from production/replica (read-only)") { o[:baseline_db] = _1 }
        p.on("--target URL", "Restore into this server instead of a throwaway local one (needs CREATE DATABASE)") { o[:target] = _1 }
        p.on("--max-age DURATION", "Fail if the newest restored data is older than this, e.g. 26h") { o[:max_age] = Duration.parse(_1) }
        p.on("--lag-tolerance DURATION", "How far restored data may trail the baseline (default 5m)") { o[:lag_tolerance] = Duration.parse(_1) }
        p.on("-j", "--jobs N", Integer, "Parallel restore jobs (default 4)") { o[:jobs] = _1 }
        p.on("--no-amcheck", "Skip index corruption checks") { o[:amcheck] = false }
        p.on("--sha256", "Include the backup's SHA-256 in the report") { o[:sha256] = true }
        p.on("--format FORMAT", %w[text json], "text (default) or json") { o[:format] = _1 }
        p.on("--output FILE", "Also write the JSON report to FILE") { o[:output] = _1 }
        p.on("--keep", "Keep the restored database (and server) for inspection") { o[:keep] = true }
      end
      parser.parse!(argv)
      path = argv.shift or raise Error, "run needs a BACKUP path\n\n#{parser.help}"
      raise Error, "use either --baseline or --baseline-db, not both" if o[:baseline] && o[:baseline_db]

      backup = BackupFile.new(path)
      base, base_source = load_baseline(o)
      report = drill(backup, base, base_source, o)

      @out.puts(o[:format] == "json" ? report.to_json : report.to_text)
      File.write(o[:output], report.to_json) if o[:output]
      report.verdict == "FAIL" ? EXIT_FAIL : EXIT_OK
    end

    def drill(backup, base, base_source, o)
      cluster = nil
      admin =
        if o[:target]
          Db.new(o[:target], label: "target")
        else
          cluster = Cluster.new
          if backup.major && cluster.major < backup.major
            raise Error, "backup was made by Postgres #{backup.major} but the local server is Postgres #{cluster.major}; " \
                         "use a newer Postgres (or the pgdrill Docker image for #{backup.major}), or pass --target"
          end
          ENV["PATH"] = "#{Cluster.bindir}#{File::PATH_SEPARATOR}#{ENV['PATH']}"
          @err.puts "starting throwaway Postgres #{cluster.major}…" if o[:format] == "text"
          Db.new(cluster.start.url, label: "throwaway")
        end

      restorer = Restorer.new(admin, jobs: o[:jobs])
      @err.puts "restoring #{backup.path}…" if o[:format] == "text"
      result = restorer.restore(backup)
      restored = nil
      if result[:ok]
        insp = Inspector.new(result[:db])
        restored = Baseline.capture(insp, like: base, exact_row_limit: o[:exact_row_limit], indexed_freshness: false)
        restored["amcheck"] = insp.amcheck if o[:amcheck]
      end
      findings = Checks.run(restore: result, restored: restored, baseline: base,
                            max_age: o[:max_age], lag_tolerance: o[:lag_tolerance])
      Report.new(backup: backup, baseline_source: base_source, baseline: base, restore: result,
                 restored: restored, findings: findings, options: o)
    ensure
      if o[:keep] && result
        @err.puts "kept restored database #{result[:name]}"
        @err.puts "  connect: psql postgresql://postgres@127.0.0.1:#{cluster.port}/#{result[:name]}\n  stop:    #{cluster.stop_command}" if cluster
      else
        restorer&.drop(result) if result && o[:target]
        cluster&.stop
      end
    end

    def load_baseline(o)
      return [Baseline.load(o[:baseline]), o[:baseline]] if o[:baseline]
      return [capture_baseline(o[:baseline_db], o), "live (#{Db.new(o[:baseline_db]).label})"] if o[:baseline_db]
      [nil, nil]
    end

    def capture_baseline(url, o)
      db = Db.new(url, read_only: true, statement_timeout: o[:statement_timeout])
      Baseline.capture(Inspector.new(db), exact_row_limit: o[:exact_row_limit], indexed_freshness: true)
    end
  end
end
