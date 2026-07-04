# frozen_string_literal: true

class Api::V1::FamilyDocumentsController < Api::V1::BaseController
  include Pagy::Backend

  MAX_UPLOAD_SIZE = Import::MAX_PDF_SIZE

  before_action :ensure_read_scope, only: %i[index show search]
  before_action :ensure_write_scope, only: %i[create destroy]
  before_action :set_family_document, only: %i[show destroy]

  def index
    @per_page = safe_per_page_param
    @pagy, documents = pagy(
      current_resource_owner.family.family_documents.order(created_at: :desc),
      page: safe_page_param,
      limit: @per_page
    )

    render json: {
      family_documents: documents.map { |document| family_document_payload(document) },
      pagination: pagination_payload,
      vector_store: vector_store_capabilities_payload
    }
  end

  def show
    render json: { family_document: family_document_payload(@family_document) }
  end

  def create
    adapter = vector_store_adapter
    return render_provider_not_configured unless adapter

    file = document_upload
    unless file
      render_validation_error("file is required")
      return
    end

    validation_error = validate_upload(file, adapter)
    return render_validation_error(validation_error) if validation_error

    content = file.read
    file.rewind if file.respond_to?(:rewind)
    if content.bytesize > MAX_UPLOAD_SIZE
      render_validation_error("File is too large. Maximum size is #{MAX_UPLOAD_SIZE / 1.megabyte}MB.")
      return
    end

    document = current_resource_owner.family.upload_document(
      file_content: content,
      filename: file.original_filename.to_s,
      metadata: document_metadata
    )

    unless document
      render json: {
        error: "document_upload_failed",
        message: "Document could not be uploaded to the vector store."
      }, status: :bad_gateway
      return
    end

    render json: { family_document: family_document_payload(document) }, status: :created
  rescue StandardError => e
    Rails.logger.error "FamilyDocumentsController#create error: #{e.message}"
    render json: { error: "internal_server_error", message: "Document could not be uploaded." }, status: :internal_server_error
  end

  def search
    query = params[:query].to_s.strip
    if query.blank?
      render_validation_error("query is required")
      return
    end

    unless current_resource_owner.family.vector_store_id.present?
      render json: {
        error: "no_documents",
        message: "No documents have been uploaded to the family document store yet.",
        results: []
      }, status: :unprocessable_entity
      return
    end

    adapter = vector_store_adapter
    return render_provider_not_configured unless adapter

    response = adapter.search(
      store_id: current_resource_owner.family.vector_store_id,
      query: query,
      max_results: safe_max_results_param
    )

    unless response.success?
      render json: {
        error: "search_failed",
        message: "Failed to search documents: #{response.error&.message}"
      }, status: :bad_gateway
      return
    end

    render json: {
      query: query,
      result_count: response.data.length,
      results: response.data.map { |result| search_result_payload(result) }
    }
  rescue StandardError => e
    Rails.logger.error "FamilyDocumentsController#search error: #{e.message}"
    render json: { error: "internal_server_error", message: "Document search could not be completed." }, status: :internal_server_error
  end

  def destroy
    unless current_resource_owner.family.remove_document(@family_document)
      render json: {
        error: "document_delete_failed",
        message: "Document could not be removed from the vector store."
      }, status: :bad_gateway
      return
    end

    render json: { message: "Family document deleted successfully" }, status: :ok
  end

  private

    def set_family_document
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @family_document = current_resource_owner.family.family_documents.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "not_found", message: "Family document not found" }, status: :not_found
    end

    def vector_store_adapter
      VectorStore.adapter
    rescue VectorStore::ConfigurationError => e
      Rails.logger.warn "Family document vector store configuration error: #{e.message}"
      nil
    end

    def render_provider_not_configured
      render json: {
        error: "provider_not_configured",
        message: "No vector store provider is configured for family documents."
      }, status: :service_unavailable
    end

    def document_upload
      params[:file].presence || params.dig(:family_document, :file).presence
    end

    def validate_upload(file, adapter)
      return "Uploaded file is invalid" unless file.respond_to?(:original_filename) && file.respond_to?(:read)

      filename = file.original_filename.to_s
      return "filename is required" if filename.blank?

      ext = File.extname(filename).downcase
      return "Document PDFs should be uploaded through POST /api/v1/imports so they can be processed as PDF imports." if ext == ".pdf"
      return "File is too large. Maximum size is #{MAX_UPLOAD_SIZE / 1.megabyte}MB." if file.respond_to?(:size) && file.size.to_i > MAX_UPLOAD_SIZE

      supported_extensions = uploadable_extensions(adapter)
      return "Unsupported file type. Supported extensions are: #{supported_extensions.join(', ')}" unless supported_extensions.include?(ext)

      nil
    end

    def uploadable_extensions(adapter)
      adapter.supported_extensions.map(&:downcase).uniq.sort - [ ".pdf" ]
    end

    def document_metadata
      source = params[:family_document].present? ? params.require(:family_document) : params
      metadata = source[:metadata].respond_to?(:to_unsafe_h) ? source[:metadata].to_unsafe_h : {}
      metadata.to_h.merge(
        "source" => "api",
        "uploaded_by_user_id" => current_resource_owner.id
      )
    end

    def safe_max_results_param
      max_results = params[:max_results].to_i
      max_results.positive? ? max_results.clamp(1, 20) : 10
    end

    def pagination_payload
      {
        page: @pagy.page,
        per_page: @per_page,
        total_count: @pagy.count,
        total_pages: @pagy.pages
      }
    end

    def vector_store_capabilities_payload
      adapter = vector_store_adapter
      {
        configured: adapter.present?,
        supported_upload_extensions: adapter ? uploadable_extensions(adapter) : [],
        max_upload_size: MAX_UPLOAD_SIZE
      }
    end

    def family_document_payload(document)
      {
        id: document.id,
        filename: document.filename,
        content_type: document.content_type,
        file_size: document.file_size,
        status: document.status,
        metadata: document.metadata || {},
        created_at: document.created_at.iso8601,
        updated_at: document.updated_at.iso8601
      }
    end

    def search_result_payload(result)
      {
        filename: result[:filename],
        content: result[:content],
        score: result[:score]
      }
    end
end
