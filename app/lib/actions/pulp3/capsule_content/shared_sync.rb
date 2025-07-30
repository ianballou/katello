module Actions
  module Pulp3
    module CapsuleContent
      class SharedSync < Sync
        # Enhanced sync action that supports repository sharing on smart proxies
        
        def plan(repository, smart_proxy, options = {})
          # Check if repository sharing is enabled
          if repository_sharing_enabled?
            plan_shared_sync(repository, smart_proxy, options)
          else
            # Fall back to regular sync
            super(repository, smart_proxy, options)
          end
        end

        private

        def plan_shared_sync(repository, smart_proxy, options)
          # Use content mapper to determine sharing strategy
          content_mapper = ::Katello::SmartProxyContentRepositoryMapper.new(smart_proxy)
          
          sequence do
            sync_task = plan_self(
              repository_id: repository.id,
              smart_proxy_id: smart_proxy.id,
              options: options.merge(use_sharing: true)
            )
            options[:sync_task_output] = sync_task.output[:pulp_tasks]
            plan_action(GenerateMetadata, repository, smart_proxy, options)
          end
        end

        def invoke_external_task
          repo = ::Katello::Repository.find(input[:repository_id])
          
          if input[:options][:use_sharing]
            # Use shared repository mirror
            repo_service = repo.backend_service(smart_proxy)
            shared_mirror = ::Katello::Pulp3::SharedRepositoryMirror.new(repo_service)
            sync_options = {}
            sync_options[:optimize] = !input[:options].fetch(:skip_metadata_check, false)
            output[:pulp_tasks] = shared_mirror.sync(sync_options)
          else
            # Use regular mirror
            super
          end
        end

        def repository_sharing_enabled?
          # Check if feature flag is enabled
          Setting[:smart_proxy_repository_sharing] == true
        end
      end
    end
  end
end