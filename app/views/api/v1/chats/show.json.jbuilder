# frozen_string_literal: true

json.partial! "chat", chat: @chat

json.messages @messages do |message|
  json.id message.id
  json.chat_id message.chat_id
  json.type message.type.underscore
  json.status message.status
  json.role message.role
  json.content message.content
  json.model message.ai_model if message.type == "AssistantMessage"
  json.ai_response_status message.status if message.type == "AssistantMessage"
  json.ai_response_message "AI response is being generated" if message.type == "AssistantMessage" && message.pending?
  json.created_at message.created_at.iso8601
  json.updated_at message.updated_at.iso8601

  # Include tool calls for assistant messages
  if message.type == "AssistantMessage" && message.tool_calls.any?
    json.tool_calls message.tool_calls do |tool_call|
      json.id tool_call.id
      json.provider_id tool_call.provider_id
      json.type tool_call.type&.underscore
      json.function_name tool_call.function_name
      json.function_arguments tool_call.function_arguments
      json.function_result tool_call.function_result
      json.created_at tool_call.created_at.iso8601
    end
  end
end

if @pagy
  json.pagination do
    json.page @pagy.page
    json.per_page @pagy.vars[:items]
    json.total_count @pagy.count
    json.total_pages @pagy.pages
  end
end
