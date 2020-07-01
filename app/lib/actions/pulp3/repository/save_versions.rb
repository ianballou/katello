module Actions
  module Pulp3
    module Repository
      class SaveVersions < Pulp3::Abstract
        def plan(repository_map, options)
          plan_self(:repository_map => repository_map, :tasks => options[:tasks], :incremental_update => options[:incremental_update])
        end

        def run
          # repo map example: `{"121"=>{"dest_repo"=>133, "base_version"=>0}, "122"=>{"dest_repo"=>134, "base_version"=>0}}`

          version_hrefs = input[:tasks].last[:created_resources]
          dest_repos = input[:repository_map].values.collect do |dest_repo_map|
            ::Katello::Repository.find(dest_repo_map[:dest_repo])
          end

          output[:contents_changed] = false
          output[:updated_repositories] = []
          dest_repos.each do |dest_repo|
            # Chop off the version number to compare base repo strings
            unversioned_href = dest_repo.version_href[0..-2].rpartition('/').first
            new_version_href = version_hrefs.detect do |version_href|
              unversioned_href == version_href[0..-2].rpartition('/').first
            end
            # Successive incremental updates won't generate a new repo version, so fetch the latest Pulp 3 repo version
            new_version_href ||= ::Katello::Pulp3::Api::Yum.new(SmartProxy.pulp_master!).
              repositories_api.read(dest_repo.backend_service(SmartProxy.pulp_master).
              repository_reference.repository_href).latest_version_href

            unless new_version_href == dest_repo.version_href
              dest_repo.update(version_href: new_version_href)
              dest_repo.index_content
              output[:contents_changed] = true
              output[:updated_repositories] << dest_repo.id
            end
          end
        end
      end
    end
  end
end
