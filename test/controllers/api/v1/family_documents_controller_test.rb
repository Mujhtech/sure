# frozen_string_literal: true

require "test_helper"

class Api::V1::FamilyDocumentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.update!(vector_store_id: nil)

    @user.api_keys.active.destroy_all
    @api_key = ApiKey.create!(
      user: @user,
      name: "Family Documents Test Key",
      scopes: [ "read_write" ],
      display_key: "family_docs_rw_#{SecureRandom.hex(8)}",
      source: "web"
    )
    @read_only_api_key = ApiKey.create!(
      user: @user,
      name: "Family Documents Read Key",
      scopes: [ "read" ],
      display_key: "family_docs_read_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    Redis.new.del("api_rate_limit:#{@api_key.id}")
    Redis.new.del("api_rate_limit:#{@read_only_api_key.id}")

    @document = @family.family_documents.create!(
      filename: "mobile_notes.txt",
      content_type: "text/plain",
      file_size: 128,
      provider_file_id: "file-mobile-notes",
      status: "ready",
      metadata: { "source" => "test" }
    )
  end

  teardown do
    VectorStore.unstub(:adapter)
  end

  test "should list family documents with vector store capabilities" do
    VectorStore.stubs(:adapter).returns(vector_store_adapter)

    get "/api/v1/family_documents", headers: api_headers(@read_only_api_key)

    assert_response :success
    json_response = JSON.parse(response.body)

    assert_equal [ @document.id ], json_response["family_documents"].map { |document| document["id"] }
    assert_equal true, json_response.dig("vector_store", "configured")
    assert_includes json_response.dig("vector_store", "supported_upload_extensions"), ".txt"
    assert_not_includes json_response.dig("vector_store", "supported_upload_extensions"), ".pdf"
  end

  test "should show family document" do
    get "/api/v1/family_documents/#{@document.id}", headers: api_headers(@read_only_api_key)

    assert_response :success
    json_response = JSON.parse(response.body)

    assert_equal @document.id, json_response.dig("family_document", "id")
    assert_equal "mobile_notes.txt", json_response.dig("family_document", "filename")
  end

  test "should upload family document" do
    adapter = vector_store_adapter
    adapter.expects(:create_store).with(name: "Family #{@family.id} Documents").returns(
      VectorStore::Response.new(success?: true, data: { id: "vs-api-docs" }, error: nil)
    )
    adapter.expects(:upload_file).with(
      store_id: "vs-api-docs",
      file_content: "hello mobile",
      filename: "mobile_upload.txt"
    ).returns(VectorStore::Response.new(success?: true, data: { file_id: "file-api-upload" }, error: nil))
    VectorStore.stubs(:adapter).returns(adapter)

    assert_difference("@family.family_documents.count", 1) do
      post "/api/v1/family_documents",
           params: {
             file: Rack::Test::UploadedFile.new(
               StringIO.new("hello mobile"),
               "text/plain",
               original_filename: "mobile_upload.txt"
             ),
             family_document: {
               metadata: { "purpose" => "mobile-test" }
             }
           },
           headers: api_headers(@api_key)
    end

    assert_response :created
    json_response = JSON.parse(response.body)
    document = @family.family_documents.find(json_response.dig("family_document", "id"))

    assert_equal "mobile_upload.txt", document.filename
    assert_equal "file-api-upload", document.provider_file_id
    assert_equal "api", document.metadata["source"]
    assert_equal @user.id, document.metadata["uploaded_by_user_id"]
    assert_equal "mobile-test", document.metadata["purpose"]
    assert_equal "vs-api-docs", @family.reload.vector_store_id
  end

  test "should reject PDF family document uploads" do
    VectorStore.stubs(:adapter).returns(vector_store_adapter(supported_extensions: %w[.pdf .txt]))

    assert_no_difference("@family.family_documents.count") do
      post "/api/v1/family_documents",
           params: {
             file: Rack::Test::UploadedFile.new(
               StringIO.new("%PDF-not-needed"),
               "application/pdf",
               original_filename: "statement.pdf"
             )
           },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "validation_failed", json_response["error"]
    assert_match "/api/v1/imports", json_response["message"]
  end

  test "should require configured vector store provider for upload" do
    VectorStore.stubs(:adapter).returns(nil)

    post "/api/v1/family_documents",
         params: {
           file: Rack::Test::UploadedFile.new(
             StringIO.new("hello mobile"),
             "text/plain",
             original_filename: "mobile_upload.txt"
           )
         },
         headers: api_headers(@api_key)

    assert_response :service_unavailable
    json_response = JSON.parse(response.body)
    assert_equal "provider_not_configured", json_response["error"]
  end

  test "should reject upload with read-only API key" do
    VectorStore.stubs(:adapter).returns(vector_store_adapter)

    post "/api/v1/family_documents",
         params: {
           file: Rack::Test::UploadedFile.new(
             StringIO.new("hello mobile"),
             "text/plain",
             original_filename: "mobile_upload.txt"
           )
         },
         headers: api_headers(@read_only_api_key)

    assert_response :forbidden
  end

  test "should search uploaded family documents" do
    @family.update!(vector_store_id: "vs-api-docs")
    adapter = vector_store_adapter
    adapter.expects(:search).with(
      store_id: "vs-api-docs",
      query: "tax total",
      max_results: 3
    ).returns(
      VectorStore::Response.new(
        success?: true,
        data: [ { filename: "tax_return.txt", content: "Total income was 120000", score: 0.92, file_id: "file-tax" } ],
        error: nil
      )
    )
    VectorStore.stubs(:adapter).returns(adapter)

    get "/api/v1/family_documents/search",
        params: { query: "tax total", max_results: 3 },
        headers: api_headers(@read_only_api_key)

    assert_response :success
    json_response = JSON.parse(response.body)

    assert_equal "tax total", json_response["query"]
    assert_equal 1, json_response["result_count"]
    assert_equal "tax_return.txt", json_response.dig("results", 0, "filename")
    assert_equal "Total income was 120000", json_response.dig("results", 0, "content")
  end

  test "should require query for family document search" do
    get "/api/v1/family_documents/search", headers: api_headers(@read_only_api_key)

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal "validation_failed", json_response["error"]
  end

  test "should delete family document" do
    @family.update!(vector_store_id: "vs-api-docs")
    adapter = vector_store_adapter
    adapter.expects(:remove_file).with(
      store_id: "vs-api-docs",
      file_id: @document.provider_file_id
    ).returns(VectorStore::Response.new(success?: true, data: {}, error: nil))
    VectorStore.stubs(:adapter).returns(adapter)

    assert_difference("@family.family_documents.count", -1) do
      delete "/api/v1/family_documents/#{@document.id}", headers: api_headers(@api_key)
    end

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal "Family document deleted successfully", json_response["message"]
  end

  test "should not expose another family's document" do
    other_family = families(:empty)
    other_document = other_family.family_documents.create!(
      filename: "other.txt",
      content_type: "text/plain",
      file_size: 1,
      provider_file_id: "file-other",
      status: "ready"
    )

    get "/api/v1/family_documents/#{other_document.id}", headers: api_headers(@api_key)

    assert_response :not_found
    json_response = JSON.parse(response.body)
    assert_equal "not_found", json_response["error"]
  end

  test "should require authentication for family documents" do
    get "/api/v1/family_documents"

    assert_response :unauthorized
  end

  private

    def vector_store_adapter(supported_extensions: %w[.txt .csv .docx .pdf])
      mock("vector_store_adapter").tap do |adapter|
        adapter.stubs(:supported_extensions).returns(supported_extensions)
      end
    end

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end
end
