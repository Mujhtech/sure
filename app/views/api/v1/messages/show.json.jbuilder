# frozen_string_literal: true

json.partial! "api/v1/chats/message", message: @message

# Note: AI response will be processed asynchronously
if @message.type == "UserMessage"
  json.ai_response_status "pending"
  json.ai_response_message "AI response is being generated"
end
