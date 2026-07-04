# frozen_string_literal: true

require "test_helper"

class Api::V1::TransactionAttachmentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.api_keys.active.destroy_all
    @read_api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "test_read_#{SecureRandom.hex(8)}"
    )
    @read_write_api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Write Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "test_rw_#{SecureRandom.hex(8)}"
    )

    @transaction = transactions(:one)
  end

  test "lists transaction attachments" do
    attachment = attach_pdf!

    get api_v1_transaction_attachments_url(@transaction), headers: api_headers(@read_api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_includes response_data["attachments"].map { |item| item["id"] }, attachment.id
    assert response_data["attachments"].first.key?("download_path")
  end

  test "uploads a transaction attachment" do
    file = fixture_file_upload("test.txt", "application/pdf")

    assert_difference("@transaction.attachments.count", 1) do
      post api_v1_transaction_attachments_url(@transaction),
           params: { attachment: file },
           headers: api_headers(@read_write_api_key)
    end

    assert_response :created
    response_data = JSON.parse(response.body)
    assert_equal 1, response_data["attachments"].size
    assert_equal "test.txt", response_data["attachments"].first["filename"]
  end

  test "uploads multiple transaction attachments" do
    file1 = fixture_file_upload("test.txt", "application/pdf")
    file2 = fixture_file_upload("profile_image.png", "image/png")

    assert_difference("@transaction.attachments.count", 2) do
      post api_v1_transaction_attachments_url(@transaction),
           params: { attachments: [ file1, file2 ] },
           headers: api_headers(@read_write_api_key)
    end

    assert_response :created
    assert_equal 2, JSON.parse(response.body)["attachments"].size
  end

  test "rejects unsupported file type" do
    file = fixture_file_upload("test.txt", "text/plain")

    assert_no_difference("@transaction.attachments.count") do
      post api_v1_transaction_attachments_url(@transaction),
           params: { attachment: file },
           headers: api_headers(@read_write_api_key)
    end

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "rejects upload with read-only key" do
    file = fixture_file_upload("test.txt", "application/pdf")

    assert_no_difference("@transaction.attachments.count") do
      post api_v1_transaction_attachments_url(@transaction),
           params: { attachment: file },
           headers: api_headers(@read_api_key)
    end

    assert_response :forbidden
  end

  test "redirects to attachment blob" do
    attachment = attach_pdf!

    get api_v1_transaction_attachment_url(@transaction, attachment, disposition: "attachment"),
        headers: api_headers(@read_api_key)

    assert_response :redirect
    assert_match(/disposition=attachment/, response.redirect_url)
  end

  test "deletes a transaction attachment" do
    attachment = attach_pdf!

    assert_difference("@transaction.attachments.count", -1) do
      delete api_v1_transaction_attachment_url(@transaction, attachment),
             headers: api_headers(@read_write_api_key)
    end

    assert_response :success
  end

  test "includes attachments in transaction payload" do
    attachment = attach_pdf!

    get api_v1_transaction_url(@transaction), headers: api_headers(@read_api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_includes response_data["attachments"].map { |item| item["id"] }, attachment.id
  end

  private

    def attach_pdf!
      @transaction.attachments.attach(
        io: StringIO.new("%PDF-1.4 test"),
        filename: "receipt.pdf",
        content_type: "application/pdf"
      )
      @transaction.attachments.last
    end
end
