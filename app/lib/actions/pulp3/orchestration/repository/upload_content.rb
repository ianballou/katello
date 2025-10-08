module Actions
  module Pulp3
    module Orchestration
      module Repository
        class UploadContent < Pulp3::Abstract
          include Actions::Helpers::OutputPropagator
          def plan(repository, smart_proxy, file, unit_type_id)
            sequence do
              if repository.deb?
                upload_action_output = plan_action(Pulp3::Repository::UploadFile, repository, smart_proxy, file[:path]).output
                artifact_action_output = plan_action(Pulp3::Repository::SaveArtifact, file, repository, smart_proxy, upload_action_output[:pulp_tasks], unit_type_id).output
              else
                checksum = Digest::SHA256.hexdigest(File.read(file[:path]))
                duplicate_sha_path_content_list = ::Katello::Pulp3::PulpContentUnit.find_duplicate_unit(repository, unit_type_id, file, checksum)
                duplicate_content_prn = duplicate_sha_path_content_list&.results&.first&.prn

                unless duplicate_content_prn
                  duplicate_sha_artifact_list = ::Katello::Pulp3::Api::Core.new(smart_proxy).artifacts_api.list("sha256": Digest::SHA256.hexdigest(File.read(file[:path])))
                  duplicate_sha_artifact_prn = duplicate_sha_artifact_list&.results&.first&.prn
                  if duplicate_sha_artifact_prn
                    artifact_action_output = plan_action(Pulp3::Repository::SaveArtifact, file, repository, smart_proxy, nil, unit_type_id, artifact_prn: duplicate_sha_artifact_prn).output
                  else
                    upload_action_output = plan_action(Pulp3::Repository::UploadFile, repository, smart_proxy, file[:path]).output
                    artifact_action_output = plan_action(Pulp3::Repository::SaveArtifact, file, repository, smart_proxy, upload_action_output[:pulp_tasks], unit_type_id).output
                  end
                end
                artifact_action_output ||= {:content_unit_prn => duplicate_content_prn}
              end

              action_output = plan_action(Pulp3::Repository::ImportUpload, artifact_action_output, repository, smart_proxy).output
              plan_action(Pulp3::Repository::SaveVersion, repository, tasks: action_output[:pulp_tasks]).output
              plan_self(:subaction_output => action_output)
            end
          end
        end
      end
    end
  end
end
