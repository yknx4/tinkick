# frozen_string_literal: true

require "active_support"
require "active_support/time"

module Tinkick
  class AggregationDate
    def initialize(format: nil, time_zone: nil)
      @format = format || "strict_date_optional_time"
      unless @format.is_a?(String) && !@format.empty?
        raise ArgumentError, "format must be a nonempty string"
      end
      unless ["strict_date_optional_time", "epoch_millis"].include?(@format)
        raise NotImplementedError, "Elasticsearch Java date patterns and format lists are not supported by native PostgreSQL aggregation. Format returned dates in the application, or use PostgreSQL to_char in an explicit SQL query."
      end
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
        unless number.is_a?(Float) && number.finite?
          raise ArgumentError, "Date range epoch bounds must be finite numbers"
        end

        return number
      end
      instant = case value
      when Time, DateTime then value.to_time
      when Date then local_date(value.year, value.month, value.day)
      when String
        if value.start_with?("now") || value.include?("||")
          raise NotImplementedError, "Elasticsearch date math is not supported by native PostgreSQL aggregation. Compute a Time or Date boundary in the application, for example 7.days.ago.beginning_of_day."
        end
        integer = Integer(value, 10, exception: false)
        return integer.to_f if integer

        date = DateTime.iso8601(value)
        if Date._iso8601(value).key?(:offset)
          date.to_time
        else
          local_date(date.year, date.month, date.day, date.hour, date.min, date.sec + date.sec_fraction)
        end
      else
        raise ArgumentError, "Date range bounds must be Date, Time, ISO8601 strings, or epoch milliseconds"
      end
      (instant.to_r * 1_000).to_f
    end

    def histogram_bound(value)
      return if value.nil?

      milliseconds = if value.is_a?(Numeric)
        number = Float(value)
        unless number.is_a?(Float) && number.finite?
          raise ArgumentError, "Numeric bounds must be integral epoch milliseconds"
        end
        integer = Integer(value)
        raise ArgumentError, "Numeric bounds must be integral epoch milliseconds" unless value == integer

        integer
      else
        parse(value)&.floor
      end
      unless milliseconds && milliseconds.between?(-(2**63), 2**63 - 1)
        raise ArgumentError, "Bounds must fit in a signed 64-bit millisecond integer"
      end

      milliseconds
    end

    def format(value, utc_offset: nil)
      return value.to_i.to_s if @format == "epoch_millis"

      timestamp = Time.at(Rational(value.to_s) / 1_000)
      instant = utc_offset ? timestamp.getlocal(utc_offset) : local_time(timestamp)
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
  end
end
