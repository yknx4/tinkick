# frozen_string_literal: true

require "active_record"
require_relative "errors"

module Tinkick
  module Functions
    class << self
      def require!(model)
        installed = model.with_connection do |connection|
          connection.select_value(<<~SQL)
            SELECT 1 FROM pg_catalog.pg_proc
            WHERE oid = pg_catalog.to_regprocedure('tinkick.osa_distance(text,text,integer)')
              AND prorettype = 'integer'::regtype
          SQL
        end
        unless installed
          raise Error, "The tinkick.osa_distance function is required for this search feature. Run bin/rails generate tinkick:functions and bin/rails db:migrate to install the optional SQL compatibility functions."
        end

        "tinkick.osa_distance"
      end
    end
  end
end
