require 'JSON'

# PayDock API - https://docs.paydock.com/

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class PaydockGateway < Gateway
      self.test_url = 'https://api-sandbox.paydock.com/v1/'
      self.live_url = 'https://api.paydock.com/v1/'

      self.default_currency = 'AUD'
      self.money_format = :dollars
      self.supported_countries = ['AU', 'NZ', 'GB', 'US', 'CA']
      self.supported_cardtypes = [:visa, :master, :american_express]

      self.homepage_url = 'https://paydock.com/'
      self.display_name = 'PayDock'

      AUTHORIZATION_MAP = {
          'h' => 'charge_id',
          'u' => 'customer_id',
          'g' => 'gateway_id',
          's' => 'payment_source_id',
          'v' => 'vault_token',
          'f' => 'first_name',
          'l' => 'last_name',
          'e' => 'email',
          'r' => 'customer_reference',
          't' => 'charge_reference',
          'x' => 'external_id'
      }

      STANDARD_ERROR_CODE_MAPPING = {}

      def initialize(options = {})
        super
        requires!(options, :login)
        requires!(options, :password)
        @gateway_id = options[:login]
        @secret_key = options[:password]
        @api_url = options[:url] || (test? ? test_url : live_url)
      end

      # Create a vault_token or payment_source
      def store(credit_card, options = {})
        options.deep_symbolize_keys!
        post = {}
        endpoint = 'vault/payment_sources'
        auth = {credit_card: credit_card}

        if options[:customer] || options[:customer_id] || options[:customer_from]
          add_customer(post, auth, options)
          add_gateway(post, options)
          add_credit_card(post[:customer][:payment_source], credit_card)

          endpoint = post[:customer_id] ? 'customers/' + post[:customer_id] : 'customers'
          post = post[:customer] # pull customer object up to root and drop everything else

        else
          options[:credit_card] = credit_card
          add_credit_card(post, credit_card)
        end

        commit(:post, endpoint, post, options)
      end

      # delete a vault_token or payment_source or customer
      def unstore(authorization, options = {})
        options.deep_symbolize_keys!
        auth = authorization_parse(authorization)

        method = nil
        endpoint = nil
        data = nil

        if (auth[:vault_token])
          method = :delete
          endpoint = 'vault-tokens/' + auth[:vault_token]
        end

        if (endpoint && method)
          commit(method, endpoint, data, options)
        end
      end

      # Authorize an amount on a credit card or vault token.
      # Once authorized, you can later capture this charge using the charge_id that is returned.
      def authorize(money, authorization, options = {})
        options[:capture] = false
        purchase(money, authorization, options)
      end

      # Create a charge using a credit card, card token or customer token
      #
      # To charge a credit card: purchase([money], [creditcard hash], ...)
      # To charge a customer, payment_source or vault_token: purchase([money], [authorization], ...)

      def purchase(money, authorization, options = {})
        options.deep_symbolize_keys!
        auth = authorization_parse(authorization)

        post = {}
        post[:capture] = options[:capture] if options.has_key?(:capture)


        add_amount(post, money, options)
        add_reference(post, options)
        add_customer(post, auth, options)
        add_payment_source(post, auth, options)
        if auth[:credit_card]
          add_credit_card(post[:customer][:payment_source], auth[:credit_card])
        end

        if post[:payment_source_id]
          post.except![:customer]
          post.except![:customer_id]
        end

        if post[:customer_id]
          post.except![:customer]
        end

        if !post[:customer_id] && !post[:payment_source_id]
          if auth.has_key?(:vault_token)
            add_vault_token(post, auth)
          end
          add_gateway(post, options)
        end

        commit(:post, 'charges', post, options)
      end


      def capture(amount, authorization, options = {})
        options.deep_symbolize_keys!
        auth = authorization_parse(authorization)
        post = {}
        add_amount(post, amount, options)
        commit(:post, 'charges/' + auth[:charge_id] + '/capture', post, options)
      end

      def refund(amount, authorization, options = {})
        options.deep_symbolize_keys!
        auth = authorization_parse(authorization)
        post = {}
        add_amount(post, amount, options)
        charge_id = auth[:charge_id] || ''
        commit(:post, 'charges/' + charge_id + '/refunds', post, options)
      end

      def supports_scrubbing
        true
      end

      def scrub(transcript)
        transcript.
            gsub(/(card_number\\?":\\?")(\d*)/, '\1[FILTERED]').
            gsub(/(card_ccv\\?":\\?")(\d*)/, '\1[FILTERED]')
      end

      private

      def add_amount(post, amount, options)
        post[:amount] = amount(amount).to_s
        post[:currency] = (options[:currency] || currency(amount))
        post[:currency] = post[:currency].upcase if post[:currency]
      end

      def add_gateway(post, options)
        post[:customer] = post[:customer] || {}
        post[:customer][:payment_source] = post[:customer][:payment_source] || {}
        post[:customer][:payment_source][:gateway_id] = (options[:gateway_id] || @gateway_id)
      end

      def add_customer(post, auth, options = {})
        customer = options[:customer] ? options[:customer].clone : {}

        # get customer_id provided
        customer_id = nil
        if options[:customer]
          customer_id = options[:customer][:id] if options[:customer][:id]
          customer_id = options[:customer][:_id] if options[:customer][:_id]
        end
        customer_id = post[:customer_id] if post[:customer_id]

        # get name from credit card
        if auth.has_key?(:credit_card)
          customer[:first_name] = auth[:credit_card].first_name
          customer[:last_name] = auth[:credit_card].last_name
        end

        # change authentication object if customer_from option set
        auth = authorization_parse(options[:customer_from]) if options[:customer_from]

        # get customer from authentication token
        customer_id = auth[:customer_id] if auth[:customer_id]
        customer[:first_name] = auth[:first_name] if auth[:first_name]
        customer[:last_name] = auth[:last_name] if auth[:last_name]
        customer[:email] = auth[:email] if auth[:email]
        customer[:reference] = auth[:customer_reference] if auth[:customer_reference]

        # overwrite with original options
        if (options[:customer])
          opt = options[:customer].except(:_id)
          opt = opt.except(:_id)
          customer = customer.merge(opt)
          customer = customer.merge!(opt)
        end

        # add customer to post
        post[:customer] = customer
        post[:customer_id] = customer_id if customer_id
        post[:customer][:_id] = customer_id if customer_id
      end

      def add_payment_source(post, auth, options = {}, payment_source = {})
        payment_source_id = auth[:payment_source_id] ? auth[:payment_source_id] : nil
        if payment_source_id
          post[:payment_source_id] = payment_source_id
        else
          post[:customer] = post[:customer] || {}
          post[:customer][:payment_source] = post[:customer][:payment_source] || {}
          post[:customer][:payment_source].merge(payment_source)

        end
      end

      def add_reference(post, options)
        post[:reference] = options[:reference] if options[:reference]
        post[:description] = options[:description] if options[:description]
      end

      def add_vault_token(post, auth)
        if auth[:vault_token]
          post[:customer] = post[:customer] || {}
          post[:customer][:payment_source] = post[:customer][:payment_source] || {}
          post[:customer][:payment_source][:vault_token] = auth[:vault_token]
        end
      end

      def add_credit_card(post, credit_card)
        if credit_card && credit_card.instance_of?(CreditCard)
          post[:card_name] = credit_card.name if credit_card.name
          post[:card_number] = credit_card.number if credit_card.number
          post[:card_ccv] = credit_card.verification_value if credit_card.verification_value
          post[:expire_month] = credit_card.month if credit_card.month
          post[:expire_year] = credit_card.year  if credit_card.year
        end
      end

      def authorization_from(endpoint, method, response, options = {})
        success = success_from(response)
        if (success)
          map = AUTHORIZATION_MAP.invert
          type = response['resource']['type']
          data = response['resource']['data']
          param = {}

          charge = type == 'charge' ? data : nil
          customer = type == 'customer' ? data : nil
          source = type == 'payment_source' ? data : nil

          # get customer from response
          if (charge && charge['customer'] && !customer)
            customer = charge['customer']
          end

          # get payment source from response
          if (customer && customer['payment_source'] && !source)
            source = customer['payment_source']
          end

          # get most recent payment source from payment_sources array
          if (customer && customer['payment_sources'] && !source)
            source = customer['payment_sources'].pop
          end

          # get first name and last from credit card
          if options[:credit_card]
            card = options[:credit_card]
            param[map['first_name']] = card.first_name if card.first_name
            param[map['last_name']] = card.last_name if card.last_name
          end

          # get info from charge object
          if charge
            param[map['charge_id']] = charge['_id'] if charge['_id']
            param[map['external_id']] = charge['external_id'] if charge['external_id']
            param[map['charge_reference']] = charge['reference'] if charge['reference']
            param[map['customer_id']] = charge['customer_id'] if charge['customer_id']
          end

          # get info form customer object
          if customer
            param[map['customer_id']] = customer['customer_id'] if customer['customer_id']
            param[map['customer_id']] = customer['_id'] if customer['_id']
            param[map['customer_reference']] = customer['reference'] if customer['reference']
            param[map['first_name']] = customer['first_name'] if customer['first_name']
            param[map['last_name']] = customer['last_name'] if customer['last_name']
            param[map['email']] = customer['email'] if customer['email']
          end

          # get info from payment_source object
          if source
            param[map['vault_token']] = source['vault_token'] if source['vault_token']
            param[map['payment_source_id']] = source['_id'] if source['_id']
            param[map['gateway_id']] = source['gateway_id'] if source['gateway_id']
          end

          param = param.to_param
          param == '' ? nil : param
          return param
        else
          return nil
        end
      end

      def authorization_parse(authorization)
        if authorization.is_a? String
          return Hash[CGI::parse(authorization).map {|k, v| [AUTHORIZATION_MAP[k].to_sym, v.first]}]
        elsif authorization.instance_of? CreditCard
          return {credit_card: authorization}
        else
          return {}
        end
      end

      def parse(body)
        JSON.parse(body)
      end

      def headers(options = {})
        key = options[:secret_key] || @secret_key
        headers = {
            'X-Accepts' => 'application/json',
            'User-Agent' => "ActiveMerchant/#{ActiveMerchant::VERSION}",
            'X-Client-IP' => options[:ip] || '',
            'X-User-Secret-Key' => key
        }
        headers
      end

      def fetch(action)
        url = (test? ? test_url : live_url) + action
        raw = ssl_get(url, headers(options))
      end

      def api_call(method, endpoint, data = nil, options = {})
        url = @api_url + endpoint
        raw = response = nil
        http_headers = headers(options)
        http_headers['Content-Type'] = 'application/json' if data != nil

        begin
          raw = ssl_request(method, url, json_data(data), http_headers)
          response = parse(raw)
        rescue ResponseError => e
          raw = e.response.body
          response = response_error(raw)
        rescue JSON::ParserError
          response = json_error(raw)
        end
        response
      rescue JSON::ParserError
        message = 'Invalid JSON received from PayDock API (' + @api_url + '). Please contact support@paydock.com'
        message += " (Raw: #{raw.inspect})"
        Response.new(false, message)
      end

      def commit(method, endpoint, data = nil, options = {})
        response = api_call(method, endpoint, data, options)
        success = success_from(response)
        Response.new(success,
                     message_from(response),
                     response,
                     :test => test?,
                     :authorization => authorization_from(endpoint, method, response, options),
                     :error_code => success ? nil : error_code_from(response)
        )
      end

      def error_code_from(response)
        return STANDARD_ERROR_CODE_MAPPING['processing_error'] unless response['error']

        code = response['error']['code']
        decline_code = response['error']['decline_code'] if code == 'card_declined'

        error_code = STANDARD_ERROR_CODE_MAPPING[decline_code]
        error_code ||= STANDARD_ERROR_CODE_MAPPING[code]
        error_code
      end

      def json_data(data)
        if !data.is_a? String
          data = data.to_json
        end
        data
      end

      def message_from(response)
        success = success_from(response)

        success ? response['status'] : response.fetch('error', {'message' => 'No error details'})['message']
      end

      def success_from(response)
        success = true
        if (response.key?('error') && response['error'] != nil)
          success = false
        else
          if (response['status'] < 200 || response['status'] > 300)
            success = false
          end
        end
        success
      end

      def response_error(raw)
        parse(raw)
      rescue JSON::ParserError
        json_error(raw)
      end

      def json_error(raw)
        msg = 'Invalid response received from the PayDock API.  Please contact support@paydock.com if you continue to receive this message.'
        msg += "  (The raw response returned by the API was #{raw.inspect})"
        {
            'error' => {
                'message' => msg
            }
        }
      end


    end
  end
end