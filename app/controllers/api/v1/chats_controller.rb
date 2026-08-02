# frozen_string_literal: true

class Api::V1::ChatsController < Api::V1::BaseController
  include Pagy::Backend
  before_action :require_ai_enabled
  before_action :ensure_read_scope, only: [ :index, :show, :updates ]
  before_action :ensure_write_scope, only: [ :create, :update, :destroy ]
  before_action :set_chat, only: [ :show, :update, :destroy, :updates ]

  def index
    @pagy, @chats = pagy(current_resource_owner.chats.ordered, items: 20)
  end

  def show
    return unless @chat
    @pagy, @messages = pagy(@chat.messages.ordered, items: 50)
  end

  # Incremental polling endpoint for API clients (e.g. mobile apps) waiting on
  # an assistant response. Returns only messages created or updated since the
  # given cursor, so clients don't have to re-fetch the whole conversation.
  #
  # Pass `since` (the `server_time` of the previous poll). The window is
  # inclusive, so an update landing in the same instant as the previous poll is
  # never missed; clients should upsert messages by id.
  MAX_UPDATES_MESSAGES = 200

  def updates
    return unless @chat

    since = parse_since_param
    return if performed?

    scope = @chat.messages.ordered
    scope = scope.where(updated_at: since..) if since

    @server_time = Time.current
    @messages = scope.last(MAX_UPDATES_MESSAGES)
    @pending_response = @chat.messages.where(type: "AssistantMessage", status: "pending").exists?
  end

  def create
    permitted_params = chat_params

    if permitted_params[:message].present?
      @chat = current_resource_owner.chats.start!(permitted_params[:message], model: permitted_params[:model])
      @chat.update!(title: permitted_params[:title]) if permitted_params[:title].present?
      @messages = @chat.messages.ordered

      render :show, status: :created
    else
      @chat = current_resource_owner.chats.build(title: permitted_params[:title])

      if @chat.save
        render :show, status: :created
      else
        render json: { error: "Failed to create chat", details: @chat.errors.full_messages }, status: :unprocessable_entity
      end
    end
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: "Failed to create chat", details: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def update
    return unless @chat

    if @chat.update(update_chat_params)
      render :show
    else
      render json: { error: "Failed to update chat", details: @chat.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    return unless @chat
    @chat.destroy
    head :no_content
  end

  private

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def set_chat
      @chat = current_resource_owner.chats.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "Chat not found" }, status: :not_found
    end

    def parse_since_param
      return nil if params[:since].blank?

      Time.iso8601(params[:since])
    rescue ArgumentError
      render json: { error: "invalid_since", message: "since must be an ISO8601 timestamp" }, status: :unprocessable_entity
      nil
    end

    def chat_params
      params.permit(:title, :message, :model)
    end

    def update_chat_params
      params.permit(:title)
    end
end
