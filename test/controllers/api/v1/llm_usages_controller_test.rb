# frozen_string_literal: true

require "test_helper"

class Api::V1::LlmUsagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @user.api_keys.active.destroy_all

    @read_key = ApiKey.create!(
      user: @user,
      name: "LLM Usage Read Key",
      scopes: [ "read" ],
      source: "mobile",
      display_key: "llm_usage_read_#{SecureRandom.hex(8)}"
    )
  end

  test "show returns date filtered family usage statistics and recent usage" do
    older_usage = create_usage!(
      operation: "chat",
      prompt_tokens: 20,
      completion_tokens: 10,
      total_tokens: 30,
      estimated_cost: 0.0012,
      created_at: 2.days.ago
    )
    failed_usage = create_usage!(
      operation: "auto_categorize",
      prompt_tokens: 15,
      completion_tokens: 5,
      total_tokens: 20,
      estimated_cost: nil,
      metadata: { error: "Rate limited", http_status_code: 429 },
      created_at: 1.day.ago
    )
    families(:empty).llm_usages.create!(
      provider: "openai",
      model: "gpt-4.1",
      operation: "chat",
      prompt_tokens: 100,
      completion_tokens: 100,
      total_tokens: 200,
      estimated_cost: 1.0,
      created_at: 1.day.ago
    )

    get api_v1_llm_usage_url,
        params: {
          start_date: 7.days.ago.to_date.iso8601,
          end_date: Date.current.iso8601,
          limit: 1
        },
        headers: api_headers(@read_key)

    assert_response :success
    response_data = JSON.parse(response.body)

    assert_equal 2, response_data.dig("statistics", "total_requests")
    assert_equal 1, response_data.dig("statistics", "requests_with_cost")
    assert_equal 50, response_data.dig("statistics", "total_tokens")
    assert_equal 1, response_data.dig("meta", "limit")
    assert_equal 1, response_data.dig("meta", "count")
    assert_equal failed_usage.id, response_data.dig("llm_usages", 0, "id")
    assert_equal true, response_data.dig("llm_usages", 0, "failed")
    assert_equal 429, response_data.dig("llm_usages", 0, "http_status_code")
    assert_equal "Rate limited", response_data.dig("llm_usages", 0, "error_message")
    refute_includes response_data["llm_usages"].map { |usage| usage["id"] }, older_usage.id
    refute response_data.dig("llm_usages", 0).key?("metadata")
  end

  test "show rejects invalid date filters" do
    get api_v1_llm_usage_url,
        params: { start_date: "not-a-date" },
        headers: api_headers(@read_key)

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "show requires authentication" do
    get api_v1_llm_usage_url

    assert_response :unauthorized
  end

  private
    def create_usage!(attributes = {})
      @family.llm_usages.create!({
        provider: "openai",
        model: "gpt-4.1",
        operation: "chat",
        prompt_tokens: 10,
        completion_tokens: 5,
        total_tokens: 15,
        estimated_cost: 0.0008,
        metadata: {}
      }.merge(attributes))
    end
end
