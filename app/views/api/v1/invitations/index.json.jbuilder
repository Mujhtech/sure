# frozen_string_literal: true

json.invitations @invitations do |invitation|
  json.partial! "api/v1/invitations/invitation", invitation: invitation, accepted_existing_user: false
end
