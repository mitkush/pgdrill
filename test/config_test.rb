require_relative "test_helper"
require "socket"

class ConfigTest < Minitest::Test
  include Snapshots
  C = Pgdrill::Config

  def cfg(h) = C.new(h)

  def test_full_config
    c = cfg("rows" => { "tolerance" => "2%", "estimate_tolerance" => 0.4, "tables" => { "events" => "50%" } },
            "ignore_tables" => ["sessions"],
            "checks" => [{ "name" => "orders", "sql" => "select 1", "expect" => "> 0" }])
    assert_in_delta 0.02, c.row_tolerance
    assert_in_delta 0.4, c.estimate_tolerance
    assert_equal({ "public.events" => 0.5 }, c.table_tolerance)
    assert c.ignored?("public.sessions")
    assert_equal ">", c.checks.first.op
  end

  def test_typos_are_errors_not_silently_ignored
    e = assert_raises(Pgdrill::Error) { cfg("row" => {}) }
    assert_includes e.message, "unknown key row"
    assert_raises(Pgdrill::Error) { cfg("rows" => { "tolerence" => "5%" }) }
    assert_raises(Pgdrill::Error) { cfg("checks" => [{ "name" => "x", "sql" => "select 1", "expected" => "> 0" }]) }
    assert_raises(Pgdrill::Error) { cfg("checks" => [{ "name" => "x", "sql" => "select 1" }]) }
    assert_raises(Pgdrill::Error) { cfg("rows" => { "tolerance" => "150%" }) }
    assert_raises(Pgdrill::Error) { cfg("checks" => [{ "name" => "x", "sql" => "select 1", "expect" => "about 5" }]) }
  end

  def check(expect) = cfg("checks" => [{ "name" => "n", "sql" => "s", "expect" => expect }]).checks.first

  def test_evaluate
    assert C.evaluate(check("> 0"), "3").first
    refute C.evaluate(check("> 0"), "0").first
    assert C.evaluate(check(">= 5000"), "5462").first
    assert C.evaluate(check(5), "5").first
    assert C.evaluate(check("!= 0"), "2.5").first
    assert C.evaluate(check(true), "t").first
    refute C.evaluate(check(true), "f").first
    refute C.evaluate(check("> 0"), nil).first, "NULL / no rows must fail"
    ok, detail = C.evaluate(check("> 0"), "abc")
    refute ok
    assert_includes detail, "not a number"
  end

  def test_load_from_file_and_bad_yaml
    Dir.mktmpdir do |d|
      good = File.join(d, "p.yml")
      File.write(good, "rows:\n  tolerance: 10%\nchecks:\n  - name: a\n    sql: select 1\n    expect: '= 1'\n")
      assert_in_delta 0.1, C.load(good).row_tolerance
      bad = File.join(d, "bad.yml")
      File.write(bad, "rows: [unclosed\n")
      assert_includes assert_raises(Pgdrill::Error) { C.load(bad) }.message, "invalid YAML"
    end
    assert_raises(Pgdrill::Error) { C.load("/nonexistent.yml") }
  end

  def rows_run(base_rows, got_rows, config)
    base = snapshot(tables: base_rows.transform_values { { "rows" => _1, "method" => "exact" } })
    got = snapshot(tables: got_rows.transform_values { { "rows" => _1, "method" => "exact" } })
    Pgdrill::Checks.run(restore: ok_restore, restored: got, baseline: base, config: config).select { _1.check == "rows" }
  end

  def test_per_table_tolerance_and_ignore
    assert_equal 1, rows_run({ "public.events" => 100 }, { "public.events" => 60 }, C.empty).size
    assert_empty rows_run({ "public.events" => 100 }, { "public.events" => 60 }, cfg("rows" => { "tables" => { "events" => "50%" } }))
    # an empty table still fails whatever its tolerance; only ignore_tables skips it
    assert_equal :critical, rows_run({ "public.events" => 100 }, { "public.events" => 0 }, cfg("rows" => { "tables" => { "events" => "100%" } })).first.severity
    assert_empty rows_run({ "public.events" => 100 }, { "public.events" => 0 }, cfg("ignore_tables" => ["events"]))
  end

  def test_failed_custom_check_is_critical
    got = snapshot.merge("custom" => [{ "name" => "orders", "ok" => false, "detail" => "returned 0; expected > 0" },
                                       { "name" => "users", "ok" => true, "detail" => "returned 5" }])
    f = Pgdrill::Checks.run(restore: ok_restore, restored: got).select { _1.check == "custom" }
    assert_equal ["orders: returned 0; expected > 0"], f.map(&:message)
    assert_equal :critical, f.first.severity
  end
end

class NotifierTest < Minitest::Test
  # One-shot HTTP server that records the request and answers `status`.
  def capture(status: 200)
    server = TCPServer.new("127.0.0.1", 0)
    got = {}
    t = Thread.new do
      c = server.accept
      head = +""
      while (l = c.gets) && l != "\r\n"
        head << l
      end
      got[:head] = head
      got[:body] = c.read(head[/content-length: (\d+)/i, 1].to_i)
      c.write "HTTP/1.1 #{status} X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      c.close
    end
    yield "http://127.0.0.1:#{server.addr[1]}/hooks/SECRET-TOKEN"
    t.join(5)
    server.close
    got
  end

  def test_slack_format_posts_text
    got = capture { |url| Pgdrill::Notifier.new(url).notify(verdict: "FAIL", text: "pgdrill FAIL for x") }
    assert_includes got[:head], "POST /hooks/SECRET-TOKEN"
    assert_includes got[:head].downcase, "content-type: application/json"
    assert_equal({ "text" => "pgdrill FAIL for x" }, JSON.parse(got[:body]))
  end

  def test_json_format_includes_report
    got = capture { |url| Pgdrill::Notifier.new(url, format: "json").notify(verdict: "ERROR", text: "t", report: { "a" => 1 }) }
    assert_equal({ "verdict" => "ERROR", "message" => "t", "report" => { "a" => 1 } }, JSON.parse(got[:body]))
  end

  def test_pass_is_quiet_unless_always
    err = StringIO.new
    Pgdrill::Notifier.new("http://127.0.0.1:1/x", err: err).notify(verdict: "PASS", text: "t")
    assert_empty err.string, "no request should have been attempted"
  end

  def test_failing_webhook_warns_without_leaking_the_url
    err = StringIO.new
    capture(status: 500) { |url| Pgdrill::Notifier.new(url, err: err).notify(verdict: "FAIL", text: "t") }
    assert_includes err.string, "HTTP 500"
    refute_includes err.string, "SECRET-TOKEN"
  end

  def test_summary_text
    h = { "verdict" => "FAIL", "backup" => { "location" => "s3://b/k.dump" }, "evidence" => { "restore_seconds" => 2.0 },
          "findings" => [{ "severity" => "critical", "check" => "rows", "message" => "public.x: restored 0 rows" },
                         { "severity" => "info", "check" => "production", "message" => "note" }] }
    assert_equal "pgdrill FAIL for s3://b/k.dump\n• rows: public.x: restored 0 rows", Pgdrill::Notifier.summary(h)
  end
end
