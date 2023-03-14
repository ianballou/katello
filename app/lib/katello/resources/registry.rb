require 'katello/util/data'

module Katello
  module Resources
    require 'rest_client'

    module Registry
      class Proxy
        def self.logger
          ::Foreman::Logging.logger('katello/registry_proxy')
        end

        def self.get(path, headers = {:accept => :json}, options = {})
          logger.debug "Sending GET request to Registry: #{path}"
          resource = RegistryResource.load_class
          joined_path = resource.prefix.chomp("/") + path
          client = resource.rest_client(Net::HTTP::Get, :get, joined_path)
          client.options.merge!(options)
          client.get(headers)
        end

        def self.put(path, body, headers)
          logger.debug "Sending PUT request to Registry: #{path}"
          resource = RegistryResource.load_class
          joined_path = resource.prefix.chomp("/") + path
          #headers['Authorization'] = 'Basic ' + Base64.encode64('admin:password')
          resource.issue_request(method: :put, path: joined_path, headers: headers, payload: body)
        end

        def self.patch(path, body, headers)
          logger.debug "Sending PATCH request to Registry: #{path}"
          resource = RegistryResource.load_class
          joined_path = resource.prefix.chomp("/") + path
          #headers['Authorization'] = 'Basic ' + Base64.encode64('admin:password')
          #binding.pry
          resource.issue_request(method: :patch, path: joined_path, headers: headers, payload: body)
        end

        def self.post(path, body, headers)
          logger.debug "Sending PUT request to Registry: #{path}"
          resource = RegistryResource.load_class
          joined_path = resource.prefix.chomp("/") + path
          # FIXME: POSTing to the Pulpcore registry is still giving 401s.
          # For now, disable registry auth in Pulp here: https://github.com/pulp/pulp_container/blob/main/pulp_container/app/token_verification.py#L181
          #headers['Authorization'] = 'Basic ' + Base64.encode64('admin:password')
          #binding.pry
          resource.issue_request(method: :post, path: joined_path, headers: headers, payload: body)
        end
      end

      class RegistryResource < HttpResource
        class << self
          def logger
            ::Foreman::Logging.logger('katello/registry_proxy')
          end

          def load_class
            pulp_primary = ::SmartProxy.pulp_primary
            content_app_url = pulp_primary.setting(SmartProxy::PULP3_FEATURE, 'content_app_url')

            fail Errors::ContainerRegistryNotConfigured unless content_app_url

            uri = URI.parse(content_app_url)
            self.prefix = "/pulpcore_registry/"
            self.site = "#{uri.scheme}://#{uri.host}:#{uri.port}"
            self.ca_cert_file = Setting[:ssl_ca_file]
            pulp_primary.pulp3_ssl_configuration(self, :net_http)

            self
          end

          def process_response(response)
            debug_level = response.code >= 400 ? :error : :debug
            logger.send(debug_level, "Registry request returned with code #{response.code}")
            super
          end
        end
      end
    end
  end
end
