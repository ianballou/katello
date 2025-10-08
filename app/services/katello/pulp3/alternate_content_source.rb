require "pulpcore_client"
module Katello
  module Pulp3
    class AlternateContentSource
      include Katello::Pulp3::ServiceCommon
      attr_accessor :acs, :smart_proxy, :repository

      def initialize(acs, smart_proxy, repository = nil)
        @acs = acs
        @smart_proxy = smart_proxy
        @repository = repository
      end

      def api
        @api ||= ::Katello::Pulp3::Repository.api(smart_proxy, @acs.content_type)
      end

      def generate_backend_object_name
        "#{acs.label}-#{smart_proxy.url}-#{rand(9999)}"
      end

      def smart_proxy_acs
        if %w[custom rhui].include?(acs.alternate_content_source_type)
          ::Katello::SmartProxyAlternateContentSource.find_by(alternate_content_source_id: acs.id, smart_proxy_id: smart_proxy.id)
        else
          ::Katello::SmartProxyAlternateContentSource.find_by(alternate_content_source_id: acs.id, smart_proxy_id: smart_proxy.id, repository_id: repository.id)
        end
      end

      def simplified_acs_remote_options
        options = repository.backend_service(smart_proxy).remote_options
        options[:policy] = 'on_demand'
        # Potential RFE: allow inheriting of default smart proxy repo's HTTP proxies for simplified ACSs
        if acs.use_http_proxies
          options[:proxy_url] = smart_proxy.http_proxy&.url
          options[:proxy_username] = smart_proxy.http_proxy&.username
          options[:proxy_password] = smart_proxy.http_proxy&.password
        else
          options[:proxy_url] = nil
          options[:proxy_username] = nil
          options[:proxy_password] = nil
        end
        options
      end

      def remote_options
        return simplified_acs_remote_options if repository.present?

        remote_options = {
          tls_validation: acs.verify_ssl,
          name: generate_backend_object_name,
          url: acs.base_url,
          policy: 'on_demand',
          proxy_url: smart_proxy.http_proxy&.url,
          proxy_username: smart_proxy.http_proxy&.username,
          proxy_password: smart_proxy.http_proxy&.password,
          total_timeout: Setting[:sync_connect_timeout],
        }
        if acs.content_type == ::Katello::Repository::FILE_TYPE && acs.subpaths.empty? && !remote_options[:url].end_with?('/PULP_MANIFEST')
          remote_options[:url] = acs.base_url + '/PULP_MANIFEST'
        end
        unless acs.use_http_proxies
          remote_options[:proxy_url] = nil
          remote_options[:proxy_username] = nil
          remote_options[:proxy_password] = nil
        end
        remote_options.merge!(username: acs&.upstream_username, password: acs&.upstream_password)
        remote_options.merge!(ssl_remote_options)
      end

      def ssl_remote_options
        if acs.custom? || acs.rhui?
          {
            client_cert: acs.ssl_client_cert&.content,
            client_key: acs.ssl_client_key&.content,
            ca_cert: acs.ssl_ca_cert&.content,
          }
        end
      end

      def create_remote
        if smart_proxy_acs&.remote_prn.nil?
          response = super
          smart_proxy_acs.update!(remote_prn: response.prn)
        end
      end

      def get_remote(prn = smart_proxy_acs.remote_prn)
        api.get_remotes_api(prn: prn).read(prn)
      end

      def update_remote(prn = smart_proxy_acs.remote_prn)
        api.get_remotes_api(prn: prn).partial_update(prn, remote_options)
      end

      def delete_remote(options = {})
        options[:prn] ||= smart_proxy_acs.remote_prn
        ignore_404_exception { api.get_remotes_api(prn: options[:prn]).delete(options[:prn]) } if options[:prn]
      end

      def create
        if smart_proxy_acs&.alternate_content_source_prn.nil?
          paths = acs.subpaths.deep_dup
          if acs.content_type == ::Katello::Repository::FILE_TYPE && acs.subpaths.present?
            paths = insert_pulp_manifest!(paths)
          end
          response = api.alternate_content_source_api.create(name: generate_backend_object_name, paths: paths.sort,
                                                             remote: smart_proxy_acs.remote_prn)
          smart_proxy_acs.update!(alternate_content_source_prn: response.prn)
          return response
        end
      end

      def read(prn = smart_proxy_acs.alternate_content_source_prn)
        api.alternate_content_source_api.read(prn)
      end

      def update
        prn = smart_proxy_acs.alternate_content_source_prn
        paths = acs.subpaths.deep_dup
        if acs.content_type == ::Katello::Repository::FILE_TYPE && acs.subpaths.present?
          paths = insert_pulp_manifest!(paths)
        end
        api.alternate_content_source_api.update(prn, name: generate_backend_object_name, paths: paths.sort, remote: smart_proxy_acs.remote_prn)
      end

      def delete_alternate_content_source
        prn = smart_proxy_acs.alternate_content_source_prn
        ignore_404_exception { api.alternate_content_source_api.delete(prn) } if prn
      end

      def refresh
        prn = smart_proxy_acs.alternate_content_source_prn
        api.alternate_content_source_api.refresh(prn)
      end

      private

      def insert_pulp_manifest!(subpaths)
        subpaths.map! do |subpath|
          if subpath.end_with?('/PULP_MANIFEST')
            subpath
          else
            subpath + '/PULP_MANIFEST'
          end
        end
      end
    end
  end
end
