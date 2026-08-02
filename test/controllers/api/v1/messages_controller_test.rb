# frozen_string_literal: true

require "test_helper"

class Api::V1::MessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(ai_enabled: true)

    @oauth_app = Doorkeeper::Application.create!(
      name: "Test API App",
      redirect_uri: "https://example.com/callback",
      scopes: "read write read_write"
    )

    @write_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )

    @chat = chats(:one)
  end

  test "should require authentication" do
    post "/api/v1/chats/#{@chat.id}/messages"
    assert_response :unauthorized
  end

  test "should require AI to be enabled" do
    @user.update!(ai_enabled: false)

    post "/api/v1/chats/#{@chat.id}/messages",
      params: { content: "Hello" },
      headers: bearer_auth_header(@write_token)
    assert_response :forbidden
  end

  test "should create message with write scope" do
    assert_difference "UserMessage.count" do
      post "/api/v1/chats/#{@chat.id}/messages",
        params: { content: "Test message", model: "gpt-4" },
        headers: bearer_auth_header(@write_token)
    end

    assert_response :created
    response_body = JSON.parse(response.body)
    assert_equal "Test message", response_body["content"]
    assert_equal "user_message", response_body["type"]
    assert_equal "pending", response_body["ai_response_status"]
  end

  test "should enqueue assistant response job" do
    assert_enqueued_with(job: AssistantResponseJob) do
      post "/api/v1/chats/#{@chat.id}/messages",
        params: { content: "Test message" },
        headers: bearer_auth_header(@write_token)
    end
  end

  test "should retry last user message" do
    @chat.messages.destroy_all

    user_message = @chat.messages.create!(
      type: "UserMessage",
      content: "Try again",
      ai_model: "gpt-4"
    )
    @chat.messages.where(type: "AssistantMessage").destroy_all
    @chat.update!(error: { message: "Provider failed" }.to_json)
    clear_enqueued_jobs if respond_to?(:clear_enqueued_jobs)

    assert_enqueued_with(job: AssistantResponseJob) do
      post "/api/v1/chats/#{@chat.id}/messages/retry",
        headers: bearer_auth_header(@write_token)
    end

    assert_response :accepted
    response_body = JSON.parse(response.body)
    assert_equal "Retry initiated", response_body["message"]
    assert_equal @chat.id, response_body["chat_id"]
    assert response_body["message_id"].present?

    pending_response = @chat.messages.find(response_body["message_id"])
    assert_equal "AssistantMessage", pending_response.type
    assert pending_response.pending?
    assert_equal user_message.ai_model, pending_response.ai_model
    assert_nil @chat.reload.error
  end

  test "should not retry if latest conversation message is not a user message" do
    @chat.messages.destroy_all
    @chat.messages.create!(
      type: "AssistantMessage",
      content: "Done",
      ai_model: "gpt-4",
      status: :complete
    )

    post "/api/v1/chats/#{@chat.id}/messages/retry.json",
      headers: bearer_auth_header(@write_token)

    assert_response :unprocessable_entity
    response_body = JSON.parse(response.body)
    assert_equal "No user message to retry", response_body["error"]
  end

  test "should report timed out assistant response" do
    @chat.messages.destroy_all
    @chat.update!(error: nil)
    assistant_message = @chat.messages.create!(
      type: "AssistantMessage",
      content: "",
      ai_model: "gpt-4",
      status: :pending
    )
    assistant_message.update_columns(created_at: 2.minutes.ago, updated_at: 2.minutes.ago)

    post "/api/v1/chats/#{@chat.id}/messages/#{assistant_message.id}/report_timeout",
      headers: bearer_auth_header(@write_token)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal "Undelivered response resolved", response_body["message"]
    assert_equal true, response_body["resolved"]
    assert_equal @chat.id, response_body["chat_id"]
    assert_equal assistant_message.id, response_body["message_id"]
    assert_not Message.exists?(assistant_message.id)
    assert @chat.reload.error.present?
  end

  test "should not report active assistant response as timed out" do
    @chat.messages.destroy_all
    @chat.update!(error: nil)
    assistant_message = @chat.messages.create!(
      type: "AssistantMessage",
      content: "",
      ai_model: "gpt-4",
      status: :pending
    )

    post "/api/v1/chats/#{@chat.id}/messages/#{assistant_message.id}/report_timeout",
      headers: bearer_auth_header(@write_token)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal "No timed out assistant response to resolve", response_body["message"]
    assert_equal false, response_body["resolved"]
    assert Message.exists?(assistant_message.id)
    assert_nil @chat.reload.error
  end

  test "should return not found when reporting timeout for missing message" do
    post "/api/v1/chats/#{@chat.id}/messages/#{SecureRandom.uuid}/report_timeout",
      headers: bearer_auth_header(@write_token)

    assert_response :not_found
    response_body = JSON.parse(response.body)
    assert_equal "Message not found", response_body["error"]
  end

  test "should not access messages in other user's chat" do
    other_user = users(:family_member)
    other_user.update!(family: families(:empty))
    other_chat = chats(:two)
    other_chat.update!(user: other_user)

    post "/api/v1/chats/#{other_chat.id}/messages",
      params: { content: "Test" },
      headers: bearer_auth_header(@write_token)

    assert_response :not_found
  end

  test "creates message with a document attachment routed to the document store" do
    Family.any_instance.stubs(:upload_document).returns(nil)

    assert_difference "UserMessage.count" do
      post "/api/v1/chats/#{@chat.id}/messages",
        params: { content: "What does this file say?", file: fixture_file_upload("test.txt", "text/plain") },
        headers: bearer_auth_header(@write_token)
    end

    assert_response :created
    body = JSON.parse(response.body)

    assert_equal "test.txt", body["attachment"]["filename"]
    assert body["attachment"]["url"].present?
    assert_includes body["content"], "What does this file say?"
    assert_includes body["content"], "[Attached file: test.txt"

    message = UserMessage.find(body["id"])
    assert message.attachment.attached?
  end

  test "creates message with a PDF attachment routed to bank statement import" do
    pdf_import_id = SecureRandom.uuid
    pdf_import = mock
    pdf_import.stubs(:id).returns(pdf_import_id)
    pdf_import.expects(:process_with_ai_later).returns(true)
    PdfImport.expects(:create_from_upload!).returns(pdf_import)

    post "/api/v1/chats/#{@chat.id}/messages",
      params: { file: fixture_file_upload("test.txt", "application/pdf") },
      headers: bearer_auth_header(@write_token)

    assert_response :created
    body = JSON.parse(response.body)

    assert_includes body["content"], "import_bank_statement"
    assert_includes body["content"], pdf_import_id
  end

  test "rejects message with neither content nor file" do
    post "/api/v1/chats/#{@chat.id}/messages",
      params: { content: "" },
      headers: bearer_auth_header(@write_token)

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "rejects oversized upload" do
    upload = fixture_file_upload("test.txt", "text/plain")
    ActionDispatch::Http::UploadedFile.any_instance.stubs(:size).returns(Chat::UploadRouter::MAX_SIZE + 1)

    post "/api/v1/chats/#{@chat.id}/messages",
      params: { file: upload },
      headers: bearer_auth_header(@write_token)

    assert_response :unprocessable_entity
    assert_equal "file_too_large", JSON.parse(response.body)["error"]
  end

  test "attachment endpoint redirects to the blob" do
    Family.any_instance.stubs(:upload_document).returns(nil)

    post "/api/v1/chats/#{@chat.id}/messages",
      params: { content: "with file", file: fixture_file_upload("test.txt", "text/plain") },
      headers: bearer_auth_header(@write_token)
    message_id = JSON.parse(response.body)["id"]

    get "/api/v1/chats/#{@chat.id}/messages/#{message_id}/attachment",
      headers: bearer_auth_header(@write_token)

    assert_response :redirect
    assert_includes response.location, "rails/active_storage"
  end

  test "attachment endpoint returns 404 when message has no attachment" do
    message = @chat.messages.create!(type: "UserMessage", content: "no file", ai_model: "gpt-4.1")

    get "/api/v1/chats/#{@chat.id}/messages/#{message.id}/attachment",
      headers: bearer_auth_header(@write_token)

    assert_response :not_found
  end

  private

    def bearer_auth_header(token)
      { "Authorization" => "Bearer #{token.token}" }
    end
end
