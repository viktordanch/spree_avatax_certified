require 'json'
require 'net/http'
require 'addressable/uri'
require 'base64'
require 'rest-client'
require 'logging'
# Avatax tax calculation API calls
class TaxSvc
  AVALARA_OPEN_TIMEOUT = ENV.fetch('AVALARA_OPEN_TIMEOUT', 2).to_i
  AVALARA_READ_TIMEOUT = ENV.fetch('AVALARA_READ_TIMEOUT', 6).to_i
  AVALARA_RETRY        = ENV.fetch('AVALARA_RETRY', 2).to_i
  ERRORS_TO_RETRY = [Timeout::Error, Errno::EINVAL, Errno::ECONNRESET, Errno::ECONNREFUSED, EOFError,
                     Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError].freeze

  def get_tax(request_hash)
    log(__method__, request_hash)
    RestClient.log = logger.logger

    response = SpreeAvataxCertified::Response::GetTax.new(request('get', request_hash))

    handle_response(response)
  end

  def cancel_tax(request_hash)
    log(__method__, request_hash)

    response = SpreeAvataxCertified::Response::CancelTax.new(request('cancel', request_hash))

    handle_response(response)
  end

  def estimate_tax(coordinates, sale_amount)
    if tax_calculation_enabled?
      log(__method__)

      return nil if coordinates.nil?
      sale_amount = 0 if sale_amount.nil?
      coor = coordinates[:latitude].to_s + ',' + coordinates[:longitude].to_s

      uri = URI(service_url + coor + '/get?saleamount=' + sale_amount.to_s)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      http.open_timeout = 1
      http.read_timeout = 1

      res = http.get(uri.request_uri, 'Authorization' => credential, 'Content-Type' => 'application/json')
      JSON.parse(res.body)
    end
  rescue => e
    logger.error e, 'Estimate Tax Error'
    'Estimate Tax Error'
  end

  def ping
    logger.info 'Ping Call'
    estimate_tax({ latitude: '40.714623', longitude: '-74.006605' }, 0)
  end

  def validate_address(address)
    begin
      uri = URI(address_service_url + address.to_query)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      http.open_timeout = 1
      http.read_timeout = 1
      request = http.get(uri.request_uri, 'Authorization' => credential)
    rescue => e
      logger.error(e)
    end

    response = SpreeAvataxCertified::Response::AddressValidation.new(request.body)
    handle_response(response)
  end

  protected

  def handle_response(response)
    result = response.result
    begin
      if response.error?
        raise response.result
      end

      logger.debug(result, response.description + ' Response')

    rescue => e
      logger.error(e.message, response.description + ' Error')
    end

    response
  end

  def logger
    @logger ||= SpreeAvataxCertified::AvataxLog.new('TaxSvc class', 'Call to tax service')
  end

  private

  def tax_calculation_enabled?
    Spree::Config.avatax_tax_calculation
  end

  def credential
    'Basic ' + Base64.encode64(account_number + ':' + license_key)
  end

  def service_url
    Spree::Config.avatax_endpoint + AVATAX_SERVICEPATH_TAX
  end

  def address_service_url
    Spree::Config.avatax_endpoint + AVATAX_SERVICEPATH_ADDRESS + 'validate?'
  end

  def license_key
    Spree::Config.avatax_license_key
  end

  def account_number
    Spree::Config.avatax_account
  end

  def request(uri, request_hash)
    tries ||= AVALARA_RETRY
    res = RestClient::Request.execute(method: :post,
                                      open_timeout: AVALARA_OPEN_TIMEOUT,
                                      read_timeout: AVALARA_READ_TIMEOUT,
                                      url: service_url + uri,
                                      payload:  JSON.generate(request_hash),
                                      headers: {
                                        authorization: credential,
                                        content_type: 'application/json'
                                      }) do |response, _request, _result|
      response
    end

    JSON.parse(res)
  rescue *(ERRORS_TO_RETRY + [RestClient::ExceptionWithResponse,
                              RestClient::ServerBrokeConnection,
                              RestClient::SSLCertificateNotVerified]) => e
    retry unless (tries -= 1).zero?
    logger.error e, 'Avalara Request Error'
  end

  def log(method, request_hash = nil)
    return if request_hash.nil?
    logger.debug(request_hash, "#{method.to_s} request hash")
  end
end
