require "open3"
require "securerandom"

module Pgdrill
  class Restorer
    # Ownership, grants and tablespaces reference roles/paths that only exist on
    # the production server; restoring them would fail for reasons unrelated to
    # whether the data is intact.
    PG_RESTORE_FLAGS = %w[--no-owner --no-privileges --no-tablespaces --exit-on-error].freeze

    def initialize(admin, jobs: 4)
      @admin = admin
      @jobs = jobs
    end

    # Returns { ok:, error:, seconds:, db: } — db is the restored database (drop it with #drop).
    def restore(backup)
      name = "pgdrill_#{Time.now.utc.strftime('%Y%m%d%H%M%S')}_#{SecureRandom.hex(3)}"
      @admin.exec(%(create database "#{name}"))
      target = @admin.with_database(name)
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ok, err = backup.archive? ? pg_restore(backup, target, name) : psql_restore(backup, target)
      seconds = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(1)
      target.exec("analyze") if ok
      { ok: ok, error: ok ? nil : explain(err), seconds: seconds, db: target, name: name }
    end

    def drop(result) = @admin.exec(%(drop database if exists "#{result[:name]}" with (force)))

    private

    def pg_restore(backup, target, name)
      args = ["pg_restore", *PG_RESTORE_FLAGS, "-d", name]
      args += ["-j", @jobs.to_s] if @jobs > 1 && %i[custom directory].include?(backup.format)
      _out, err, st = Open3.capture3(target.env, *args, backup.path)
      [st.success?, err]
    end

    def psql_restore(backup, target)
      backup.referenced_roles.each do |role|
        quoted = role.start_with?('"') ? role : %("#{role}")
        @admin.exec("do $$ begin create role #{quoted} nologin; exception when duplicate_object then null; end $$")
      end
      err = +""
      status = Open3.popen3(target.env, "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", "-") do |stdin, stdout, stderr, wait|
        readers = [Thread.new { stdout.read }, Thread.new { err << stderr.read }]
        begin
          backup.each_sql_line { stdin.write(_1) }
        rescue Errno::EPIPE
          nil # psql stopped on the first error; its stderr says why
        ensure
          stdin.close unless stdin.closed?
        end
        readers.each(&:join)
        wait.value
      end
      [status.success?, err]
    end

    def explain(err)
      lines = err.to_s.lines.map(&:strip).reject(&:empty?)
      if (ext = err.to_s[%r{extension control file "[^"]*/([\w-]+)\.control"}, 1])
        return "the backup needs the '#{ext}' extension, which is not installed on the restore server (use a pgdrill image that includes it, or --target a server that has it)"
      end
      errors = lines.grep(/error/i).first(2)
      (errors.empty? ? lines.last(2) : errors).join(" | ")
    end
  end
end
