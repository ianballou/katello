module Katello
  module Pulp3
    class SharedRepositoryMirror < RepositoryMirror
      include Actions::Helpers::RollingCVRepos

      attr_accessor :content_mapper

      def initialize(repository_service)
        super(repository_service)
        @content_mapper = ::Katello::SmartProxyContentRepositoryMapper.new(smart_proxy)
      end

      # Override backend_object_name to use shared repository naming
      def backend_object_name
        content_mapper.generate_shared_pulp_id(repo)
      end

      # Override distribution_options to maintain original distribution names
      # while pointing to shared repository content
      def distribution_options(path, options = {})
        ret = {
          base_path: path,
          name: repo.pulp_id, # Keep original pulp_id for distribution name - NOT shared name
        }
        ret[:content_guard] = repo.unprotected ? nil : content_guard_href
        ret[:publication] = options[:publication] if options.key? :publication
        ret[:repository_version] = options[:repository_version] if options.key? :repository_version
        ret
      end

      # Override sync to handle shared repositories
      def sync(options = {})
        # Only sync if this repository hasn't been synced by another repository sharing the same content
        if needs_sync?
          Rails.logger.info("Syncing shared repository for content: #{content_mapper.generate_content_key(repo)}")
          super(options)
        else
          Rails.logger.info("Skipping sync - shared repository already up to date for: #{repo.pulp_id}")
          []
        end
      end

      # Check if sync is needed for this shared repository
      def needs_sync?
        shared_repo = fetch_repository
        return true unless shared_repo

        # Check if any repository sharing this content has been synced recently
        content_key = content_mapper.generate_content_key(repo)
        sharing_map = content_mapper.repository_sharing_map([repo])
        
        return true unless sharing_map[content_key]

        # If any shared repository has been synced, we don't need to sync again
        sharing_map[content_key][:repositories].none? do |shared_repo|
          sync_history = shared_repo.smart_proxy_sync_histories.where(smart_proxy: smart_proxy).last
          sync_history&.finished_at&.present?
        end
      end

      # Override to ensure distributions point to shared repository
      def refresh_distributions(options = {})
        path = repo_service.relative_path
        dist_params = {}
        
        # Point distribution to the appropriate shared repository resource:
        # - For content types WITH publications (RPM, DEB): point to publication
        # - For content types WITHOUT publications (Docker, File): point directly to repository version
        if repo_service.repo.repository_type.pulp3_skip_publication
          # Content types like Docker/File serve directly from repository version
          dist_params[:repository_version] = version_href
          fail "could not lookup a version_href for shared repo #{repo.id}" if version_href.nil?
        else
          # Content types like RPM/DEB require a publication (processed metadata)
          dist_params[:publication] = publication_href
          fail "Could not lookup a publication_href for shared repo #{repo.id}" if publication_href.nil?
        end

        dist_options = distribution_options(path, dist_params)
        dist_options.delete(:content_guard) if repo_service.repo.content_type == "docker"
        
        # distribution_options already sets the correct name (repo.pulp_id)
        
        if (distro = repo_service.lookup_distributions(base_path: path).first) ||
          (distro = repo_service.lookup_distributions(name: repo.pulp_id).first)
          # update existing distribution to point to shared repository
          update_options = dist_options.except(:name)
          api.distributions_api.partial_update(distro.pulp_href, update_options)
        else
          # create new distribution pointing to shared repository
          create_distribution(path, dist_params)
        end
      end

      # Override create_distribution to point to shared repository
      def create_distribution(path, dist_params = {})
        if dist_params.empty?
          # Determine what the distribution should point to based on content type
          if repo_service.repo.repository_type.pulp3_skip_publication
            # Direct repository version reference for Docker/File/etc.
            dist_params[:repository_version] = version_href
          else
            # Publication reference for RPM/DEB/etc. (includes processed metadata)
            dist_params[:publication] = publication_href
          end
        end
        
        dist_options = distribution_options(path, dist_params)
        dist_options.delete(:content_guard) if repo_service.repo.content_type == "docker"
        
        distribution_data = api.distribution_class.new(dist_options)
        repo_service.distributions_api.create(distribution_data)
      end

      private

      def backend_service
        repo.backend_service(smart_proxy)
      end

      def api
        backend_service.api
      end
    end
  end
end