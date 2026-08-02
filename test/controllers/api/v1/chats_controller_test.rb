# frozen_string_literal: true

require "test_helper"

class Api::V1::ChatsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(ai_enabled: true)

    @oauth_app = Doorkeeper::Application.create!(
      name: "Test API App",
      redirect_uri: "https://example.com/callback",
      scopes: "read write read_write"
    )

    @read_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
    )

    @write_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )

    @chat = chats(:one)
  end

  test "should require authentication" do
    get "/api/v1/chats"
    assert_response :unauthorized
  end

  test "should require AI to be enabled" do
    @user.update!(ai_enabled: false)

    get "/api/v1/chats", headers: bearer_auth_header(@read_token)
    assert_response :forbidden

    response_body = JSON.parse(response.body)
    assert_equal "feature_disabled", response_body["error"]
  end

  test "should list chats with read scope" do
    get "/api/v1/chats", headers: bearer_auth_header(@read_token)
    assert_response :success

    response_body = JSON.parse(response.body)
    assert response_body["chats"].is_a?(Array)
    assert response_body["pagination"].present?
  end

  test "should show chat with messages" do
    get "/api/v1/chats/#{@chat.id}", headers: bearer_auth_header(@read_token)
    assert_response :success

    response_body = JSON.parse(response.body)
    assert_equal @chat.id, response_body["id"]
    assert response_body["messages"].is_a?(Array)
  end

  test "should create chat with write scope" do
    assert_difference "Chat.count" do
      post "/api/v1/chats",
        params: { title: "New chat", message: "Hello AI" },
        headers: bearer_auth_header(@write_token)
    end

    assert_response :created
    response_body = JSON.parse(response.body)
    assert_equal "New chat", response_body["title"]
  end

  test "should create chat with generated title from initial message" do
    prompt = "Summarize my grocery spending this month and point out anything unusual."

    assert_difference "Chat.count" do
      post "/api/v1/chats",
        params: { message: prompt },
        headers: bearer_auth_header(@write_token)
    end

    assert_response :created
    response_body = JSON.parse(response.body)
    assert_equal prompt.first(80), response_body["title"]
    assert_equal prompt, response_body["messages"].find { |message| message["type"] == "user_message" }["content"]
  end

  test "should not create chat with read scope" do
    post "/api/v1/chats",
      params: { title: "New chat" },
      headers: bearer_auth_header(@read_token)

    assert_response :forbidden
  end

  test "should update chat" do
    patch "/api/v1/chats/#{@chat.id}",
      params: { title: "Updated title" },
      headers: bearer_auth_header(@write_token)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal "Updated title", response_body["title"]
  end

  test "should delete chat" do
    assert_difference "Chat.count", -1 do
      delete "/api/v1/chats/#{@chat.id}", headers: bearer_auth_header(@write_token)
    end

    assert_response :no_content
  end

  test "should not access other user's chat" do
    other_user = users(:family_member)
    other_user.update!(family: families(:empty))
    other_chat = chats(:two)
    other_chat.update!(user: other_user)

    get "/api/v1/chats/#{other_chat.id}", headers: bearer_auth_header(@read_token)
    assert_response :not_found
  end

  test "should support API key authentication" do
    # Remove any existing API keys for this user
    @user.api_keys.destroy_all

    plain_key = ApiKey.generate_secure_key
    api_key = @user.api_keys.build(
      name: "Test API Key",
      scopes: [ "read_write" ]
    )
    api_key.key = plain_key
    api_key.save!

    get "/api/v1/chats", headers: { "X-Api-Key" => plain_key }
    assert_response :success
  end

  test "API key authentication should not inherit web session impersonation" do
    support_user = users(:sure_support_staff)
    support_user.update!(ai_enabled: true)
    support_user.api_keys.active.destroy_all
    support_chat = support_user.chats.create!(title: "Support Chat")

    token_value = ApiKey.generate_secure_key
    credential = support_user.api_keys.build(
      name: "Impersonation Guard Credential",
      scopes: [ "read" ]
    )
    credential.key = token_value
    credential.save!

    impersonation_session = impersonation_sessions(:in_progress)
    impersonated_chat = impersonation_session.impersonated.chats.create!(title: "Impersonated Chat")
    support_user.sessions.destroy_all
    support_user.sessions.create!(
      user_agent: "Browser session",
      ip_address: "127.0.0.1",
      active_impersonator_session: impersonation_session
    )

    get "/api/v1/chats", headers: { "X-Api-Key" => token_value }

    assert_response :success
    response_body = JSON.parse(response.body)
    chat_ids = response_body["chats"].pluck("id")

    assert_includes chat_ids, support_chat.id
    assert_not_includes chat_ids, impersonated_chat.id
  end

  test "OAuth authentication should not inherit web session impersonation" do
    support_user = users(:sure_support_staff)
    support_user.update!(ai_enabled: true)
    support_chat = support_user.chats.create!(title: "Support Chat")
    support_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: support_user.id,
      scopes: "read"
    )

    impersonation_session = impersonation_sessions(:in_progress)
    impersonated_chat = impersonation_session.impersonated.chats.create!(title: "Impersonated Chat")
    support_user.sessions.destroy_all
    support_user.sessions.create!(
      user_agent: "Browser session",
      ip_address: "127.0.0.1",
      active_impersonator_session: impersonation_session
    )

    get "/api/v1/chats", headers: bearer_auth_header(support_token)

    assert_response :success
    response_body = JSON.parse(response.body)
    chat_ids = response_body["chats"].pluck("id")

    assert_includes chat_ids, support_chat.id
    assert_not_includes chat_ids, impersonated_chat.id
  end

  test "updates returns all messages when no cursor given" do
    get "/api/v1/chats/#{@chat.id}/updates", headers: bearer_auth_header(@read_token)

    assert_response :success
    body = JSON.parse(response.body)

    assert_equal @chat.id, body["id"]
    assert_equal @chat.messages.count, body["messages"].size
    assert_includes [ true, false ], body["pending_response"]
    assert body["server_time"].present?
    assert_nothing_raised { Time.iso8601(body["server_time"]) }
  end

  test "updates returns only messages changed since cursor" do
    cursor = 1.minute.from_now.iso8601(6)

    get "/api/v1/chats/#{@chat.id}/updates", params: { since: cursor }, headers: bearer_auth_header(@read_token)
    assert_response :success
    assert_empty JSON.parse(response.body)["messages"]

    new_message = @chat.messages.create!(
      type: "AssistantMessage", content: "Fresh answer", ai_model: "gpt-4.1", status: :complete
    )
    new_message.update_column(:updated_at, 2.minutes.from_now)

    get "/api/v1/chats/#{@chat.id}/updates", params: { since: cursor }, headers: bearer_auth_header(@read_token)
    assert_response :success
    body = JSON.parse(response.body)

    assert_equal [ new_message.id ], body["messages"].pluck("id")
    assert_equal "Fresh answer", body["messages"].first["content"]
  end

  test "updates includes cursor window inclusively so same-instant changes are not missed" do
    message = @chat.messages.ordered.last
    cursor = message.updated_at.iso8601(6)

    get "/api/v1/chats/#{@chat.id}/updates", params: { since: cursor }, headers: bearer_auth_header(@read_token)

    assert_response :success
    assert_includes JSON.parse(response.body)["messages"].pluck("id"), message.id
  end

  test "updates reports pending assistant response" do
    @chat.messages.create!(type: "AssistantMessage", content: "", ai_model: "gpt-4.1", status: :pending)

    get "/api/v1/chats/#{@chat.id}/updates", headers: bearer_auth_header(@read_token)

    assert_response :success
    assert JSON.parse(response.body)["pending_response"]
  end

  test "updates rejects malformed since cursor" do
    get "/api/v1/chats/#{@chat.id}/updates", params: { since: "yesterday-ish" }, headers: bearer_auth_header(@read_token)

    assert_response :unprocessable_entity
    assert_equal "invalid_since", JSON.parse(response.body)["error"]
  end

  test "updates requires read scope and chat ownership" do
    other_chat = chats(:two)

    get "/api/v1/chats/#{other_chat.id}/updates", headers: bearer_auth_header(@read_token)
    assert_response :not_found
  end

  private

    def bearer_auth_header(token)
      { "Authorization" => "Bearer #{token.token}" }
    end
end
