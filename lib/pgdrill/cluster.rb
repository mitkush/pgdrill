require "fileutils"
require "open3"
require "securerandom"
require "socket"
require "tmpdir"

module Pgdrill
  # A disposable Postgres server for restores. Durability is off because the
  # whole cluster is deleted afterwards; that makes restores much faster.
  class Cluster
    SETTINGS = {
      "listen_addresses" => "127.0.0.1",
      "unix_socket_directories" => "''", # socket paths under long tmpdirs exceed the 107-byte limit
      "fsync" => "off",
      "synchronous_commit" => "off",
      "full_page_writes" => "off",
      "max_wal_size" => "4GB",
      "checkpoint_timeout" => "30min",
      "maintenance_work_mem" => "512MB"
    }.freeze

    attr_reader :port, :major, :dir

    def stop_command = "#{File.join(@bin, 'pg_ctl')} -D #{data} stop && rm -rf #{@dir}"

    # Prefer the initdb on PATH (lets users pick a version by PATH order); pg_config can point
    # at a different installed version on multi-version hosts.
    def self.bindir
      on_path = ENV["PATH"].to_s.split(File::PATH_SEPARATOR).find { File.executable?(File.join(_1, "initdb")) }
      return on_path if on_path
      out, st = (Open3.capture2("pg_config", "--bindir") rescue [nil, nil])
      dir = st&.success? ? out.strip : nil
      return dir if dir && File.executable?(File.join(dir, "initdb"))
      raise Error, "Postgres server binaries (initdb, pg_ctl) not found; install Postgres, use the pgdrill Docker image, or pass --target"
    end

    def initialize(bindir: self.class.bindir)
      @bin = bindir
      out, = Open3.capture2(File.join(@bin, "postgres"), "--version")
      @major = out[/(\d+)(?:\.\d+)?/, 1].to_i
    end

    # The restored data is a copy of production, so other local users must not be able to read it:
    # password auth with a random secret, and the data directory is private (initdb uses 0700).
    def start
      @dir = Dir.mktmpdir("pgdrill-")
      @port = free_port
      @password = SecureRandom.hex(24)
      pwfile = File.join(@dir, "pw")
      File.write(pwfile, @password, perm: 0o600)
      run!("initdb", "-D", data, "-U", "postgres", "--auth=scram-sha-256", "--pwfile", pwfile, "--no-locale", "-E", "UTF8")
      File.delete(pwfile)
      opts = SETTINGS.merge("port" => @port.to_s).map { |k, v| "-c #{k}=#{v}" }.join(" ")
      run!("pg_ctl", "-D", data, "-l", File.join(@dir, "server.log"), "-o", opts, "-w", "-t", "60", "start")
      self
    end

    def url(database = "postgres") = "postgresql://postgres:#{@password}@127.0.0.1:#{@port}/#{database}"

    def stop
      return unless @dir
      Open3.capture3(File.join(@bin, "pg_ctl"), "-D", data, "-m", "immediate", "stop")
      FileUtils.rm_rf(@dir)
      @dir = nil
    end

    private

    def data = File.join(@dir, "data")

    def free_port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }

    def run!(cmd, *args)
      out, st = Open3.capture2e(File.join(@bin, cmd), *args)
      raise Error, "#{cmd} failed: #{out.lines.last(3).join.strip}" unless st.success?
    end
  end
end
