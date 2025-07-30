module Katello
  class SmartProxyContentRepositoryMapper
    attr_accessor :smart_proxy

    def initialize(smart_proxy)
      @smart_proxy = smart_proxy
    end

    # Maps Katello repositories to shared content repositories on the smart proxy
    # Groups repositories by content fingerprint to enable sharing
    def repository_sharing_map(repositories)
      content_groups = {}
      
      repositories.each do |repo|
        content_key = generate_content_key(repo)
        content_groups[content_key] ||= {
          shared_pulp_id: generate_shared_pulp_id(repo),
          repositories: [],
          version_href: repo.version_href
        }
        content_groups[content_key][:repositories] << repo
      end

      content_groups
    end

    # Generate a content-based key for grouping repositories with identical content
    def generate_content_key(repository)
      # Use content view version ID and library instance to identify identical content
      # This ensures repositories with the same content share the same Pulp repository
      "#{repository.content_view_version_id}_#{repository.library_instance_or_self.id}_#{repository.content_type}"
    end

    # Generate a shared pulp_id that doesn't include environment-specific information
    def generate_shared_pulp_id(repository)
      # Create a shared identifier based on content, not environment
      org_label = repository.organization.label
      cv_label = repository.content_view.label
      cv_version = repository.content_view_version.version
      product_label = repository.product.label
      repo_label = repository.label
      
      "#{org_label}-#{cv_label}-#{cv_version}-#{product_label}-#{repo_label}-shared"
    end

    # Map distributions to repositories considering the shared repository approach
    def distribution_mapping(content_groups)
      distribution_map = {}
      
      content_groups.each do |content_key, group_data|
        shared_pulp_id = group_data[:shared_pulp_id]
        
        group_data[:repositories].each do |repo|
          # Each repository still gets its own distribution for environment-specific access
          dist_path = "#{repo.organization.label}/#{repo.environment.label}/#{repo.content_view.label}/#{repo.relative_path}"
          distribution_map[repo.id] = {
            base_path: dist_path,
            shared_repository_pulp_id: shared_pulp_id,
            repository: repo
          }
        end
      end
      
      distribution_map
    end

    # Check if repositories can safely share content
    def can_share_content?(repo1, repo2)
      # Must be same content type, same library instance, same content view version
      repo1.content_type == repo2.content_type &&
        repo1.library_instance_or_self.id == repo2.library_instance_or_self.id &&
        repo1.content_view_version_id == repo2.content_view_version_id &&
        repo1.version_href == repo2.version_href
    end

    # Get repositories that would benefit from sharing
    def shareable_repositories(environment = nil, content_view = nil)
      smart_proxy_helper = ::Katello::SmartProxyHelper.new(smart_proxy)
      repositories = smart_proxy_helper.repositories_available_to_capsule(environment, content_view)
      
      # Group by content and filter groups with multiple repositories
      sharing_map = repository_sharing_map(repositories)
      sharing_map.select { |_, group| group[:repositories].count > 1 }
    end

    # Calculate potential space savings
    def estimate_space_savings
      shareable_groups = shareable_repositories
      total_repositories = 0
      shared_repositories = 0
      
      shareable_groups.each do |_, group|
        total_repositories += group[:repositories].count
        shared_repositories += 1  # One shared repository per group
      end
      
      {
        original_count: total_repositories,
        shared_count: shared_repositories,
        reduction_count: total_repositories - shared_repositories,
        reduction_percentage: total_repositories > 0 ? ((total_repositories - shared_repositories).to_f / total_repositories * 100).round(2) : 0
      }
    end
  end
end