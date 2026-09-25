require "minitest/autorun"
require "json"
require "tmpdir"
require "stringio"
require "uri"
require_relative "../lib/pgdrill"

module Snapshots
  def snapshot(tables: {}, schema: [], freshness: {}, sequences: [], unreadable: [])
    { "format" => 1, "schema" => schema, "tables" => tables, "freshness" => freshness,
      "sequences" => sequences, "unreadable_tables" => unreadable }
  end

  def ok_restore = { ok: true, seconds: 1.0 }

  def checks_for(check, findings) = findings.select { _1.check == check }
end
