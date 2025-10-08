require "pulpcore_client"

module Katello
  module Pulp3
    module Api
      class Yum < Core
        def self.remote_uln_class
          PulpRpmClient::RpmUlnRemote
        end

        def self.rpm_package_group_class
          PulpRpmClient::RpmPackageGroup
        end

        def self.copy_class
          PulpRpmClient::Copy
        end

        def self.add_remove_content_class
          PulpRpmClient::RepositoryAddRemoveContent
        end

        def self.alternate_content_source_class
          PulpRpmClient::RpmRpmAlternateContentSource
        end

        def alternate_content_source_api
          PulpRpmClient::AcsRpmApi.new(api_client)
        end

        def remotes_uln_api
          PulpRpmClient::RemotesUlnApi.new(api_client)
        end

        def get_remotes_api(prn: nil, url: nil)
          fail 'Provide exactly one of prn or url for yum remote selection!' if url.blank? && prn.blank?
          fail 'The prn must be a pulp_rpm remote prn!' if prn && !prn.start_with?('prn:rpm.')

          # PRN format: prn:rpm.ulnremote:<uuid> for ULN remotes, prn:rpm.rpmremote:<uuid> for regular RPM remotes
          if prn&.start_with?('prn:rpm.ulnremote:') || url&.start_with?('uln')
            remotes_uln_api
          else
            remotes_api
          end
        end

        def copy_api
          PulpRpmClient::RpmCopyApi.new(api_client)
        end

        def content_package_groups_api
          PulpRpmClient::ContentPackagegroupsApi.new(api_client)
        end

        def content_package_environments_api
          PulpRpmClient::ContentPackageenvironmentsApi.new(api_client)
        end

        def content_modulemd_defaults_api
          PulpRpmClient::ContentModulemdDefaultsApi.new(api_client)
        end

        def content_repo_metadata_files_api
          PulpRpmClient::ContentRepoMetadataFilesApi.new(api_client)
        end

        def content_distribution_trees_api
          PulpRpmClient::ContentDistributionTreesApi.new(api_client)
        end
      end
    end
  end
end
