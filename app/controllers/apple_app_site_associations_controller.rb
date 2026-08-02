# frozen_string_literal: true

class AppleAppSiteAssociationsController < ActionController::API
  def show
    render json: {
      applinks: {
        details: [
          {
            appIDs: [ "6JR3ZGLPD6.mujhtech.usemoney" ],
            components: [
              { "/": "/app/*" },
              { "/": "/events/30-day-savings-challenge" },
              { "/": "/events/30-day-savings-2026" }
            ]
          }
        ]
      },
      webcredentials: {
        apps: [ "6JR3ZGLPD6.mujhtech.usemoney" ]
      }
    }
  end
end
