# frozen_string_literal: true

module TinkickTestBackend
  def require_production_tin_plan!
    return unless ENV["TINKICK_TEST_BACKEND"] == "lead"

    skip "Production TIN plan assertions require production TIN; Lead does not implement production scans or top-k execution"
  end
end

ActiveSupport::TestCase.include(TinkickTestBackend)
