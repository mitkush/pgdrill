require "digest"
require "open3"
require "zlib"

module Pgdrill
  class BackupFile
    FORMATS = %i[custom directory tar plain plain_gz].freeze

    attr_reader :path, :format

    def initialize(path)
      raise Error, "backup not found: #{path}" unless File.exist?(path)
      @path = path
      @format = detect
    end

    def size = File.directory?(path) ? Dir.glob(File.join(path, "*")).sum { File.size(_1) } : File.size(path)

    def sha256 = File.directory?(path) ? nil : Digest::SHA256.file(path).hexdigest

    def archive? = %i[custom directory tar].include?(format)

    # "16.4" style versions of the server the dump came from and the pg_dump that wrote it.
    def versions
      @versions ||= if archive?
        # An unreadable table of contents is a broken backup, not a tool error: let the restore report it.
        # The exception is an archive format newer than this pg_restore understands (written by a newer pg_dump).
        toc, err, _st = Open3.capture3("pg_restore", "-l", path)
        { from: toc[/Dumped from database version: (\S+)/, 1], by: toc[/Dumped by pg_dump version: (\S+)/, 1],
          newer_archive: err[/unsupported version \(([\d.]+)\) in file header/, 1] }
      else
        head = each_sql_line.first(40).join
        { from: head[/Dumped from database version (\S+)/, 1], by: head[/Dumped by pg_dump version (\S+)/, 1] }
      end
    end

    def major = versions[:from].to_s[/\A\d+/]&.to_i

    def pg_dump_major = versions[:by].to_s[/\A\d+/]&.to_i

    # A newer pg_dump writes archive versions / SET commands an older server or pg_restore can't read,
    # so the restore side must be at least as new as both the source server and pg_dump.
    def required_major = [major, pg_dump_major].compact.max

    # Schema-only SQL: for archives pg_restore renders just the DDL (cheap, no table data).
    def each_ddl_line(&block)
      return each_sql_line(&block) unless archive?
      Open3.popen2("pg_restore", "--schema-only", "-f", "-", path, err: File::NULL) do |_in, out, wait|
        out.each_line(&block)
        wait.value # a truncated archive just yields fewer lines; the restore reports the damage
      end
    end

    def each_sql_line(&block)
      return enum_for(:each_sql_line) unless block
      if format == :plain_gz
        Zlib::GzipReader.open(path) { |gz| gz.each_line(&block) }
      else
        File.foreach(path, &block)
      end
    end

    ROLE = /"[^"]+"|[\w$]+/
    ROLE_LIST = /(?:#{ROLE})(?:, *(?:#{ROLE}))*/

    # Roles the dump refers to. Row-level security policies (e.g. Supabase's `TO authenticated`)
    # need their roles to exist even with --no-owner --no-privileges, and plain SQL can't skip
    # ownership at all, so the restorer pre-creates these as NOLOGIN roles on the throwaway server.
    def referenced_roles
      roles = []
      each_ddl_line do |l|
        next unless l.start_with?("ALTER ", "GRANT ", "REVOKE ", "CREATE POLICY ")
        l.scan(/OWNER TO (#{ROLE});/) { roles << _1[0] }
        l.scan(/FOR ROLE (#{ROLE_LIST})/) { roles.concat(_1[0].split(/, */)) }
        l.scan(/\b(?:TO|FROM) (#{ROLE_LIST})(?: WITH GRANT OPTION)?(?=;| USING\b| WITH CHECK\b)/) { roles.concat(_1[0].split(/, */)) }
      end
      roles.map(&:strip).uniq.reject { |r| RESERVED_ROLES.include?(r.upcase) || r.delete('"').start_with?("pg_") }
    end

    # pg_* names are reserved/built in (e.g. pg_database_owner owns public on Postgres 15+).
    RESERVED_ROLES = %w[PUBLIC POSTGRES CURRENT_USER SESSION_USER CURRENT_ROLE].freeze

    private

    def detect
      return :directory if File.directory?(path) && File.exist?(File.join(path, "toc.dat"))
      raise Error, "#{path} is a directory but not a pg_dump directory archive (no toc.dat)" if File.directory?(path)

      head = File.binread(path, 512) || ""
      return :custom if head.start_with?("PGDMP")
      return :tar if head.bytesize >= 262 && head[257, 5] == "ustar"
      if head.start_with?("\x1f\x8b".b)
        inner = Zlib::GzipReader.open(path) { _1.read(5) }
        raise Error, "#{path} is a gzipped custom-format archive; gunzip it first (custom format is already compressed)" if inner == "PGDMP"
        return :plain_gz
      end
      :plain
    end
  end
end
