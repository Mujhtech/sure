# frozen_string_literal: true

module SavingsChallenge
  class Campaign
    KEY = "30-day-savings-2026"
    NAME = "30-Day Savings Challenge"
    DURATION_DAYS = 30
    DEFAULT_START_DATE = "2026-08-01"

    class << self
      def starts_on
        Date.iso8601(ENV.fetch("SAVINGS_CHALLENGE_START_DATE", DEFAULT_START_DATE))
      rescue Date::Error
        Date.iso8601(DEFAULT_START_DATE)
      end

      def ends_on
        starts_on + (DURATION_DAYS - 1).days
      end

      def phase(on: Date.current)
        return "upcoming" if on < starts_on
        return "ended" if on > ends_on

        "active"
      end

      def day_number(on: Date.current)
        return nil unless phase(on:) == "active"

        (on - starts_on).to_i + 1
      end

      def days_remaining(on: Date.current)
        return DURATION_DAYS if on < starts_on
        return 0 if on > ends_on

        (ends_on - on).to_i + 1
      end
    end
  end
end
