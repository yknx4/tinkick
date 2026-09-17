# frozen_string_literal: true

require "active_support"
require "active_support/time"

module Tinkick
  class AggregationDate
    def initialize(time_zone: nil, now: Time.now)
      @now = now
      @offset = 0
      @zone = nil
      zone_name = time_zone || "UTC"
      raise ArgumentError, "time_zone must be a string" unless zone_name.is_a?(String)

      if /\A[+-]\d{2}:\d{2}\z/.match?(zone_name)
        parts = zone_name.delete_prefix("+").delete_prefix("-").split(":").map(&:to_i)
        raise ArgumentError, "Invalid time_zone offset minutes" if parts.fetch(1) > 59

        @offset = (parts.fetch(0) * 3_600 + parts.fetch(1) * 60) * (zone_name.start_with?("-") ? -1 : 1)
        raise ArgumentError, "time_zone offset must be within -18:00 and +18:00" if @offset.abs > 18 * 3_600
      elsif !["UTC", "Z"].include?(zone_name)
        zone = ActiveSupport::TimeZone[zone_name]
        unless zone && zone.tzinfo.identifier == zone_name
          raise ArgumentError, "time_zone must be an IANA zone name or an ISO8601 offset"
        end
        @zone = zone
      end
    end

    def parse(value)
      return if value.nil?
      if value.is_a?(Numeric)
        number = Float(value)
        raise ArgumentError, "Date range epoch bounds must be finite numbers" unless number.is_a?(Float) && number.finite?

        return number
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

          parsed = parse_iso8601(anchor)
          math ? calculate(parsed, math) : parsed
        end
      else
        raise ArgumentError, "Date range bounds must be Date, Time, ISO8601 strings, or epoch milliseconds"
      end
      (instant.to_r * 1_000).to_f
    end

    def format(value)
      instant = local_time(Time.at(Rational(value.to_s) / 1_000))
      instant.utc_offset.zero? ? instant.utc.iso8601(3) : instant.iso8601(3)
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

    def parse_iso8601(value)
      parts = Date._iso8601(value)
      year = parts[:year]
      raise ArgumentError, "Invalid ISO8601 date range bound: #{value.inspect}" unless year

      month = parts.fetch(:mon, 1)
      day = parts.fetch(:mday, 1)
      Date.new(year, month, day)
      hour = parts.fetch(:hour, 0)
      minute = parts.fetch(:min, 0)
      second = parts.fetch(:sec, 0).to_r + parts.fetch(:sec_fraction, 0).to_r
      unless (0..23).cover?(hour) && (0..59).cover?(minute) && second >= 0 && second < 60
        raise ArgumentError, "Invalid ISO8601 clock time: #{value.inspect}"
      end

      offset = parts[:offset]
      offset ? local_time(Time.new(year, month, day, hour, minute, second, offset)) : local_date(year, month, day, hour, minute, second)
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
