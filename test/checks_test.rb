require_relative "test_helper"

class ChecksTest < Minitest::Test
  include Snapshots
  C = Pgdrill::Checks
  T0 = Time.utc(2026, 9, 25, 12)

  def run_checks(baseline, restored, **opts) = C.run(restore: ok_restore, restored: restored, baseline: baseline, now: T0, **opts)

  def test_identical_snapshots_pass
    s = snapshot(schema: %w[a b], tables: { "public.t" => { "rows" => 10, "method" => "exact" } },
                 freshness: { "public.t|created_at" => "2026-09-25T11:00:00Z" })
    assert_equal "PASS", C.verdict(run_checks(s, s))
  end

  def test_failed_restore_is_the_only_finding
    f = C.run(restore: { ok: false, error: "boom" }, restored: nil, baseline: snapshot)
    assert_equal [["restore", :critical]], f.map { [_1.check, _1.severity] }
  end

  def test_missing_schema_objects_name_the_tables
    base = snapshot(schema: ["column public.orders.id bigint notnull=t", "column public.orders.total numeric notnull=f", "index x"])
    f = checks_for("schema", run_checks(base, snapshot(schema: ["index x"])))
    assert_equal :critical, f.first.severity
    assert_includes f.first.message, "public.orders"
  end

  def test_extra_objects_in_restore_are_fine
    assert_empty checks_for("schema", run_checks(snapshot(schema: %w[a]), snapshot(schema: %w[a b])))
  end

  def test_empty_table_is_critical_even_for_estimates
    base = snapshot(tables: { "public.big" => { "rows" => 5_000_000, "method" => "estimate" } })
    got = snapshot(tables: { "public.big" => { "rows" => 0, "method" => "estimate" } })
    assert_equal :critical, checks_for("rows", run_checks(base, got)).first.severity
  end

  def test_row_drift_uses_method_specific_tolerance
    base = snapshot(tables: { "public.a" => { "rows" => 100, "method" => "exact" }, "public.b" => { "rows" => 100, "method" => "estimate" } })
    got = snapshot(tables: { "public.a" => { "rows" => 90, "method" => "exact" }, "public.b" => { "rows" => 90, "method" => "estimate" } })
    f = checks_for("rows", run_checks(base, got))
    assert_equal ["public.a"], f.map { _1.message[/\A\S+(?=:)/] }
    assert_equal :warning, f.first.severity
  end

  def test_freshness_lag_behind_baseline
    base = snapshot(freshness: { "t|c" => "2026-09-25T11:00:00Z" })
    got = snapshot(freshness: { "t|c" => "2026-09-25T10:00:00Z" })
    assert_equal :critical, checks_for("freshness", run_checks(base, got)).first.severity
    assert_empty checks_for("freshness", run_checks(base, got, lag_tolerance: 7200))
  end

  def test_max_age_gate
    got = snapshot(freshness: { "t|c" => "2026-09-23T12:00:00Z" })
    assert_equal :critical, checks_for("freshness", run_checks(nil, got, max_age: 26 * 3600)).first.severity
    assert_empty checks_for("freshness", run_checks(nil, got, max_age: 72 * 3600))
    assert_equal :warning, checks_for("freshness", run_checks(nil, snapshot, max_age: 3600)).first.severity
  end

  def seq(last, max) = { "seq" => "public.t_id_seq", "col" => "public.t.id", "last_value" => last, "max_id" => max }

  def test_sequence_not_restored
    f = checks_for("sequences", run_checks(snapshot(sequences: [seq(500, 500)]), snapshot(sequences: [seq(nil, 500)])))
    assert_equal :critical, f.first.severity
  end

  def test_sequence_already_behind_in_production_is_not_blamed_on_backup
    f = run_checks(snapshot(sequences: [seq(4, 101)]), snapshot(sequences: [seq(4, 101)]))
    assert_empty checks_for("sequences", f)
    assert_equal :info, checks_for("production", f).first.severity
    assert_equal "PASS", C.verdict(f)
  end

  def test_sequence_worse_than_production_is_still_caught
    f = checks_for("sequences", run_checks(snapshot(sequences: [seq(90, 101)]), snapshot(sequences: [seq(nil, 101)])))
    assert_equal :critical, f.first.severity
  end

  def test_sequence_without_baseline_is_only_a_warning
    assert_equal :warning, checks_for("sequences", run_checks(nil, snapshot(sequences: [seq(nil, 5)]))).first.severity
  end

  def test_amcheck_corruption_vs_uncheckable
    got = snapshot.merge("amcheck" => { "available" => true, "checked" => 3, "corrupt" => ["i1: XX002 bad"], "skipped" => ["i2: 0A000 nope"] })
    f = checks_for("amcheck", run_checks(nil, got))
    assert_equal %i[critical info], f.map(&:severity)
  end
end
