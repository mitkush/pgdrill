require "open3"
require "optparse"

module Pgdrill
  class CLI
    EXIT_OK = 0
    EXIT_FAIL = 1
    EXIT_ERROR = 2

    USAGE = <<~TXT
      Usage:
        pgdrill run BACKUP [options]        restore BACKUP into a throwaway server and verify it
        pgdrill baseline --db URL [options] record what production looks like (run just before the backup)
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
        p.banner = "Usage: pgdrill baseline --db URL [options]\n\n" \
                   "Run it just before pg_dump starts: the backup must then contain everything the baseline saw.\n" \
                   "Reads catalog metadata and small/indexed data only; safe for production and read replicas.\n" \
                   "Keep passwords out of the command line: use PGDRILL_DB, PGPASSWORD or ~/.pgpass."
        p.on("--db URL", "Production or replica connection URL (default: PGDRILL_DB env var)") { o[:db] = _1 }
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
        p.banner = "Usage: pgdrill run BACKUP [options]\n\n" \
                   "BACKUP: pg_dump custom (-Fc), directory (-Fd) or tar (-Ft) archive, or plain .sql / .sql.gz, given as\n" \
                   "  a local path, s3://bucket/key (s3://bucket/prefix/ = newest object; AWS_* env credentials,\n" \
                   "  AWS_ENDPOINT_URL for R2/B2/other S3-compatible stores) or an https:// (e.g. presigned) URL"
        p.on("--latest", "Treat an s3:// location as a prefix and drill the newest backup under it") { o[:latest] = true }
        p.on("--baseline FILE", "Compare against a baseline written by `pgdrill baseline`") { o[:baseline] = _1 }
        p.on("--baseline-db URL", "Capture the baseline live from production/replica, read-only (or PGDRILL_BASELINE_DB).",
             "Only for drills right after the backup: data written since then counts against --lag-tolerance") { o[:baseline_db] = _1 }
        p.on("--target URL", "Restore into this server instead of a throwaway local one (or PGDRILL_TARGET).",
             "Needs CREATE DATABASE and CREATEROLE: roles the backup references are created as NOLOGIN") { o[:target] = _1 }
        p.on("--max-age DURATION", "Fail if the newest restored data is older than this, e.g. 26h") { o[:max_age] = Duration.parse(_1) }
        p.on("--lag-tolerance DURATION", "How far restored data may trail the baseline (default 5m)") { o[:lag_tolerance] = Duration.parse(_1) }
        p.on("-j", "--jobs N", Integer, "Parallel restore jobs (default 4)") { o[:jobs] = _1 }
        p.on("--no-amcheck", "Skip index corruption checks") { o[:amcheck] = false }
        p.on("--sha256", "Include the backup's SHA-256 in the report") { o[:sha256] = true }
        p.on("--format FORMAT", %w[text json], "text (default) or json") { o[:format] = _1 }
        p.on("--output FILE", "Also write the JSON report to FILE") { o[:output] = _1 }
        p.on("--summary FILE", "Append a Markdown report to FILE (e.g. $GITHUB_STEP_SUMMARY)") { o[:summary] = _1 }
        p.on("--fail-on-warn", "Exit 1 on WARN too, not only on FAIL") { o[:fail_on_warn] = true }
        p.on("--keep", "Keep the restored database (and server) for inspection") { o[:keep] = true }
      end
      parser.parse!(argv)
      o[:baseline_db] ||= ENV["PGDRILL_BASELINE_DB"] unless o[:baseline]
      o[:target] ||= ENV["PGDRILL_TARGET"]
      path = argv.shift or raise Error, "run needs a BACKUP path\n\n#{parser.help}"
      raise Error, "use either --baseline or --baseline-db, not both" if o[:baseline] && o[:baseline_db]

      base, base_source = load_baseline(o)
      fetched = Source.fetch(path, latest: o[:latest], log: o[:format] == "text" ? @err.method(:puts) : nil)
      backup = BackupFile.new(fetched.path)
      report = drill(backup, base, base_source, o, fetched)

      @out.puts(o[:format] == "json" ? report.to_json : report.to_text)
      File.write(o[:output], report.to_json) if o[:output]
      File.open(o[:summary], "a") { _1.puts(report.to_markdown) } if o[:summary]
      failing = o[:fail_on_warn] ? %w[FAIL WARN] : %w[FAIL]
      failing.include?(report.verdict) ? EXIT_FAIL : EXIT_OK
    ensure
      if fetched&.dir
        o[:keep] ? @err.puts("kept downloaded backup #{fetched.path}") : fetched.cleanup
      end
    end

    def drill(backup, base, base_source, o, fetched)
      cluster = nil
      admin =
        if o[:target]
          Db.new(o[:target], label: "target").tap do |db|
            ensure_new_enough!(backup, "the --target server", db.value("show server_version_num").to_i / 10_000)
            ensure_new_enough!(backup, "pg_restore on PATH", client_major("pg_restore")) if backup.archive?
          end
        else
          cluster = Cluster.new
          ENV["PATH"] = "#{Cluster.bindir}#{File::PATH_SEPARATOR}#{ENV['PATH']}" # restore with the matching pg_restore
          ensure_new_enough!(backup, "the local Postgres", cluster.major)
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
      Report.new(backup: backup, source: fetched, baseline_source: base_source, baseline: base, restore: result,
                 restored: restored, findings: findings, options: o)
    ensure
      if o[:keep] && result
        @err.puts "kept restored database #{result[:name]}"
        @err.puts "  connect: psql '#{cluster.url(result[:name])}'\n  stop:    #{cluster.stop_command}" if cluster
      else
        restorer&.drop(result) if result && o[:target]
        cluster&.stop
      end
    end

    # A too-old restore side would make a healthy backup look broken, so it's a tool error (exit 2), not a FAIL.
    def ensure_new_enough!(backup, what, have)
      if (fmt = backup.versions[:newer_archive])
        raise Error, "backup archive format #{fmt} was written by a newer pg_dump than this pg_restore " \
                     "(Postgres #{client_major('pg_restore')}) can read; use a newer pgdrill Docker image or Postgres"
      end
      need = backup.required_major or return
      return if have.to_i >= need
      raise Error, "backup needs Postgres #{need}+ to restore (source server #{backup.versions[:from] || '?'}, " \
                   "pg_dump #{backup.versions[:by] || '?'}) but #{what} is #{have}; " \
                   "use the pgdrill:pg#{need} Docker image or a newer Postgres"
    end

    def client_major(cmd)
      out, st = Open3.capture2(cmd, "--version")
      st.success? ? out[/(\d+)(?:\.\d+)?/, 1].to_i : 0
    rescue Errno::ENOENT
      raise Error, "#{cmd} not found on PATH"
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
