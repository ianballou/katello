module Actions
  module Katello
    module CapsuleContent
      class ConsolidateRepositories < ::Actions::EntryAction
        include ::Actions::Helpers::SmartProxySyncHistoryHelper

        def humanized_name
          _("Consolidate Duplicate Repositories")
        end

        def plan(smart_proxy, options = {})
          plan_self(smart_proxy_id: smart_proxy.id, options: options)
          action_subject(smart_proxy)
        end

        def run
          smart_proxy = ::SmartProxy.find(input[:smart_proxy_id])
          content_mapper = ::Katello::SmartProxyContentRepositoryMapper.new(smart_proxy)
          
          # Find repositories that can be consolidated
          shareable_groups = content_mapper.shareable_repositories
          
          consolidation_results = {
            processed_groups: 0,
            consolidated_repositories: 0,
            errors: []
          }

          shareable_groups.each do |content_key, group|
            begin
              result = consolidate_repository_group(smart_proxy, group)
              consolidation_results[:processed_groups] += 1
              consolidation_results[:consolidated_repositories] += result[:consolidated_count]
            rescue StandardError => e
              error_msg = "Failed to consolidate group #{content_key}: #{e.message}"
              Rails.logger.error(error_msg)
              consolidation_results[:errors] << error_msg
            end
          end

          output[:consolidation_results] = consolidation_results
        end

        private

        def consolidate_repository_group(smart_proxy, group)
          shared_pulp_id = group[:shared_pulp_id]
          repositories = group[:repositories]
          
          Rails.logger.info("Consolidating #{repositories.count} repositories into shared repository: #{shared_pulp_id}")
          
          # Find if any of these repositories already exists on the smart proxy
          existing_repo = find_existing_repository(smart_proxy, repositories)
          
          if existing_repo
            # Use existing repository as the shared one
            consolidate_to_existing_repository(smart_proxy, existing_repo, repositories)
          else
            # Create new shared repository
            create_shared_repository(smart_proxy, shared_pulp_id, repositories)
          end

          { consolidated_count: repositories.count - 1 } # -1 because we keep one as the shared repo
        end

        def find_existing_repository(smart_proxy, repositories)
          repositories.find do |repo|
            mirror = repo.backend_service(smart_proxy).with_mirror_adapter
            mirror.fetch_repository.present?
          end
        end

        def consolidate_to_existing_repository(smart_proxy, primary_repo, all_repositories)
          content_mapper = ::Katello::SmartProxyContentRepositoryMapper.new(smart_proxy)
          shared_pulp_id = content_mapper.generate_shared_pulp_id(primary_repo)
          
          primary_mirror = primary_repo.backend_service(smart_proxy).with_mirror_adapter
          primary_pulp_repo = primary_mirror.fetch_repository
          
          return unless primary_pulp_repo

          # Rename primary repository to shared name if needed
          if primary_pulp_repo.name != shared_pulp_id
            primary_mirror.api.repositories_api.partial_update(
              primary_pulp_repo.pulp_href,
              { name: shared_pulp_id }
            )
            Rails.logger.info("Renamed repository #{primary_pulp_repo.name} to shared name #{shared_pulp_id}")
          end

          # Ensure the shared repository has a publication
          ensure_shared_repository_publication(primary_mirror, primary_repo)

          # Update all distributions to point to the shared repository's publication/version
          all_repositories.each do |repo|
            update_repository_distributions(smart_proxy, repo)
            
            unless repo.id == primary_repo.id
              cleanup_old_repository(smart_proxy, repo)
              Rails.logger.info("Cleaned up duplicate repository for #{repo.pulp_id}")
            end
          end
        end

        def create_shared_repository(smart_proxy, shared_pulp_id, repositories)
          # Use the first repository as template
          template_repo = repositories.first
          repo_service = template_repo.backend_service(smart_proxy)
          shared_mirror = ::Katello::Pulp3::SharedRepositoryMirror.new(repo_service)
          
          # Create the shared repository - it will use the shared name from backend_object_name
          shared_mirror.create
          
          # Ensure the shared repository has a publication
          ensure_shared_repository_publication(shared_mirror, template_repo)
          
          # Update all distributions to point to the shared repository's publication/version
          repositories.each do |repo|
            update_repository_distributions(smart_proxy, repo)
            cleanup_old_repository(smart_proxy, repo)
          end
        end

        def update_repository_distributions(smart_proxy, repo)
          # Update distributions to point to the shared repository's publication/version
          # while maintaining the original distribution name and path
          begin
            repo_service = repo.backend_service(smart_proxy)
            shared_mirror = ::Katello::Pulp3::SharedRepositoryMirror.new(repo_service)
            shared_mirror.refresh_distributions
            Rails.logger.info("Updated distributions for repository #{repo.pulp_id} to point to shared repository")
          rescue StandardError => e
            Rails.logger.warn("Failed to update distributions for repository #{repo.pulp_id}: #{e.message}")
          end
        end

        def ensure_shared_repository_publication(mirror, repo)
          # Pulp content distribution hierarchy:
          # Repository → Repository Version → Publication → Distribution (for RPM, DEB, etc.)
          # Repository → Repository Version → Distribution (for Docker, File, etc. - no publication needed)
          
          # Skip publication creation for content types that serve directly from repository versions
          # (Docker, File, etc. use pulp3_skip_publication=true)
          return if repo.repository_type.pulp3_skip_publication

          begin
            # Check if publication already exists for the current repository version
            existing_publication = mirror.publication_href
            return if existing_publication

            # Create publication from the shared repository's latest version
            # This allows distributions to serve processed content (metadata, repodata, etc.)
            Rails.logger.info("Creating publication for shared repository: #{mirror.backend_object_name}")
            mirror.create_publication
          rescue StandardError => e
            Rails.logger.warn("Failed to create publication for shared repository #{mirror.backend_object_name}: #{e.message}")
          end
        end

        def cleanup_old_repository(smart_proxy, repo)
          # Look for repository with the old (non-shared) name
          old_mirror = repo.backend_service(smart_proxy).with_mirror_adapter
          content_mapper = ::Katello::SmartProxyContentRepositoryMapper.new(smart_proxy)
          shared_name = content_mapper.generate_shared_pulp_id(repo)
          
          # Find repository by original pulp_id name
          old_repos = old_mirror.api.list_all(name: repo.pulp_id)
          old_repos.each do |old_repo|
            if old_repo.name != shared_name
              begin
                old_mirror.delete(old_repo.pulp_href)
                Rails.logger.info("Cleaned up old repository: #{old_repo.name}")
              rescue StandardError => e
                Rails.logger.warn("Failed to cleanup old repository #{old_repo.name}: #{e.message}")
              end
            end
          end
        end
      end
    end
  end
end