module Katello
  module Validators
    # Candidates describe distributions that will actually be written, not their source repositories.
    class DistributionPathValidator
      Candidate = Struct.new(:path, :repository, :reference_id, :namespace, keyword_init: true)
      Conflict = Struct.new(:candidate, :other, keyword_init: true)

      def self.overlap?(first, second)
        first = normalize(first)
        second = normalize(second)
        first == second || first.start_with?("#{second}/") || second.start_with?("#{first}/")
      end

      def self.normalize(path)
        raise ArgumentError, "Distribution path must be present" if path.blank? || path.delete('/').blank?
        path.sub(%r{\A/+}, '').sub(%r{/+\z}, '')
      end

      # A nil namespace is unknown, and therefore potentially overlaps every namespace.
      # References are unscoped: authorization controls presentation, not detection.
      def self.conflicts(candidates:, references: nil)
        candidates.each { |candidate| normalize(candidate.path) }
        references ||= Katello::Pulp3::DistributionReference.unscoped.includes(:repository).to_a
        current = references.map do |reference|
          Candidate.new(path: reference.path, repository: reference.repository, reference_id: reference.id)
        end
        conflicts = []
        candidates.each_with_index do |candidate, index|
          candidates.drop(index + 1).each do |other|
            conflicts << Conflict.new(candidate: candidate, other: other) if same_namespace?(candidate, other) && overlap?(candidate.path, other.path)
          end
          current.each do |other|
            next if candidate.reference_id.present? && candidate.reference_id == other.reference_id
            next unless same_namespace?(candidate, other) && overlap?(candidate.path, other.path)
            conflicts << Conflict.new(candidate: candidate, other: other)
          end
        end
        conflicts
      end

      def self.same_namespace?(first, second)
        first.namespace.nil? || second.namespace.nil? || first.namespace == second.namespace
      end

      # Explicit user and organization arguments prevent anonymous task contexts from inheriting admin visibility.
      def self.details_allowed?(repositories, organization:, user:)
        return false unless user && organization&.id && !user.hidden?
        return false if [::User::ANONYMOUS_ADMIN, ::User::ANONYMOUS_API_ADMIN, ::User::ANONYMOUS_CONSOLE_ADMIN].include?(user.login)
        return false if repositories.any? { |repo| !repo || !repo.persisted? || repo.organization_id != organization.id }
        ids = repositories.map(&:id).uniq
        Katello::Repository.readable_as(user).where(id: ids).distinct.count == ids.length
      end

      def self.messages(candidates:, organization:, user: nil, references: nil)
        conflicts(candidates: candidates, references: references).map do |conflict|
          first, second = conflict.candidate, conflict.other
          if details_allowed?([first.repository, second.repository], organization: organization, user: user)
            N_("Distribution path '%{path}' for repository '%{repository}' overlaps path '%{other_path}' for repository '%{other_repository}'. Change the lifecycle environment registry name pattern.") %
              {path: first.path, repository: first.repository.name, other_path: second.path, other_repository: second.repository.name}
          else
            N_("A distribution path overlaps an existing or proposed distribution. Change the lifecycle environment registry name pattern or contact an administrator.")
          end
        end.uniq
      end
    end
  end
end
