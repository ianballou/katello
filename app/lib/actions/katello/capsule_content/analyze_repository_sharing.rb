module Actions
  module Katello
    module CapsuleContent
      class AnalyzeRepositorySharing < ::Actions::Base
        def humanized_name
          _("Analyze Repository Sharing Opportunities")
        end

        def plan(smart_proxy, options = {})
          plan_self(smart_proxy_id: smart_proxy.id, options: options)
        end

        def run
          smart_proxy = ::SmartProxy.find(input[:smart_proxy_id])
          content_mapper = ::Katello::SmartProxyContentRepositoryMapper.new(smart_proxy)
          
          # Analyze current sharing opportunities
          analysis = perform_analysis(content_mapper)
          
          output[:analysis] = analysis
          output[:recommendations] = generate_recommendations(analysis)
        end

        private

        def perform_analysis(content_mapper)
          shareable_groups = content_mapper.shareable_repositories
          space_savings = content_mapper.estimate_space_savings
          
          analysis = {
            total_repositories: ::Katello::SmartProxyHelper.new(content_mapper.smart_proxy).repositories_available_to_capsule.count,
            shareable_groups: shareable_groups.count,
            repositories_in_shareable_groups: shareable_groups.sum { |_, group| group[:repositories].count },
            space_savings: space_savings,
            detailed_groups: []
          }

          # Add detailed information about each shareable group
          shareable_groups.each do |content_key, group|
            group_info = {
              content_key: content_key,
              shared_pulp_id: group[:shared_pulp_id],
              repository_count: group[:repositories].count,
              repositories: group[:repositories].map do |repo|
                {
                  id: repo.id,
                  name: repo.name,
                  environment: repo.environment.name,
                  content_view: repo.content_view.name,
                  content_view_version: repo.content_view_version.version,
                  pulp_id: repo.pulp_id
                }
              end
            }
            analysis[:detailed_groups] << group_info
          end

          analysis
        end

        def generate_recommendations(analysis)
          recommendations = []

          if analysis[:shareable_groups] > 0
            unless Setting[:smart_proxy_repository_sharing]
              recommendations << {
                type: 'enable_sharing',
                priority: 'high',
                title: 'Enable Repository Sharing',
                description: "Enable repository sharing to reduce #{analysis[:space_savings][:reduction_count]} duplicate repositories (#{analysis[:space_savings][:reduction_percentage]}% reduction).",
                action: "Set 'smart_proxy_repository_sharing' setting to true"
              }
            end

            recommendations << {
              type: 'consolidate_repositories',
              priority: 'medium', 
              title: 'Consolidate Existing Repositories',
              description: "Run repository consolidation to merge existing duplicate repositories on the smart proxy.",
              action: "Execute repository consolidation task for smart proxy ID #{input[:smart_proxy_id]}"
            }
          else
            recommendations << {
              type: 'no_action_needed',
              priority: 'low',
              title: 'No Sharing Opportunities',
              description: "No duplicate repositories found that would benefit from sharing.",
              action: "No action required"
            }
          end

          recommendations
        end
      end
    end
  end
end
