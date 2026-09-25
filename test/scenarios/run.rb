# Breaks backups of a real database on purpose and checks pgdrill classifies each one.
#   PGDRILL_SCENARIO_DB=postgresql://postgres@127.0.0.1:55432/pagila bundle exec rake scenarios
# The database is written to (a heartbeat table), so never point this at production.
require "fileutils"
require "json"
require "open3"
require "stringio"
require "zlib"
require "socket"
require_relative "../../lib/pgdrill"

URL = ENV.fetch("PGDRILL_SCENARIO_DB") { abort "set PGDRILL_SCENARIO_DB to a disposable database URL" }
WORK = File.expand_path(ENV.fetch("PGDRILL_SCENARIO_DIR", "tmp/scenarios"))
LAG = 10
FileUtils.rm_rf(WORK)
FileUtils.mkdir_p(WORK)

PROD = Pgdrill::Db.new(URL)
DUMP_ENV = PROD.env
def path(name) = File.join(WORK, name)

# PGDRILL_SCENARIO_PG_DUMP lets a scenario make backups with an older pg_dump (e.g. 14) than the restore side.
def pg_dump(name, *args)
  _o, err, st = Open3.capture3(DUMP_ENV, ENV.fetch("PGDRILL_SCENARIO_PG_DUMP", "pg_dump"), *args, "-f", path(name))
  abort "pg_dump failed: #{err}" unless st.success?
  path(name)
end

def pgdrill(*args)
  out, err = StringIO.new, StringIO.new
  code = Pgdrill::CLI.start(args.map(&:to_s), out: out, err: err)
  [code, out.string, err.string]
end

def drill(backup, *extra)
  report = path("report-#{File.basename(backup)}-#{rand(1_000_000)}.json")
  code, _out, err = pgdrill("run", backup, "--format", "json", "--output", report, *extra)
  abort "pgdrill errored (exit #{code}): #{err}" if code == Pgdrill::CLI::EXIT_ERROR
  JSON.parse(File.read(report)).merge("exit" => code)
end

def baseline(name = "baseline.json")
  code, _o, err = pgdrill("baseline", "--db", URL, "-o", path(name))
  abort "baseline failed: #{err}" unless code.zero?
  path(name)
end

RESULTS = []
def expect(name, report, verdict, check = nil)
  hit = check.nil? || report["findings"].any? { _1["check"] == check && _1["severity"] == "critical" }
  ok = report["verdict"] == verdict && hit
  RESULTS << { "scenario" => name, "expected" => verdict, "verdict" => report["verdict"], "check" => check, "correct" => ok }
  first = report["findings"].find { _1["severity"] != "info" }
  puts format("%-7s %-52s → %-4s (expected %s%s)%s", ok ? "ok" : "WRONG", name, report["verdict"], verdict,
              check ? " via #{check}" : "", first ? "\n        #{first['check']}: #{first['message'][0, 150]}" : "")
end

def skip(name, why)
  RESULTS << { "scenario" => name, "verdict" => "N/A", "correct" => nil }
  puts format("%-7s %-52s → N/A (%s)", "skip", name, why)
end

PROD.exec("create table if not exists public.zz_pgdrill_heartbeat (ts timestamptz not null)")
PROD.exec("create index if not exists zz_pgdrill_heartbeat_ts on public.zz_pgdrill_heartbeat (ts)")
PROD.exec("insert into public.zz_pgdrill_heartbeat values (now())")

good = pg_dump("good.dump", "-Fc")
base = baseline
snap = Pgdrill::Baseline.load(base)
puts "#{snap['database']}: #{snap['tables'].size} tables, #{snap['schema'].size} schema objects, #{snap['sequences'].size} sequences\n\n"

if (u = snap.dig("tables", "public.zz_unanalyzed"))
  ok = u["method"] == "estimate"
  RESULTS << { "scenario" => "never-analyzed large table is not counted on production", "expected" => "estimate",
               "verdict" => u["method"], "correct" => ok }
  puts format("%-7s %-52s → %s", ok ? "ok" : "WRONG", "never-analyzed large table not counted exactly", u["method"])
end

expect("A  healthy custom-format backup", drill(good, "--baseline", base), "PASS")
expect("A2 healthy plain .sql backup", drill(pg_dump("good.sql", "-Fp"), "--baseline", base), "PASS")
File.binwrite(path("good.sql.gz"), Zlib.gzip(File.binread(path("good.sql"))))
expect("A3 healthy .sql.gz backup", drill(path("good.sql.gz"), "--baseline", base), "PASS")
expect("A4 healthy directory-format backup", drill(pg_dump("good.dir", "-Fd"), "--baseline", base), "PASS")
expect("A5 healthy backup, live baseline", drill(good, "--baseline-db", URL), "PASS")

File.binwrite(path("truncated.dump"), File.binread(good)[0, (File.size(good) * 0.6).to_i])
expect("B  truncated backup file", drill(path("truncated.dump"), "--baseline", base), "FAIL", "restore")

leaves = PROD.rows(<<~SQL).map { _1["t"] }
  select format('%I.%I', n.nspname, c.relname) as t
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where c.relkind = 'r' and not c.relispartition and #{Pgdrill::Inspector::USER_NS}
     and c.relname not in ('zz_pgdrill_heartbeat', 'zz_unanalyzed')
     and not exists (select 1 from pg_constraint k where k.confrelid = c.oid)
     and not exists (select 1 from pg_inherits i where i.inhparent = c.oid)
     -- extension-owned tables (e.g. PostGIS spatial_ref_sys) ignore pg_dump -T, so they can't be "left out"
     and not exists (select 1 from pg_depend d where d.classid = 'pg_class'::regclass and d.objid = c.oid and d.deptype = 'e')
   order by c.reltuples desc, 1 limit 10
SQL

picked = leaves.first(5).lazy.map do |t|
  r = drill(pg_dump("no_table.dump", "-Fc", "-T", t), "--baseline", base)
  r["evidence"]["restore_ok"] ? [t, r] : nil
end.find(&:itself)
picked ? expect("C  table missing, restore succeeds (#{picked[0]})", picked[1], "FAIL", "schema") : skip("C  table missing", "no table can be excluded cleanly")

nonempty = leaves.select { snap.dig("tables", _1, "rows").to_i.positive? }
picked = nonempty.first(5).lazy.map do |t|
  r = drill(pg_dump("no_data.dump", "-Fc", "--exclude-table-data=#{t}"), "--baseline", base)
  r["evidence"]["restore_ok"] ? [t, r] : nil
end.find(&:itself)
picked ? expect("D  table data missing (#{picked[0]})", picked[1], "FAIL", "rows") : skip("D  table data missing", "no non-empty leaf table")

if picked
  table = picked[0]
  no_data = path("no_data.dump")
  File.write(path("checks.yml"), <<~YML)
    checks:
      - name: #{table} has rows
        sql: select count(*) from #{table}
        expect: "> 0"
  YML
  expect("H1 custom check passes on a good backup", drill(good, "--baseline", base, "--config", path("checks.yml")), "PASS")
  expect("H2 custom check catches the missing data", drill(no_data, "--config", path("checks.yml")), "FAIL", "custom")
  File.write(path("ignore.yml"), "ignore_tables: [#{table}]\n")
  expect("H3 ignore_tables skips that table", drill(no_data, "--baseline", base, "--config", path("ignore.yml")), "PASS")
  File.write(path("broken-check.yml"), "checks:\n  - name: typo\n    sql: select count(*) from no_such_table\n    expect: '> 0'\n")
  expect("H4 a check query that errors fails the drill", drill(good, "--config", path("broken-check.yml")), "FAIL", "custom")

  # Webhook: a local server records what pgdrill posts.
  hook = TCPServer.new("127.0.0.1", 0)
  bodies = Queue.new
  listener = Thread.new do
    loop do
      c = hook.accept
      head = +""
      while (l = c.gets) && l != "\r\n" do head << l end
      bodies << c.read(head[/content-length: (\d+)/i, 1].to_i)
      c.write "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      c.close
    end
  end
  url = "http://127.0.0.1:#{hook.addr[1]}/hook"
  drill(no_data, "--baseline", base, "--webhook", url)
  text = JSON.parse(bodies.pop(timeout: 10) || "{}")["text"].to_s
  ok = text.start_with?("pgdrill FAIL for ") && text.include?(table)
  RESULTS << { "scenario" => "K1 webhook alert on a failed drill", "verdict" => ok ? "sent" : "missing", "correct" => ok }
  puts format("%-7s %-52s → %s", ok ? "ok" : "WRONG", "K1 webhook alert on a failed drill", text.lines.first.to_s.strip[0, 70])
  code, = pgdrill("run", path("does-not-exist.dump"), "--webhook", url)
  text = JSON.parse(bodies.pop(timeout: 10) || "{}")["text"].to_s
  ok = code == Pgdrill::CLI::EXIT_ERROR && text.start_with?("pgdrill could not drill")
  RESULTS << { "scenario" => "K2 webhook alert when the drill can't run", "verdict" => ok ? "sent" : "missing", "correct" => ok }
  puts format("%-7s %-52s → exit %s, %s", ok ? "ok" : "WRONG", "K2 webhook alert when the drill can't run", code, text[0, 60])
  listener.kill
  hook.close
end

if snap["sequences"].any? { _1["max_id"].to_i.positive? }
  File.write(path("no_setval.sql"), File.foreach(path("good.sql")).reject { _1.start_with?("SELECT pg_catalog.setval(") }.join)
  expect("E  sequence positions lost", drill(path("no_setval.sql"), "--baseline", base), "FAIL", "sequences")
else
  skip("E  sequence positions lost", "no sequence-backed column holds data")
end

stale = pg_dump("stale.dump", "-Fc")
sleep LAG + 3
PROD.exec("insert into public.zz_pgdrill_heartbeat values (now())")
expect("F  stale backup (production moved on)", drill(stale, "--baseline", baseline("after.json"), "--lag-tolerance", "#{LAG}s"), "FAIL", "freshness")
expect("G  backup older than --max-age", drill(stale, "--max-age", "5s"), "FAIL", "freshness")

scored = RESULTS.reject { _1["correct"].nil? }
puts "\n#{scored.count { _1['correct'] }}/#{scored.size} scenarios correct, #{RESULTS.size - scored.size} not applicable"
File.write(File.join(WORK, "results-#{snap['database']}.json"), JSON.pretty_generate(RESULTS))
exit(scored.all? { _1["correct"] } ? 0 : 1)
