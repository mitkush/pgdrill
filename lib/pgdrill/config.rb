require "yaml"

module Pgdrill
  # Optional pgdrill.yml: per-table row tolerances, tables to skip in the row check,
  # and custom SQL checks run against the restored copy. Unknown keys are errors, so a
  # typo can't silently turn a check off.
  class Config
    Check = Struct.new(:name, :sql, :op, :value, keyword_init: true) do
      def expectation = op == :bool ? value.to_s : "#{op} #{value}"
    end

    KEYS = %w[rows ignore_tables checks].freeze
    ROW_KEYS = %w[tolerance estimate_tolerance tables].freeze
    CHECK_KEYS = %w[name sql expect].freeze
    EXPECT = /\A(>=|<=|!=|=|>|<)\s*(-?\d+(?:\.\d+)?)\z/

    attr_reader :row_tolerance, :estimate_tolerance, :table_tolerance, :ignore_tables, :checks

    def self.load(path)
      raise Error, "config file not found: #{path}" unless File.exist?(path)
      data = YAML.safe_load(File.read(path)) || {}
      raise Error, "#{path}: expected a mapping at the top level" unless data.is_a?(Hash)
      new(data, source: path)
    rescue Psych::SyntaxError => e
      raise Error, "#{path}: invalid YAML: #{e.message}"
    end

    def self.empty = new({})

    def initialize(h, source: "config")
      @source = source
      strict!(h, KEYS, "top level")
      rows = h["rows"] || {}
      raise Error, "#{source}: rows must be a mapping" unless rows.is_a?(Hash)
      strict!(rows, ROW_KEYS, "rows")
      @row_tolerance = pct(rows["tolerance"], "rows.tolerance")
      @estimate_tolerance = pct(rows["estimate_tolerance"], "rows.estimate_tolerance")
      tables = rows["tables"] || {}
      raise Error, "#{source}: rows.tables must map table names to tolerances" unless tables.is_a?(Hash)
      @table_tolerance = tables.to_h { |t, v| [qualify(t), pct(v, "rows.tables.#{t}")] }
      @ignore_tables = Array(h["ignore_tables"]).map { qualify(_1) }
      @checks = Array(h["checks"]).each_with_index.map { |c, i| check(c, i) }
    end

    def ignored?(table) = @ignore_tables.include?(table)

    # [passed?, human description] for a custom check's first value.
    def self.evaluate(check, result)
      return [false, "returned no value (NULL or no rows); expected #{check.expectation}"] if result.nil? || result.empty?
      if check.op == :bool
        got = %w[t true].include?(result.downcase)
        return [got == check.value, "returned #{result}; expected #{check.value}"]
      end
      num = Float(result, exception: false)
      return [false, "returned #{result.inspect}, not a number; expected #{check.expectation}"] unless num
      ok = case check.op
           when ">" then num > check.value
           when ">=" then num >= check.value
           when "<" then num < check.value
           when "<=" then num <= check.value
           when "=" then num == check.value
           when "!=" then num != check.value
           end
      [ok, "returned #{result}; expected #{check.expectation}"]
    end

    private

    def strict!(h, allowed, where)
      bad = h.keys.map(&:to_s) - allowed
      raise Error, "#{@source}: unknown key#{'s' if bad.size > 1} #{bad.join(', ')} in #{where} (allowed: #{allowed.join(', ')})" if bad.any?
    end

    # Table keys in pgdrill are schema-qualified; "orders" means public.orders.
    def qualify(t) = t.to_s.include?(".") ? t.to_s : "public.#{t}"

    def pct(v, where)
      return nil if v.nil?
      n = case v
          when /\A\s*(\d+(?:\.\d+)?)\s*%\s*\z/ then Regexp.last_match(1).to_f / 100
          when Numeric then v.to_f
          end
      raise Error, "#{@source}: #{where} must be a percentage like \"5%\" or a fraction between 0 and 1, got #{v.inspect}" if n.nil? || n.negative? || n > 1
      n
    end

    def check(c, i)
      raise Error, "#{@source}: checks[#{i}] must be a mapping with name, sql and expect" unless c.is_a?(Hash)
      strict!(c, CHECK_KEYS, "checks[#{i}]")
      missing = CHECK_KEYS - c.keys.map(&:to_s)
      raise Error, "#{@source}: checks[#{i}] is missing #{missing.join(', ')}" if missing.any?
      e = c["expect"]
      op, value =
        case e
        when true, false then [:bool, e]
        when Integer, Float then ["=", e.to_f]
        when EXPECT then [Regexp.last_match(1), Regexp.last_match(2).to_f]
        when /\A(true|false)\z/i then [:bool, e.downcase == "true"]
        else raise Error, "#{@source}: checks[#{i}].expect must look like \"> 0\", \">= 100\", \"= 3\" or true/false, got #{e.inspect}"
        end
      Check.new(name: c["name"].to_s, sql: c["sql"].to_s, op: op, value: value)
    end
  end
end
