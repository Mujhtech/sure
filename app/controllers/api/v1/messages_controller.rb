# frozen_string_literal: true

class Api::V1::MessagesController < Api::V1::BaseController
  before_action :require_ai_enabled
  before_action :ensure_write_scope, only: [ :create, :retry, :report_timeout ]
  before_action :set_chat

  def create
    @message = @chat.messages.build(
      content: message_params[:content],
      type: "UserMessage",
      ai_model: message_params[:model].presence || Chat.default_model
    )

    if @message.save
      # NOTE: Commenting out duplicate job enqueue to fix mobile app receiving duplicate AI responses
      # UserMessage model already triggers AssistantResponseJob via after_create_commit callback
      # in app/models/user_message.rb:10-12, so this manual enqueue causes the job to run twice,
      # resulting in duplicate AI responses with different content and wasted tokens.
      # See: https://github.com/dwvwdv/sure (mobile app integration issue)
      # AssistantResponseJob.perform_later(@message)
      render :show, status: :created
    else
      render json: { error: "Failed to create message", details: @message.errors.full_messages }, status: :unprocessable_entity
    end
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

    def ensure_write_scope
      authorize_scope!(:write)
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
