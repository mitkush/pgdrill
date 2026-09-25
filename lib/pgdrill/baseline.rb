require "json"
require "time"

module Pgdrill
  # A snapshot of what a database looks like: schema, row counts, newest data,
  # sequence positions. Captured from production ("baseline") and from the
  # restored copy, then compared by Checks.
  module Baseline
    FORMAT = 1
    DEFAULT_EXACT_ROW_LIMIT = 100_000

    module_function

    # like: a production baseline to mirror, so the restored copy is measured the same way.
    def capture(inspector, like: nil, exact_row_limit: DEFAULT_EXACT_ROW_LIMIT, indexed_freshness: true)
      tables = inspector.tables
      readable, unreadable = tables.partition { _1["readable"] }

      exact_names, estimate_names =
        if like
          readable.map { _1["t"] }.partition { like.dig("tables", _1, "method") != "estimate" }
        else
          readable.partition { _1["estimate"] < exact_row_limit }.map { |part| part.map { _1["t"] } }
        end

      counts = inspector.exact_counts(exact_names).transform_values { { "rows" => _1, "method" => "exact" } }
      inspector.estimates(estimate_names).each { |t, n| counts[t] = { "rows" => n, "method" => "estimate" } }

      fresh_cols = like ? like.fetch("freshness", {}).keys.map { _1.split("|", 2) } : inspector.freshness_columns(indexed_only: indexed_freshness)

      {
        "format" => FORMAT,
        "pgdrill" => VERSION,
        "captured_at" => Time.now.utc.iso8601,
        "database" => inspector.database_name,
        "server_version" => inspector.server_version,
        "schema" => inspector.schema_objects,
        "tables" => counts.sort.to_h,
        "freshness" => inspector.newest(fresh_cols).sort.to_h,
        "sequences" => inspector.sequences,
        "unreadable_tables" => unreadable.map { _1["t"] }
      }
    end

    def newest(snapshot) = snapshot.fetch("freshness", {}).values.compact.map { Time.parse(_1) }.max

    def save(snapshot, path) = File.write(path, JSON.pretty_generate(snapshot))

    def load(path)
      data = JSON.parse(File.read(path))
      raise Error, "#{path}: unsupported baseline format #{data['format'].inspect}" unless data["format"] == FORMAT
      data
    end
  end
end
