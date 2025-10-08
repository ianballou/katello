module Katello
  module Pulp3
    class SmartProxyMirrorRepository < SmartProxyRepository
      def initialize(smart_proxy)
        fail "Cannot use a central pulp smart proxy" if smart_proxy.pulp_primary?
        @smart_proxy = smart_proxy
      end

      def orphaned_repositories
        repo_map = {}

        smart_proxy_helper = ::Katello::SmartProxyHelper.new(smart_proxy)
        katello_pulp_ids = smart_proxy_helper.combined_repos_available_to_capsule.map(&:pulp_id)
        pulp3_enabled_repo_types.each do |repo_type|
          api = repo_type.pulp3_api(smart_proxy)
          repo_map[api] = api.list_all.reject { |capsule_repo| katello_pulp_ids.include? capsule_repo.name }
        end

        repo_map
      end

      def orphan_repository_versions
        repo_version_map = {}

        pulp3_enabled_repo_types.each do |repo_type|
          api = repo_type.pulp3_api(smart_proxy)
          version_prns = api.repository_versions
          orphan_version_prns = api.list_all.collect do |pulp_repo|
            mirror_repo_versions = api.versions_list_for_repository(pulp_repo.prn, ordering: ['-pulp_created'])
            version_prns = mirror_repo_versions.select { |repo_version| repo_version.number != 0 }.collect { |version| version.prn }

            version_prns - [pulp_repo.latest_version_href]
          end
          repo_version_map[api] = orphan_version_prns.flatten
        end

        repo_version_map
      end

      def report_misconfigured_repository_version(api, prn)
        # Reasons for distributions distributing orphaned repository versions:
        # 1. The sync succeeded but Pulp did not update the publication (yum content)
        #    - Fix: completely resync the repository to the smart proxy (need to verify)
        # 2. The sync suceeded but metadata was not generated (non-yum content)
        #    - Fix: completely resync the repository on the smart proxy (need to verify)
        # 3. A repository, distribution, and publication was lost track of
        #    - Fix: same as 4
        # 4. Pulp content was modified outside of Katello
        #    - Fix: find repositories outside of Katello and delete them. Deleting the entire repo works and leaves an orphaned distribution.
        #        - If RemoveUnneededRepos goes first, this should be taken care of.
        # 5. An older repository version has a distribution, but the repository is not an orphan
        #    - Fix: delete the orphan distribution
        errors = []
        related_distributions = if api.repository_type.publications_api_class.present?
                                  publication_prns = api.publications_list_all(repository_version: prn).map(&:prn)
                                  # Searching distributions by publication isn't supported
                                  api.distributions_list_all.select { |dist| publication_prns.include? dist.publication }
                                else
                                  # Searching distributions by repository version isn't supported
                                  api.distributions_list_all.select { |dist| dist.repository_version == prn }
                                end
        repositories_to_redistribute = ::Katello::Repository.where(pulp_id: related_distributions.map(&:name))
        if repositories_to_redistribute.present?
          warning = "Completely resync (skip metadata check) repositories with the following paths to the smart proxy with ID #{smart_proxy.id}: " \
                    "#{repositories_to_redistribute.map(&:relative_path).join(', ')}. " \
                    "Orphan cleanup is skipped for these repositories until they are fixed on smart proxy with ID #{smart_proxy.id}. " \
                    "Try `hammer capsule content synchronize --id #{smart_proxy.id} --skip-metadata-check 1 ...` using " \
                    "--repository-id with #{repositories_to_redistribute.map(&:id).join(', ')}."
          errors << warning
          Rails.logger.warn(warning)
        end
        Rails.logger.debug("Orphan cleanup error: investigate the version_prn #{prn} on the smart proxy with ID #{smart_proxy.id} " \
                            "and the related distributions #{related_distributions.map(&:prn)}")
        Rails.logger.debug('It is likely that the related distributions are distributing an older version of the repository.')
        errors
      end

      # See app/services/katello/pulp3/smart_proxy_repository.rb#delete_orphan_repository_versions for foreman orphan cleanup
      def delete_orphan_repository_versions
        tasks = []
        errors = []
        orphan_repository_versions.each do |api, version_prns|
          version_prns.each do |prn|
            tasks << api.repository_versions_api.delete(prn)
          rescue => e
            if e.message.include?('Please update the necessary distributions first.')
              errors << report_misconfigured_repository_version(api, prn)
            else
              raise e
            end
          end
        end
        { pulp_tasks: tasks.flatten, errors: errors.flatten }
      end

      def delete_orphan_repositories
        tasks = []

        orphaned_repositories.each do |api, pulp3_repo_list|
          tasks << pulp3_repo_list.collect do |repo|
            api.repositories_api.delete(repo.prn)
          end
        end

        tasks.flatten!
      end

      def delete_orphan_distributions
        tasks = []
        pulp3_enabled_repo_types.each do |repo_type|
          orphan_distributions(repo_type).each do |distribution|
            tasks << repo_type.pulp3_api(smart_proxy).delete_distribution(distribution.prn)
          end
        end
        tasks
      end

      def orphan_distributions(repo_type)
        api = repo_type.pulp3_api(smart_proxy)
        api.distributions_list_all.select do |distribution|
          dist = api.get_distribution(distribution.prn)
          self.class.orphan_distribution?(dist)
        end
      end

      def self.orphan_distribution?(distribution)
        distribution.try(:publication).nil? &&
            distribution.try(:repository).nil? &&
            distribution.try(:repository_version).nil? ||
            ::Katello::Repository.pluck(:pulp_id).exclude?(distribution.name)
      end

      def delete_orphan_alternate_content_sources
        tasks = []
        known_acs_prns = []
        known_acss = smart_proxy.smart_proxy_alternate_content_sources
        known_acs_prns = known_acss.pluck(:alternate_content_source_prn) if known_acss.present?

        if RepositoryTypeManager.enabled_repository_types['file']
          file_acs_api = ::Katello::Pulp3::Repository.api(smart_proxy, 'file').alternate_content_source_api
          orphan_file_acs_prns = file_acs_api.list.results.map(&:prn) - known_acs_prns
          orphan_file_acs_prns.each do |orphan_file_acs_prn|
            tasks << file_acs_api.delete(orphan_file_acs_prn)
          end
        end
        if RepositoryTypeManager.enabled_repository_types['yum']
          yum_acs_api = ::Katello::Pulp3::Repository.api(smart_proxy, 'yum').alternate_content_source_api
          orphan_yum_acs_prns = yum_acs_api.list.results.map(&:prn) - known_acs_prns
          orphan_yum_acs_prns.each do |orphan_yum_acs_prn|
            tasks << yum_acs_api.delete(orphan_yum_acs_prn)
          end
        end
      end

      def delete_orphan_remotes
        tasks = []
        smart_proxy_helper = ::Katello::SmartProxyHelper.new(smart_proxy)
        repo_names = smart_proxy_helper.combined_repos_available_to_capsule.map(&:pulp_id)
        acs_remotes = Katello::SmartProxyAlternateContentSource.pluck(:remote_prn)
        pulp3_enabled_repo_types.each do |repo_type|
          api = repo_type.pulp3_api(smart_proxy)
          remotes = api.remotes_list_all(smart_proxy)

          remotes.each do |remote|
            if !repo_names.include?(remote.name) && !acs_remotes.include?(remote.prn)
              tasks << api.delete_remote(remote.prn)
            end
          end
        end
        tasks
      end
    end
  end
end
