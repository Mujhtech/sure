# frozen_string_literal: true

class Api::V1::TransactionAttachmentsController < Api::V1::BaseController
  before_action :ensure_read_scope, only: %i[index show]
  before_action :ensure_write_scope, only: %i[create destroy]
  before_action :set_transaction
  before_action :set_attachment, only: %i[show destroy]

  def index
    @attachments = @transaction.attachments

    render :index
  end

  def show
    disposition = params[:disposition] == "attachment" ? "attachment" : "inline"

    redirect_to rails_blob_url(@attachment, disposition: disposition), allow_other_host: true
  end

  def create
    unless can_upload?
      render_forbidden("You do not have permission to upload attachments for this transaction")
      return
    end

    uploads = attachment_uploads
    if uploads.empty?
      render_validation_error("No files selected for upload")
      return
    end

    @transaction.with_lock do
      current_count = @transaction.attachments.count
      if current_count + uploads.size > Transaction::MAX_ATTACHMENTS_PER_TRANSACTION
        render_validation_error("Cannot exceed #{Transaction::MAX_ATTACHMENTS_PER_TRANSACTION} attachments")
        return
      end

      existing_ids = @transaction.attachments.pluck(:id)
      @transaction.attachments.attach(uploads)
      @attachments = @transaction.attachments.reject { |attachment| existing_ids.include?(attachment.id) }

      unless @transaction.valid?
        @attachments.each(&:purge)
        render json: {
          error: "validation_failed",
          message: "Attachment upload failed",
          errors: @transaction.errors.full_messages_for(:attachments)
        }, status: :unprocessable_entity
        return
      end
    end

    render :index, status: :created
  rescue StandardError => e
    Rails.logger.error "TransactionAttachmentsController#create error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def destroy
    unless can_delete?
      render_forbidden("You do not have permission to delete this attachment")
      return
    end

    @attachment.purge

    render json: { message: "Attachment deleted successfully" }, status: :ok
  rescue StandardError => e
    Rails.logger.error "TransactionAttachmentsController#destroy error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  private

    def set_transaction
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:transaction_id])

      @transaction = current_resource_owner.family.transactions
        .joins(entry: :account)
        .merge(Account.accessible_by(current_resource_owner))
        .find(params[:transaction_id])
      @account = @transaction.entry.account
    rescue ActiveRecord::RecordNotFound
      render json: {
        error: "not_found",
        message: "Transaction not found"
      }, status: :not_found
    end

    def set_attachment
      @attachment = @transaction.attachments.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: {
        error: "not_found",
        message: "Attachment not found"
      }, status: :not_found
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def account_permission
      @account.permission_for(current_resource_owner)
    end

    def can_upload?
      account_permission.in?(%i[owner full_control read_write])
    end

    def can_delete?
      account_permission.in?(%i[owner full_control])
    end

    def attachment_uploads
      uploads = if params.key?(:attachments)
        Array(params[:attachments])
      elsif params.key?(:attachment)
        [ params[:attachment] ]
      elsif params.key?(:file)
        [ params[:file] ]
      else
        []
      end

      uploads.filter_map do |upload|
        upload = upload[:file] if upload.respond_to?(:[]) && upload.respond_to?(:key?) && upload.key?(:file)
        upload.presence
      end
    end

    def render_forbidden(message)
      render json: {
        error: "forbidden",
        message: message
      }, status: :forbidden
    end
end
