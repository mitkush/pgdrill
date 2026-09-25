require_relative "test_helper"
require "zlib"

class BackupFileTest < Minitest::Test
  SQL = <<~SQL
    --
    -- PostgreSQL database dump
    --
    -- Dumped from database version 16.4
    -- Dumped by pg_dump version 16.4
    CREATE TABLE public.t (id integer);
    ALTER TABLE public.t OWNER TO app_owner;
    GRANT SELECT ON TABLE public.t TO reporting, "Mixed Case";
    REVOKE ALL ON TABLE public.t FROM PUBLIC;
    ALTER TABLE public.t OWNER TO postgres;
    ALTER SCHEMA public OWNER TO pg_database_owner;
    GRANT USAGE ON SCHEMA public TO CURRENT_USER;
    CREATE POLICY own_rows ON public.t FOR SELECT TO authenticated, anon USING ((id > 0));
    CREATE POLICY writers ON public.t FOR INSERT TO service_role WITH CHECK (true);
    ALTER DEFAULT PRIVILEGES FOR ROLE migrator IN SCHEMA public GRANT SELECT ON TABLES TO reporting;
  SQL

  def with_file(name, bytes)
    Dir.mktmpdir do |d|
      path = File.join(d, name)
      File.binwrite(path, bytes)
      yield path
    end
  end

  def test_plain_sql_detection_versions_and_roles
    with_file("db.sql", SQL) do |p|
      b = Pgdrill::BackupFile.new(p)
      assert_equal :plain, b.format
      assert_equal "16.4", b.versions[:from]
      assert_equal 16, b.major
      assert_equal ["app_owner", "reporting", '"Mixed Case"', "authenticated", "anon", "service_role", "migrator"], b.referenced_roles
    end
  end

  def test_required_major_covers_newer_pg_dump
    with_file("db.sql", SQL.sub("pg_dump version 16.4", "pg_dump version 17.2")) do |p|
      b = Pgdrill::BackupFile.new(p)
      assert_equal 16, b.major
      assert_equal 17, b.required_major
    end
  end

  def test_gzipped_plain_sql
    with_file("db.sql.gz", Zlib.gzip(SQL)) do |p|
      b = Pgdrill::BackupFile.new(p)
      assert_equal :plain_gz, b.format
      assert_equal "16.4", b.versions[:from]
    end
  end

  def test_custom_format_by_magic_bytes
    with_file("db.dump", "PGDMP\x01\x0e\x00".b) { assert_equal :custom, Pgdrill::BackupFile.new(_1).format }
  end

  def test_gzipped_custom_archive_is_rejected_with_advice
    with_file("db.dump.gz", Zlib.gzip("PGDMP\x01".b)) do |p|
      err = assert_raises(Pgdrill::Error) { Pgdrill::BackupFile.new(p) }
      assert_includes err.message, "gunzip"
    end
  end

  def test_missing_file
    assert_raises(Pgdrill::Error) { Pgdrill::BackupFile.new("/nonexistent.dump") }
  end
end
