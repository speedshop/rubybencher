module ApiAuthentication
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_api_request!
  end

  private

  def authenticate_api_request!
    token = request.headers['Authorization']&.remove('Bearer ')

    unless token.present? && valid_api_token?(token)
      render json: { error: 'Unauthorized' }, status: :unauthorized
    end
  end

  def valid_api_token?(token)
    expected_token = ENV.fetch('API_KEY', 'dev_api_key_change_in_production')
    ActiveSupport::SecurityUtils.secure_compare(token, expected_token)
  end
end
