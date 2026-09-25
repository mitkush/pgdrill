module Pgdrill
  module Duration
    UNITS = { "s" => 1, "m" => 60, "h" => 3600, "d" => 86_400 }.freeze

    module_function

    def parse(text)
      m = text.to_s.strip.match(/\A(\d+(?:\.\d+)?)\s*([smhd])\z/i)
      raise Error, "invalid duration #{text.inspect} (use e.g. 90s, 30m, 26h, 2d)" unless m
      (m[1].to_f * UNITS.fetch(m[2].downcase)).round
    end

    def human(seconds)
      return "#{seconds.to_f.round(1)}s" if seconds < 10
      s = seconds.round
      return "#{s}s" if s < 120
      return "#{(s / 60.0).round(1)}m" if s < 7200
      return "#{(s / 3600.0).round(1)}h" if s < 172_800
      "#{(s / 86_400.0).round(1)}d"
    end
  end
end
