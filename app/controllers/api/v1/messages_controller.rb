# frozen_string_literal: true

class Api::V1::MessagesController < Api::V1::BaseController
  before_action :require_ai_enabled
  before_action :ensure_read_scope, only: [ :attachment ]
  before_action :ensure_write_scope, only: [ :create, :retry, :report_timeout ]
  before_action :set_chat

  def create
    upload = params[:file]

    if message_params[:content].blank? && upload.blank?
      return render json: { error: "validation_failed", message: "Provide content or a file." }, status: :unprocessable_entity
    end

    if upload.present? && (upload_error = validate_upload(upload))
      return render json: upload_error[:body], status: upload_error[:status]
    end

    # NOTE: The AI response is triggered by UserMessage's after_create_commit
    # callback (app/models/user_message.rb) — do not enqueue it here too, or
    # clients receive duplicate responses.
    @message = UserMessage.compose!(
      chat: @chat,
      content: message_params[:content],
      ai_model: message_params[:model].presence || Chat.default_model,
      upload: upload,
      user: current_resource_owner
    )

    render :show, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: "Failed to create message", details: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def attachment
    message = @chat.messages.find(params[:id])

    unless message.attachment.attached?
      return render json: { error: "not_found", message: "Message has no attachment" }, status: :not_found
    end

    disposition = params[:disposition] == "attachment" ? "attachment" : "inline"
    redirect_to rails_blob_url(message.attachment, disposition: disposition), allow_other_host: true
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Message not found" }, status: :not_found
  end

  def retry
    last_message = @chat.conversation_messages.ordered.last

    unless last_message&.role == "user"
      return render json: { error: "No user message to retry" }, status: :unprocessable_entity
    end

    @chat.retry_last_message!
    pending_response = @chat.messages.where(type: "AssistantMessage", status: "pending").ordered.last

    render json: {
      message: "Retry initiated",
      message_id: pending_response&.id,
      chat_id: @chat.id
    }, status: :accepted
  end

  def report_timeout
    message = @chat.messages.find(params[:id])
    resolved = @chat.handle_undelivered_response!(message)

    render json: {
      message: resolved ? "Undelivered response resolved" : "No timed out assistant response to resolve",
      resolved: resolved,
      chat_id: @chat.id,
      message_id: message.id
    }, status: :ok
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Message not found" }, status: :not_found
  end

  private

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def validate_upload(upload)
      unless upload.respond_to?(:original_filename) && upload.respond_to?(:content_type)
        return { status: :unprocessable_entity, body: { error: "invalid_file", message: "file must be a multipart file upload" } }
      end

      if upload.size.to_i > Chat::UploadRouter::MAX_SIZE
        max_mb = Chat::UploadRouter::MAX_SIZE / 1.megabyte
        return { status: :unprocessable_entity, body: { error: "file_too_large", message: "File is too large. Maximum size is #{max_mb}MB." } }
      end

      nil
    end

    def set_chat
      @chat = current_resource_owner.chats.find(params[:chat_id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "Chat not found" }, status: :not_found
    end

    def message_params
      params.permit(:content, :model)
    end
end
