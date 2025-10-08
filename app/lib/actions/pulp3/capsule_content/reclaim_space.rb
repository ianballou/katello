module Actions
  module Pulp3
    module CapsuleContent
      class ReclaimSpace < Pulp3::AbstractAsyncTask
        def plan(smart_proxy)
          action_subject(smart_proxy)
          if smart_proxy.pulp_primary?
            repository_prns = ::Katello::Pulp3::RepositoryReference.default_cv_repository_prns(::Katello::Repository.unscoped.on_demand, ::Organization.all)
            repository_prns.flatten!
          else
            if smart_proxy.download_policy != ::Katello::RootRepository::DOWNLOAD_ON_DEMAND
              fail _('Only On Demand smart proxies may have space reclaimed.')
            end
            repository_prns = ::Katello::Pulp3::Api::Core.new(smart_proxy).core_repositories_list_all(fields: 'prn').map(&:prn)
          end
          fail _('There is no downloaded content to clean.') if repository_prns.empty?
          plan_self(repository_prns: repository_prns, smart_proxy_id: smart_proxy.id)
        end

        def invoke_external_task
          output[:pulp_tasks] = ::Katello::Pulp3::Api::Core.new(SmartProxy.find(input[:smart_proxy_id])).
            repositories_reclaim_space_api.reclaim(repo_prns: input[:repository_prns])
        end

        def rescue_strategy
          Dynflow::Action::Rescue::Skip
        end
      end
    end
  end
end
