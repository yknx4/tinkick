# frozen_string_literal: true

require "active_support"
require "active_support/time"

module Tinkick
  class AggregationDate
    FORMAT_TOKENS = {
      "yyyy" => ["year", "[0-9]{4}", "%Y"], "uuuu" => ["year", "[0-9]{4}", "%Y"],
      "MM" => ["month", "[0-9]{2}", "%m"], "dd" => ["day", "[0-9]{2}", "%d"],
      "HH" => ["hour", "[0-9]{2}", "%H"], "mm" => ["minute", "[0-9]{2}", "%M"], "ss" => ["second", "[0-9]{2}", "%S"],
      "S" => ["fraction", "[0-9]", "%1N"], "SS" => ["fraction", "[0-9]{2}", "%2N"], "SSS" => ["fraction", "[0-9]{3}", "%3N"],
      "XXX" => ["offset", "(?:Z|[+-][0-9]{2}:[0-9]{2})", "%:z"],
    }.freeze
    ISO8601 = /\A(?<year>-?[0-9]{4})(?:-(?<month>[0-9]{2})(?:-(?<day>[0-9]{2}))?)?(?:T(?:(?<hour>[0-9]{2})(?::(?<minute>[0-9]{2})(?::(?<second>[0-9]{2})(?:[.,](?<fraction>[0-9]{1,9}))?)?)?(?<offset>Z|[+-][0-9]{2}(?::?[0-9]{2})?)?)?)?\z/

    def initialize(format: nil, time_zone: nil, now: Time.now)
      pattern = format || "strict_date_optional_time||epoch_millis"
      raise ArgumentError, "format must be a nonempty string" unless pattern.is_a?(String) && !pattern.empty?

      @formats = pattern.split("||", -1)
      @custom_formats = {}
      @formats.each do |name|
        @custom_formats[name] = compile_format(name) unless ["strict_date_optional_time", "epoch_millis"].include?(name)
      end
      @now = now
      @offset = 0
      @zone = nil
      zone_name = time_zone.nil? ? "UTC" : time_zone
      case zone_name
      when Integer, Float
        raise ArgumentError, "time_zone numeric hours must be finite" if zone_name.is_a?(Float) && !zone_name.finite?

        @offset = zone_name.to_i * 3_600
      when String
        offset = zone_name.sub(/\A(?:UTC|GMT|UT)(?=[+-])/, "")
        if /\A[+-](?:[0-9]{1,2}|[0-9]{4}|[0-9]{6}|[0-9]{2}:[0-9]{2}(?::[0-9]{2})?)\z/.match?(offset)
          digits = offset[1..].to_s.delete(":").rjust(2, "0")
          hours = digits[0, 2].to_i
          minutes = digits[2, 2].to_s.to_i
          seconds = digits[4, 2].to_s.to_i
          raise ArgumentError, "Invalid time_zone offset minutes or seconds" if minutes > 59 || seconds > 59

          @offset = (hours * 3_600 + minutes * 60 + seconds) * (offset.start_with?("-") ? -1 : 1)
        elsif !["UTC", "Z", "UT", "GMT"].include?(zone_name)
          zone = ActiveSupport::TimeZone[zone_name]
          unless zone && zone.tzinfo.identifier == zone_name
            raise ArgumentError, "time_zone must be an IANA zone name or an ISO8601 offset"
          end
          @zone = zone
        end
      else
        raise ArgumentError, "time_zone must be a string or numeric hours"
      end
      raise ArgumentError, "time_zone offset must be within -18:00 and +18:00" if @offset.abs > 18 * 3_600
    end

    def fixed_offset
      @offset unless @zone
    end

    def parse(value)
      return if value.nil?
      if value.is_a?(Numeric)
        number = Float(value)
        raise ArgumentError, "Date range epoch bounds must be finite numbers" unless number.is_a?(Float) && number.finite?

        # Date ranges truncate numeric bounds before applying their formatter.
        value = number.to_i.to_s
      end

      instant = case value
      when Time then local_time(value.to_time)
      when DateTime then local_time(value.to_time)
      when Date then local_date(value.year, value.month, value.day)
      when String
        if value.start_with?("now")
          calculate(local_time(@now), value.delete_prefix("now"))
        else
          anchor, math = value.split("||", 2)
          raise ArgumentError, "Date range bounds cannot be empty" unless anchor

          parsed = parse_anchor(anchor)
          math ? calculate(parsed, math) : parsed
        end
      else
        raise ArgumentError, "Date range bounds must be Date, Time, ISO8601 strings, or epoch milliseconds"
      end
      (instant.to_r * 1_000).to_f
    end

    def format(value)
      instant = local_time(Time.at(Rational(value.to_s) / 1_000))
      pattern = @formats.fetch(0)
      case pattern
      when "epoch_millis" then value.to_i.to_s
      when "strict_date_optional_time"
        # Upstream prints only offset hours/minutes, using Z when both are zero.
        instant.iso8601(3).sub(/[+-]00:00\z/, "Z")
      else
        @custom_formats.fetch(pattern).last.map do |part, token|
          if token
            part == "XXX" && instant.utc_offset.abs < 60 ? "Z" : instant.strftime(FORMAT_TOKENS.fetch(part).fetch(2))
          else
            part
          end
        end.join
      end
    end

    private

    def local_time(instant)
      zone = @zone
      zone ? instant.in_time_zone(zone) : instant.getlocal(@offset)
    end

    def local_date(year, month, day, hour = 0, minute = 0, second = 0)
      zone = @zone
      zone ? zone.local(year, month, day, hour, minute, second) : Time.new(year, month, day, hour, minute, second, @offset)
    end

    def compile_format(pattern)
      # @type var parts: Array[[String, bool]]
      parts = []
      source = +""
      remaining = pattern
      until remaining.empty?
        if remaining.start_with?("''")
          part = "'"
          remaining = remaining.delete_prefix("''")
          token = false
        elsif remaining.start_with?("'")
          quoted = /\A'((?:[^']|'')*)'/.match(remaining)
          raise ArgumentError, "Unclosed quote in date format" unless quoted

          part = quoted[1].to_s.gsub("''", "'")
          remaining = quoted.post_match
          token = false
        else
          match = /\A(?:([A-Za-z])\1*|[^A-Za-z'\[\]{}#]+)/.match(remaining)
          raise ArgumentError, "Unsupported date format syntax: #{remaining.inspect}" unless match

          part = match[0].to_s
          remaining = match.post_match
          token = /\A[A-Za-z]/.match?(part)
        end
        parts << [part, token]
        if token
          definition = FORMAT_TOKENS[part]
          raise ArgumentError, "Unsupported date format token: #{part.inspect}" unless definition

          source << "(?<#{definition[0]}>#{definition[1]})"
        else
          source << Regexp.escape(part)
        end
      end
      raise ArgumentError, "Date format must contain a supported date or time token" unless parts.any?(&:last)

      [Regexp.new("\\A#{source}\\z"), parts]
    end

    def parse_anchor(value)
      @formats.each do |pattern|
        if pattern == "epoch_millis"
          next unless /\A-?[0-9]+(?:\.[0-9]+)?\z/.match?(value)

          return local_time(Time.at(Rational(value) / 1_000))
        end
        expression = pattern == "strict_date_optional_time" ? ISO8601 : @custom_formats.fetch(pattern).first
        match = expression.match(value)
        return parse_parts(match.named_captures) if match
      rescue ArgumentError
        # A later configured format can still parse this value.
      end
      raise ArgumentError, "Invalid date range bound #{value.inspect} for format #{@formats.join("||").inspect}"
    end

    def parse_parts(parts)
      year = (parts["year"] || "1970").to_i
      month = (parts["month"] || "1").to_i
      day = (parts["day"] || "1").to_i
      Date.new(year, month, day)
      hour = (parts["hour"] || "0").to_i
      minute = (parts["minute"] || "0").to_i
      second = (parts["second"] || "0").to_i + Rational("0.#{parts["fraction"] || "0"}")
      unless (0..23).cover?(hour) && (0..59).cover?(minute) && second >= 0 && second < 60
        raise ArgumentError, "Invalid date range clock time"
      end

      offset = parts["offset"]
      return local_date(year, month, day, hour, minute, second) unless offset

      hours = offset[1, 2].to_i
      minutes = offset.delete(":")[3, 2].to_i
      seconds = hours * 3_600 + minutes * 60
      raise ArgumentError, "Invalid date range offset" if minutes > 59 || seconds > 18 * 3_600

      local_time(Time.new(year, month, day, hour, minute, second, offset.start_with?("-") ? -seconds : seconds))
    end

    def calculate(instant, math)
      until math.empty?
        step = %r{\A([+/-])(\d*)([yMwdhHms])}.match(math)
        raise ArgumentError, "Invalid date math: #{math.inspect}" unless step

        operator = step[1].to_s
        amount_text = step[2].to_s
        amount = amount_text.empty? ? 1 : amount_text.to_i
        raise ArgumentError, "Date math amount exceeds a 32-bit integer" if amount > 2_147_483_647

        unit = step[3].to_s
        math = step.post_match
        if operator == "/"
          raise ArgumentError, "Date math rounding requires a single unit" unless amount == 1

          instant = round(instant, unit)
        else
          unit_name = { "y" => :years, "M" => :months, "w" => :weeks, "d" => :days, "h" => :hours, "H" => :hours, "m" => :minutes, "s" => :seconds }.fetch(unit)
          instant = instant.advance(unit_name => (operator == "-" ? -amount : amount))
        end
      end
      instant
    end

    def round(instant, unit)
      case unit
      when "y" then instant.beginning_of_year
      when "M" then instant.beginning_of_month
      when "w" then instant.beginning_of_week(:monday)
      when "d" then instant.beginning_of_day
      when "h", "H" then instant.change(min: 0, sec: 0)
      when "m" then instant.change(sec: 0)
      else instant.change(usec: 0)
      end
    end
  end
end
