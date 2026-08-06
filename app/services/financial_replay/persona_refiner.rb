# frozen_string_literal: true

module FinancialReplay
  class PersonaRefiner
    ARCHETYPES = {
      "investor" => {
        title: "The Investor",
        headline: "You put your money to work.",
        description: "Your month leaned toward ownership, compounding, and the long game.",
        closing_line: "Future you got funded.",
        symbol: "chart.line.uptrend.xyaxis"
      }.freeze,
      "achiever" => {
        title: "The Achiever",
        headline: "You turned targets into receipts.",
        description: "Progress was not abstract this month. You gave it a number and moved it forward.",
        closing_line: "Goal energy, backed by numbers.",
        symbol: "trophy.fill"
      }.freeze,
      "planner" => {
        title: "The Planner",
        headline: "You gave the month a job.",
        description: "Your choices followed a plan, with enough structure to keep the fun intentional.",
        closing_line: "The plan held. So did you.",
        symbol: "checklist"
      }.freeze,
      "builder" => {
        title: "The Builder",
        headline: "You kept more than momentum.",
        description: "This month added another layer to the life and balance sheet you are building.",
        closing_line: "Built quietly. Felt loudly.",
        symbol: "building.columns.fill"
      }.freeze,
      "steward" => {
        title: "The Steady Hand",
        headline: "You made calm look profitable.",
        description: "Restraint, visibility, and small decisions did the heavy lifting this month.",
        closing_line: "Less noise. More control.",
        symbol: "hand.raised.fill"
      }.freeze,
      "explorer" => {
        title: "The Explorer",
        headline: "You spent on a life worth remembering.",
        description: "Experiences led the story, while the numbers kept the adventure grounded.",
        closing_line: "A full life, fully accounted for.",
        symbol: "safari.fill"
      }.freeze
    }.freeze

    def initialize(user:, month:, metrics:, cache: Rails.cache)
      @user = user
      @family = user.family
      @month = month
      @metrics = metrics.deep_symbolize_keys
      @cache = cache
    end

    def call
      fallback = heuristic_persona
      return fallback unless user.ai_enabled?

      provider = Provider::Registry.preferred_llm_provider
      return fallback unless provider

      cached = cache.read(cache_key)
      return cached.deep_symbolize_keys if cached.present?

      response = provider.chat_response(
        prompt,
        model: Chat.default_model,
        instructions: instructions,
        session_id: "financial-replay-#{family.id}-#{month_key}",
        user_identifier: Digest::SHA256.hexdigest(user.id.to_s),
        family: family
      )

      unless response.success?
        capture_failure(response.error)
        return fallback
      end

      refined = parse_response(response.data, fallback)
      unless refined
        capture_failure(JSON::ParserError.new("Financial Replay persona response was invalid"))
        return fallback
      end

      cache.write(cache_key, refined, expires_in: 30.days)
      refined
    rescue StandardError => e
      capture_failure(e)
      fallback || heuristic_persona
    end

    private
      attr_reader :user, :family, :month, :metrics, :cache

      def instructions
        <<~PROMPT
          You write upbeat, shareable financial recap copy for NorthLedger.
          Classify the user using exactly one allowed archetype key:
          investor, achiever, planner, builder, steward, explorer.

          Use only the aggregate signals supplied. Do not infer sensitive traits,
          diagnose the user, shame spending, or invent facts or numbers. Make the
          copy warm, specific in tone, and suitable for a social story card.

          Return only a JSON object with these string keys:
          archetype, headline, description, closing_line.
          headline: at most 56 characters.
          description: at most 130 characters.
          closing_line: at most 48 characters.
          Optionally add "category_quips": up to 3 playful labels (max 26
          characters each), one per top category in the order given. Ground
          each in that category's real transaction count or total — never
          invent numbers.
        PROMPT
      end

      def prompt
        <<~PROMPT
          Completed month: #{month_key}
          Aggregate monthly signals:
          #{JSON.generate(metrics)}
        PROMPT
      end

      def parse_response(chat_response, fallback)
        text = Array(chat_response&.messages).map(&:output_text).join("\n")
        json = text[/\{.*\}/m]
        return if json.blank?

        parsed = JSON.parse(json)
        key = parsed["archetype"].to_s
        return unless ARCHETYPES.key?(key)

        definition = ARCHETYPES.fetch(key)
        quips = Array(parsed["category_quips"])
          .filter_map { |quip| quip.to_s.squish.presence&.first(26) }
          .first(3)

        {
          key: key,
          title: definition.fetch(:title),
          headline: normalized_copy(parsed["headline"], definition.fetch(:headline), 56),
          description: normalized_copy(parsed["description"], definition.fetch(:description), 130),
          closing_line: normalized_copy(parsed["closing_line"], definition.fetch(:closing_line), 48),
          category_quips: quips,
          symbol: definition.fetch(:symbol),
          source: "ai"
        }
      rescue JSON::ParserError
        nil
      end

      def normalized_copy(value, fallback, limit)
        value.to_s.squish.presence&.first(limit) || fallback
      end

      def heuristic_persona
        key = heuristic_key
        definition = ARCHETYPES.fetch(key)

        {
          key: key,
          title: definition.fetch(:title),
          headline: definition.fetch(:headline),
          description: definition.fetch(:description),
          closing_line: definition.fetch(:closing_line),
          symbol: definition.fetch(:symbol),
          source: "rules"
        }
      end

      def heuristic_key
        scores = ARCHETYPES.keys.index_with { 0 }
        scores["builder"] = 1

        scores["investor"] += 4 if metrics[:has_investments]
        scores["investor"] += 3 if metrics[:investment_contributions].to_f.positive?
        scores["investor"] += 1 if metrics[:investment_trades_count].to_i.positive?

        scores["achiever"] += 4 if metrics[:goal_progress].to_f >= 0.5
        scores["achiever"] += 2 if metrics[:savings_rate].to_f >= 20
        scores["achiever"] += 1 if metrics[:income_change_percent].to_f.positive?

        unless metrics[:budget_progress].nil?
          scores["planner"] += 4
          scores["planner"] += 2 if metrics[:budget_progress].to_f <= 1
        end
        scores["planner"] += 1 if metrics[:active_recurring_count].to_i.positive?

        scores["builder"] += 3 if metrics[:net_savings].to_f.positive?
        scores["builder"] += 2 if metrics[:savings_rate].to_f >= 10
        scores["builder"] += 2 if metrics[:net_worth_change_percent].to_f.positive?

        scores["steward"] += 3 if metrics[:expense_change_percent].to_f.negative?
        tracked_days = metrics[:tracked_days].to_i
        no_spend_ratio = tracked_days.positive? ? metrics[:no_spend_days].to_f / tracked_days : 0
        scores["steward"] += 2 if no_spend_ratio >= 0.2
        scores["steward"] += 1 if metrics[:active_recurring_count].to_i.positive?

        experience_pattern = /travel|flight|hotel|dining|restaurant|entertainment|holiday|vacation/i
        has_experience_category = Array(metrics[:top_categories]).any? do |category|
          name = category.is_a?(Hash) ? category[:name] : category
          name.to_s.match?(experience_pattern)
        end
        scores["explorer"] += 5 if has_experience_category

        scores.max_by { |_key, score| score }.first
      end

      def cache_key
        digest = Digest::SHA256.hexdigest(JSON.generate(metrics))
        "financial-replay/persona/v2/#{family.id}/#{user.id}/#{month_key}/#{digest}"
      end

      def month_key
        month.strftime("%Y-%m")
      end

      def capture_failure(error)
        DebugLogEntry.capture(
          category: "ai_personalization",
          level: "warn",
          message: "Financial Replay AI refinement failed; heuristic copy was used",
          source: self.class.name,
          provider_key: Setting.llm_provider,
          family: family,
          user: user,
          metadata: {
            month: month_key,
            error_class: error&.class&.name
          }
        )
      rescue StandardError => logging_error
        Rails.logger.warn(
          "FinancialReplay::PersonaRefiner could not record AI fallback: " \
          "#{logging_error.class}: #{logging_error.message}"
        )
      end
  end
end
