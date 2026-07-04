# frozen_string_literal: true

json.id invitation.id
json.email invitation.email
json.role invitation.role
json.pending invitation.pending?
json.accepted_existing_user local_assigns.fetch(:accepted_existing_user, false)
json.accepted_at invitation.accepted_at&.iso8601
json.expires_at invitation.expires_at&.iso8601
json.created_at invitation.created_at.iso8601
json.updated_at invitation.updated_at.iso8601

json.family do
  json.id invitation.family.id
  json.name invitation.family.name
end

json.inviter do
  json.id invitation.inviter.id
  json.email invitation.inviter.email
  json.display_name invitation.inviter.display_name
  json.initials invitation.inviter.initials
end

if Current.user&.admin? && Rails.configuration.app_mode.self_hosted? && invitation.pending?
  json.token invitation.token
  json.accept_url accept_invitation_url(invitation.token)
else
  json.token nil
  json.accept_url nil
end
