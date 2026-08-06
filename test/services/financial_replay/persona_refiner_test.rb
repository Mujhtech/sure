# frozen_string_literal: true

require "test_helper"

class FinancialReplay::PersonaRefinerTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @month = Date.current.prev_month.beginning_of_month.to_date
    @cache = ActiveSupport::Cache::MemoryStore.new
    @metrics = {
      savings_rate: 18,
      net_savings: "800",
      income_change_percent: 3,
      expense_change_percent: -2,
      tracked_days: 30,
      no_spend_days: 5,
      active_recurring_count: 4,
      top_categories: [ "Home" ],
      net_worth_change_percent: 1.2,
      budget_progress: nil,
      goal_progress: nil,
      has_investments: false,
      investment_contributions: "0",
      investment_trades_count: 0
    }
  end

  test "uses a deterministic archetype when AI is disabled" do
    @user.stubs(:ai_enabled?).returns(false)
    @metrics.merge!(
      has_investments: true,
      investment_contributions: "600",
      investment_trades_count: 2
    )

    persona = build_refiner.call

    assert_equal "investor", persona[:key]
    assert_equal "The Investor", persona[:title]
    assert_equal "rules", persona[:source]
  end

  test "uses category names from structured persona metrics" do
    @user.stubs(:ai_enabled?).returns(false)
    @metrics.merge!(
      savings_rate: 0,
      net_savings: "0",
      income_change_percent: 0,
      expense_change_percent: 0,
      active_recurring_count: 0,
      top_categories: [ { name: "Travel", transactions: 3, total: "$240.00" } ],
      net_worth_change_percent: 0
    )

    persona = build_refiner.call

    assert_equal "explorer", persona[:key]
    assert_equal "rules", persona[:source]
  end

  test "accepts validated AI copy and archetype" do
    @user.stubs(:ai_enabled?).returns(true)
    provider = mock("llm provider")
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)
    Chat.stubs(:default_model).returns("test-model")

    message = Provider::LlmConcept::ChatMessage.new(
      id: "message-1",
      output_text: <<~JSON
        {"archetype":"achiever","headline":"Your goals got louder.","description":"You moved from intention to visible progress.","closing_line":"Receipts for the life you are building."}
      JSON
    )
    chat_response = Provider::LlmConcept::ChatResponse.new(
      id: "response-1",
      model: "test-model",
      messages: [ message ],
      function_requests: []
    )
    provider.stubs(:chat_response).returns(
      Provider::Response.new(success?: true, data: chat_response, error: nil)
    )

    persona = build_refiner.call

    assert_equal "achiever", persona[:key]
    assert_equal "Your goals got louder.", persona[:headline]
    assert_equal "ai", persona[:source]
  end

  test "falls back safely when AI returns an unknown archetype" do
    @user.stubs(:ai_enabled?).returns(true)
    provider = mock("llm provider")
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)
    Chat.stubs(:default_model).returns("test-model")
    DebugLogEntry.stubs(:capture)

    message = Provider::LlmConcept::ChatMessage.new(
      id: "message-1",
      output_text: '{"archetype":"high_roller","headline":"Nope","description":"Nope","closing_line":"Nope"}'
    )
    chat_response = Provider::LlmConcept::ChatResponse.new(
      id: "response-1",
      model: "test-model",
      messages: [ message ],
      function_requests: []
    )
    provider.stubs(:chat_response).returns(
      Provider::Response.new(success?: true, data: chat_response, error: nil)
    )

    persona = build_refiner.call

    assert_equal "builder", persona[:key]
    assert_equal "rules", persona[:source]
  end

  test "returns the deterministic fallback even when AI and fallback logging fail" do
    @user.stubs(:ai_enabled?).returns(true)
    Provider::Registry.stubs(:preferred_llm_provider).raises(StandardError, "provider unavailable")
    DebugLogEntry.stubs(:capture).raises(StandardError, "log unavailable")

    persona = build_refiner.call

    assert_equal "builder", persona[:key]
    assert_equal "rules", persona[:source]
  end

  private
    def build_refiner
      FinancialReplay::PersonaRefiner.new(
        user: @user,
        month: @month,
        metrics: @metrics,
        cache: @cache
      )
    end
end
