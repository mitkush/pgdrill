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
        toc, _err, _st = Open3.capture3("pg_restore", "-l", path)
        { from: toc[/Dumped from database version: (\S+)/, 1], by: toc[/Dumped by pg_dump version: (\S+)/, 1] }
      else
        head = each_sql_line.first(40).join
        { from: head[/Dumped from database version (\S+)/, 1], by: head[/Dumped by pg_dump version (\S+)/, 1] }
      end
    end

    def major = versions[:from].to_s[/\A\d+/]&.to_i

    def each_sql_line(&block)
      return enum_for(:each_sql_line) unless block
      if format == :plain_gz
        Zlib::GzipReader.open(path) { |gz| gz.each_line(&block) }
      else
        File.foreach(path, &block)
      end
    end

    # Plain-SQL dumps can't skip ownership/grants like pg_restore --no-owner, so the
    # restorer pre-creates the roles they mention.
    def referenced_roles
      roles = []
      each_sql_line do |l|
        next unless l.start_with?("ALTER ", "GRANT ", "REVOKE ")
        l.scan(/OWNER TO ([^;]+);/) { roles << _1[0] }
        l.scan(/\b(?:TO|FROM) ((?:"[^"]+"|[\w$]+)(?:, *(?:"[^"]+"|[\w$]+))*)(?: WITH GRANT OPTION)?;/) { roles.concat(_1[0].split(/, */)) }
      end
      roles.map(&:strip).uniq - %w[PUBLIC postgres]
    end

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
