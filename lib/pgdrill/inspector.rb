module Pgdrill
  # Catalog and data probes. Everything here is a plain SELECT, so it runs on
  # read replicas and under a read-only role. amcheck is the one exception and
  # is only ever called on the throwaway restore target.
  class Inspector
    USER_NS = <<~SQL.strip
      n.nspname not in ('pg_catalog', 'information_schema')
      and n.nspname not like 'pg\\_toast%' and n.nspname not like 'pg\\_temp%'
      and not exists (select 1 from pg_depend e where e.objid = n.oid and e.deptype = 'e')
    SQL
    TIMESTAMP_TYPES = "('timestamp'::regtype, 'timestamptz'::regtype, 'date'::regtype)"
    CHUNK = 200
    ISO = %q{'YYYY-MM-DD"T"HH24:MI:SS"Z"'}

    def initialize(db) = @db = db

    def server_version = @db.value("show server_version_num").to_i

    def database_name = @db.value("select current_database()")

    def schema_objects
      @db.rows(<<~SQL).map { _1["i"] }.sort
        select format('column %I.%I.%I %s notnull=%s', n.nspname, c.relname, a.attname,
                      format_type(a.atttypid, a.atttypmod), a.attnotnull) as i
          from pg_attribute a
          join pg_class c on c.oid = a.attrelid
          join pg_namespace n on n.oid = c.relnamespace
         where c.relkind in ('r', 'p') and a.attnum > 0 and not a.attisdropped and #{USER_NS}
        union all
        select format('index %s', i.indexdef)
          from pg_indexes i join pg_namespace n on n.nspname = i.schemaname
         where #{USER_NS}
        union all
        -- constraints cloned onto partitions are re-derived on restore, so only compare the originals
        select format('constraint %s %s %s',
                      coalesce(nullif(k.conrelid, 0)::regclass::text, k.contypid::regtype::text),
                      k.conname, pg_get_constraintdef(k.oid))
          from pg_constraint k join pg_namespace n on n.oid = k.connamespace
         where k.conparentid = 0 and #{USER_NS}
        union all
        select format('%s %I.%I',
                      case c.relkind when 'v' then 'view' when 'm' then 'matview' when 'S' then 'sequence' end,
                      n.nspname, c.relname)
          from pg_class c join pg_namespace n on n.oid = c.relnamespace
         where c.relkind in ('v', 'm', 'S') and #{USER_NS}
      SQL
    end

    def tables
      @db.rows(<<~SQL)
        select format('%I.%I', n.nspname, c.relname) as t,
               has_table_privilege(c.oid, 'SELECT') as readable,
               c.reltuples::bigint as estimate
          from pg_class c join pg_namespace n on n.oid = c.relnamespace
         where c.relkind = 'r' and #{USER_NS}
      SQL
    end

    def exact_counts(names)
      union(names) { |t| "select #{lit(t)} as k, count(*)::text as v from #{t}" }.transform_values(&:to_i)
    end

    def estimates(names)
      return {} if names.empty?
      tables.select { names.include?(_1["t"]) }.to_h { [_1["t"], [_1["estimate"], 0].max] }
    end

    # indexed_only keeps production probes cheap: max() on a btree-leading column is an index lookup.
    def freshness_columns(indexed_only:)
      @db.rows(<<~SQL).map { [_1["t"], _1["c"]] }
        select format('%I.%I', n.nspname, c.relname) as t, quote_ident(a.attname) as c
          from pg_attribute a
          join pg_class c on c.oid = a.attrelid
          join pg_namespace n on n.oid = c.relnamespace
         where c.relkind = 'r' and a.attnum > 0 and not a.attisdropped and #{USER_NS}
           and a.atttypid in #{TIMESTAMP_TYPES}
           and has_table_privilege(c.oid, 'SELECT')
           #{"and exists (select 1 from pg_index x join pg_class ic on ic.oid = x.indexrelid join pg_am am on am.oid = ic.relam
                          where x.indrelid = c.oid and x.indkey[0] = a.attnum and am.amname = 'btree')" if indexed_only}
      SQL
    end

    # Ignores values more than a day in the future (expiry dates, 'infinity') so they can't mask staleness.
    def newest(columns)
      union(columns.map { _1.join("|") }) do |key|
        t, c = key.split("|", 2)
        "select #{lit(key)} as k, to_char(max(#{c})::timestamptz at time zone 'UTC', #{ISO}) as v " \
          "from #{t} where #{c} < now() + interval '1 day' and #{c} > '-infinity'"
      end.compact
    end

    def sequences
      links = @db.rows(<<~SQL)
        select format('%I.%I', sn.nspname, s.relname) as seq,
               format('%I.%I', n.nspname, tbl.relname) as t, quote_ident(att.attname) as c,
               case when has_sequence_privilege(s.oid, 'SELECT') then pg_sequence_last_value(s.oid)::text end as last_value
          from pg_class s
          join pg_namespace sn on sn.oid = s.relnamespace
          join (
            select d.objid as seq_oid, d.refobjid as tbl_oid, d.refobjsubid as attnum
              from pg_depend d
             where d.classid = 'pg_class'::regclass and d.refclassid = 'pg_class'::regclass and d.deptype in ('a', 'i')
            union
            select d.refobjid, ad.adrelid, ad.adnum
              from pg_attrdef ad
              join pg_depend d on d.classid = 'pg_attrdef'::regclass and d.objid = ad.oid and d.refclassid = 'pg_class'::regclass
          ) l on l.seq_oid = s.oid
          join pg_class tbl on tbl.oid = l.tbl_oid and tbl.relkind = 'r'
          join pg_namespace n on n.oid = tbl.relnamespace
          join pg_attribute att on att.attrelid = tbl.oid and att.attnum = l.attnum
         where s.relkind = 'S' and #{USER_NS} and has_table_privilege(tbl.oid, 'SELECT')
           and format_type(att.atttypid, null) in ('smallint', 'integer', 'bigint', 'numeric')
      SQL
      maxes = union(links.map { "#{_1['t']}|#{_1['c']}" }.uniq) do |key|
        t, c = key.split("|", 2)
        "select #{lit(key)} as k, max(#{c})::text as v from #{t}"
      end
      links.map do |l|
        { "seq" => l["seq"], "col" => "#{l['t']}.#{l['c']}",
          "last_value" => l["last_value"]&.to_i, "max_id" => maxes["#{l['t']}|#{l['c']}"]&.to_i }
      end
    end

    def amcheck(heapallindexed: true)
      begin
        @db.exec("create extension if not exists amcheck")
      rescue Db::QueryError => e
        return { "available" => false, "reason" => e.message, "checked" => 0, "corrupt" => [], "skipped" => [] }
      end
      # One session checks every index; a per-index exception handler records failures instead of aborting.
      rows = @db.rows(<<~SQL, setup: AMCHECK_FN)
        select c.oid::regclass::text as i, pg_temp.pgdrill_amcheck(c.oid, #{heapallindexed}) as err
          from pg_index x join pg_class c on c.oid = x.indexrelid
          join pg_am am on am.oid = c.relam join pg_namespace n on n.oid = c.relnamespace
         where am.amname = 'btree' and c.relkind = 'i' and x.indisvalid and x.indisready and #{USER_NS}
      SQL
      corrupt, skipped = rows.select { _1["err"] }.partition { _1["err"].start_with?("XX001", "XX002") }
      { "available" => true, "checked" => rows.size,
        "corrupt" => corrupt.map { "#{_1['i']}: #{_1['err']}" }, "skipped" => skipped.map { "#{_1['i']}: #{_1['err']}" } }
    end

    AMCHECK_FN = <<~SQL.freeze
      create function pg_temp.pgdrill_amcheck(i oid, heap boolean) returns text language plpgsql as $f$
      begin perform bt_index_check(i::regclass, heap); return null;
      exception when others then return sqlstate || ' ' || sqlerrm; end $f$;
    SQL

    private

    def lit(s) = "'#{s.gsub("'", "''")}'"

    def union(keys)
      keys.each_slice(CHUNK).each_with_object({}) do |slice, acc|
        sql = slice.map { "(#{yield _1})" }.join(" union all ")
        @db.rows(sql).each { acc[_1["k"]] = _1["v"] }
      end
    end
  end
end
