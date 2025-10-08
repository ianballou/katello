module Katello
  class ErrataController < Katello::ApplicationController
    def auto_complete
      repo_prns = readable_repos(:pulp_prn)

      results = Errata.autocomplete_search("#{params[:term]}*", repo_prns)
      results = results.map { |erratum| {label: erratum.id_title, value: erratum.errata_id} }

      render :json => results
    end

    private

    def readable_repos(attribute)
      repos = []
      repos += Product.readable_repositories.pluck(attribute)
      repos += ContentView.readable_repositories.pluck(attribute)
      repos
    end
  end
end
