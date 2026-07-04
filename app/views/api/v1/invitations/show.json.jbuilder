# frozen_string_literal: true

json.partial! "api/v1/invitations/invitation",
              invitation: @invitation,
              accepted_existing_user: @accepted_existing_user
