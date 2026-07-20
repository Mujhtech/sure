# frozen_string_literal: true

require "test_helper"

class Api::V1::SavingsChallengesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @user.api_keys.active.destroy_all
    @read_key = ApiKey.create!(
      user: @user,
      name: "Challenge Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "challenge_read_#{SecureRandom.hex(8)}"
    )
    @write_key = ApiKey.create!(
      user: @user,
      name: "Challenge Write Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "challenge_rw_#{SecureRandom.hex(8)}"
    )
    @account = accounts(:depository)
  end

  test "shows the campaign before enrollment" do
    travel_to Date.new(2026, 7, 25) do
      get api_v1_savings_challenge_url, headers: api_headers(@read_key)

      assert_response :success
      response_data = JSON.parse(response.body)
      assert_equal SavingsChallenge::Campaign::KEY, response_data.dig("campaign", "id")
      assert_equal "upcoming", response_data.dig("campaign", "phase")
      assert_nil response_data["enrollment"]
    end
  end

  test "joins the challenge and creates a baseline-backed goal" do
    travel_to Time.zone.local(2026, 8, 3, 12) do
      assert_difference([ "@family.goals.count", "@family.savings_challenge_enrollments.count" ], 1) do
        post api_v1_savings_challenge_url,
             params: { challenge: { target_amount: "500", account_id: @account.id } },
             headers: api_headers(@write_key)
      end

      assert_response :created
      response_data = JSON.parse(response.body)
      assert_equal "active", response_data.dig("campaign", "phase")
      assert_equal 3, response_data.dig("campaign", "day_number")
      assert_equal 50_000, response_data.dig("enrollment", "target_amount_cents")
      assert_equal 0, response_data.dig("enrollment", "saved_amount_cents")
      assert_equal SavingsChallenge::Campaign.ends_on.to_s, @family.goals.order(:created_at).last.target_date.to_s
    end
  end

  test "join is idempotent" do
    post api_v1_savings_challenge_url,
         params: { challenge: { target_amount: "500", account_id: @account.id } },
         headers: api_headers(@write_key)

    assert_no_difference([ "@family.goals.count", "@family.savings_challenge_enrollments.count" ]) do
      post api_v1_savings_challenge_url,
           params: { challenge: { target_amount: "900", account_id: @account.id } },
           headers: api_headers(@write_key)
    end

    assert_response :success
  end

  test "rejects enrollment with a read only key" do
    post api_v1_savings_challenge_url,
         params: { challenge: { target_amount: "500", account_id: @account.id } },
         headers: api_headers(@read_key)

    assert_response :forbidden
  end

  test "rejects a new enrollment after the campaign ends" do
    travel_to Time.zone.local(2026, 9, 1, 12) do
      assert_no_difference([ "@family.goals.count", "@family.savings_challenge_enrollments.count" ]) do
        post api_v1_savings_challenge_url,
             params: { challenge: { target_amount: "500", account_id: @account.id } },
             headers: api_headers(@write_key)
      end

      assert_response :unprocessable_entity
      assert_equal "This savings challenge has ended.", JSON.parse(response.body)["message"]
    end
  end
end
