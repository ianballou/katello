module Actions
  module Pulp3
    module Repository
      class SaveArtifact < Pulp3::AbstractAsyncTask
        #This task creates a content unit and may or may not create a new repository version in the process
        def plan(file, repository, smart_proxy, tasks, unit_type_id, options = {})
          options[:file_name] = file[:filename]
          options[:sha256] = file[:sha256] || (Digest::SHA256.hexdigest(File.read(file[:path])) if file[:path].present?)
          plan_self(:repository_id => repository.id, :smart_proxy_id => smart_proxy.id, :tasks => tasks, :unit_type_id => unit_type_id, :options => options)
        end

        def invoke_external_task
          repository = ::Katello::Repository.find(input[:repository_id])
          artifact_prn = input[:options][:artifact_prn] || fetch_artifact_prn
          fail _("Content not uploaded to pulp") unless artifact_prn
          content_type = input[:unit_type_id]
          content_backend_service = SmartProxy.pulp_primary.content_service(content_type)

          if repository.deb?
            repo_prn = repository.backend_service(smart_proxy).repository_reference.repository_prn
            output[:pulp_tasks] = [content_backend_service.content_api_create(relative_path: input[:options][:file_name],
                                                                              repository: repo_prn,
                                                                              repository_id: repository.id,
                                                                              distribution: "katello",
                                                                              component: "upload",
                                                                              artifact: artifact_prn,
                                                                              content_type: content_type)]
          else
            existing_content = ::Katello::Pulp3::PulpContentUnit.find_duplicate_unit(repository, input[:unit_type_id], {filename: input[:options][:file_name]}, input[:options][:sha256])
            existing_content_prn = existing_content&.results&.first&.prn

            if ::Katello::RepositoryTypeManager.find_content_type(input[:unit_type_id]).repository_import_on_upload
              output[:pulp_tasks] = [repository.backend_service(smart_proxy).repository_import_content(artifact_prn, input[:options])]
            else
              if existing_content_prn
                output[:content_unit_prn] = existing_content_prn
                []
              else
                output[:pulp_tasks] = [content_backend_service.content_api_create(relative_path: input[:options][:file_name],
                                                                                  repository_id: repository.id,
                                                                                  artifact: artifact_prn,
                                                                                  content_type: content_type)]
              end
            end
          end
        end

        def fetch_artifact_prn
          sha_artifact_list = ::Katello::Pulp3::Api::Core.new(smart_proxy).artifacts_api.list("sha256": input[:options][:sha256])
          sha_artifact_list&.results&.first&.prn
        end
      end
    end
  end
end
