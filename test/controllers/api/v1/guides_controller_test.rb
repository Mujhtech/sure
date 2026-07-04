# frozen_string_literal: true

require "test_helper"

class Api::V1::GuidesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.api_keys.active.destroy_all

    @read_only_api_key = ApiKey.create!(
      user: @user,
      name: "Guide Read Key",
      scopes: [ "read" ],
      display_key: "guide_ro_#{SecureRandom.hex(8)}"
    )

    Redis.new.del("api_rate_limit:#{@read_only_api_key.id}")
  end

  test "shows onboarding guide markdown" do
    get "/api/v1/guide", headers: api_headers(@read_only_api_key)

    assert_response :success

    response_data = response_body
    assert_equal "onboarding", response_data.dig("guide", "slug")
    assert_equal "Welcome to Sure!", response_data.dig("guide", "title")
    assert_equal "markdown", response_data.dig("guide", "format")
    assert_includes response_data.dig("guide", "markdown"), "Adding your first accounts"
    assert response_data.dig("guide", "byte_size").positive?
    assert response_data.dig("guide", "updated_at").present?
  end

  test "requires authentication" do
    get "/api/v1/guide"

    assert_response :unauthorized
  end

  private

    def response_body
      JSON.parse(response.body)
    end
end
