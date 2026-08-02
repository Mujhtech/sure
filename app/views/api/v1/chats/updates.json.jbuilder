# frozen_string_literal: true

json.partial! "chat", chat: @chat

json.messages @messages do |message|
  json.partial! "message", message: message
end

json.pending_response @pending_response
json.server_time @server_time.iso8601(6)
