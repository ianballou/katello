module Katello
  module Validators
    class ContentViewDistributionPathValidator
      def self.candidates(version:, sources:, environments:, include_archive: false)
        view = version.content_view
        destinations = environments.to_a.uniq
        destinations << nil if include_archive

        sources.flat_map do |source|
          next [] unless source.docker?

          destinations.map do |environment|
            existing = environment && view.get_repo_clone(environment, source).first
            projected = Katello::Repository.new(root: source.root, library_instance: source.library_instance_or_self,
                                                environment: environment, content_view_version: version)
            path = Katello::Repository.safe_render_container_name(projected)
            unless path.present? && ContainerImageNameValidator.validate_name(path)
              fail Katello::HttpErrors::Conflict, N_("The generated container image name is invalid. Review the lifecycle environment registry name pattern, repository upstream image name, and labels used to generate the name, or contact an administrator.")
            end

            DistributionPathValidator::Candidate.new(
              path: path,
              repository: existing || source,
              reference_id: existing && Katello::Pulp3::DistributionReference.find_by(repository_id: existing.id)&.id
            )
          end
        end
      end

      def self.validate!(version:, sources:, environments:, include_archive: false, user:)
        proposed = candidates(version: version, sources: sources, environments: environments, include_archive: include_archive)
        return if proposed.empty?

        messages = DistributionPathValidator.messages(candidates: proposed, organization: version.content_view.organization, user: user)
        fail Katello::HttpErrors::Conflict, messages.join("  ") if messages.any?
      end
    end
  end
end
