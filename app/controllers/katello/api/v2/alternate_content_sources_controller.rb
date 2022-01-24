module Katello
  class Api::V2::AlternateContentSourcesController < Api::V2::ApiController
    include Katello::Concerns::FilteredAutoCompleteSearch

    before_action :find_authorized_katello_resource, :only => [:show, :update, :destroy]
    before_action :find_smart_proxies

    def_param_group :acs do
      param :name, String, desc: N_("Name of the alternate content source"), required: false
      param :description, String, desc: N_("Description for the alternate content source")
      param :base_url, String, desc: N_('Base URL for finding alternate content')
      param :subpaths, Array, desc: N_('Path suffixes for finding alternate content')
      param :smart_proxy_ids, Array, desc: N_("Ids of smart proxies to associate"), required: false
      param :content_type, RepositoryTypeManager.defined_repository_types.keys, desc: N_("The content type for the Alternate Content Source")
      param :alternate_content_source_type, AlternateContentSource::ALLOWED_TYPES, desc: N_("The Alternate Content Source type")
      param :upstream_username, String, desc: N_("Basic authentication username"), required: false
      param :upstream_password, String, desc: N_("Basic authentication password"), required: false
      param :ssl_ca_cert_id, :number, desc: N_("Identifier of the content credential containing the SSL CA Cert"), required: false
      param :ssl_client_cert_id, :number, desc: N_("Identifier of the content credential containing the SSL Client Cert"), required: false
      param :ssl_client_key_id, :number, desc: N_("Identifier of the content credential containing the SSL Client Key"), required: false
      param :http_proxy_id, :number, desc: N_("ID of a HTTP Proxy"), required: false
      param :verify_ssl, :bool, desc: N_("If SSL should be verified for the upstream URL"), required: false
    end

    api :GET, "/alternate_content_sources", N_("List of alternate_content_sources")
    param :label, String, desc: N_("Label of the alternate content source"), required: false
    param_group :search, Api::V2::ApiController
    add_scoped_search_description_for(AlternateContentSource)
    def index
      base_args = [index_relation.distinct, :name, :asc]

      respond_to do |format|
        format.csv do
          options[:csv] = true
          alternate_content_sources = scoped_search(*base_args)
          csv_response(alternate_content_sources,
                       [:id, :name, :description, :label, :base_url, :subpaths, :content_type, :alternate_content_source_type],
                       ['Id', 'Name', 'Description', 'label', 'Base URL', 'Subpaths', 'Content Type', 'Alternate Content Source Type'])
        end
        format.any do
          alternate_content_sources = scoped_search(*base_args)
          respond(collection: alternate_content_sources)
        end
      end
    end

    def index_relation
      query = AlternateContentSource.readable
      query = with_type(params[:content_type]) if params[:content_type]
      query = query.where(name: params[:name]) if params[:name]
      query = query.where(label: params[:label]) if params[:label]
      query = query.where(base_url: params(:base_url)) if params[:base_url]
      query = query.where(subpaths: params(:subpaths)) if params[:subpaths]
      query = query.where(alternate_content_source_type: params(:alternate_content_source_type)) if params[:alternate_content_source_type]
      query = query.joins('inner join katello_smart_proxy_alternate_content_sources on katello_smart_proxy_alternate_content_sources.alternate_content_source_id = katello_alternate_content_sources.id').joins('inner join smart_proxies on katello_smart_proxy_alternate_content_sources.smart_proxy_id = smart_proxies.id').where('smart_proxies.id' => params[:smart_proxy_ids]) if params[:smart_proxy_ids]
      query
    end

    api :GET, '/alternate_content_sources/:id', N_('Show an alternate content source')
    param :id, :number, :required => true, :desc => N_("Alternate content source ID")
    def show
      respond_for_show(:resource => @alternate_content_source)
    end

    api :POST, '/alternate_content_sources', N_('Create an ACS')
    param_group :acs
    def create
      @alternate_content_source = ::Katello::AlternateContentSource.new(acs_params)
      sync_task(::Actions::Katello::AlternateContentSource::Create, @alternate_content_source, @smart_proxies)
      respond_for_create(resource: @alternate_content_source.reload)
    end

    api :PUT, '/alternate_content_sources/:id', N_('Update an alternate content source')
    param_group :acs
    param :id, :number, :required => true, :desc => N_("Alternate content source ID")
    def update
      sync_task(::Actions::Katello::AlternateContentSource::Update, @alternate_content_source, @smart_proxies, acs_params)
      respond_for_show(:resource => @alternate_content_source)
    end

    api :DELETE, '/alternate_content_sources/:id', N_('Destroy an alternate content source')
    param :id, :number, :required => true, :desc => N_("Alternate content source ID")
    def destroy
      sync_task(::Actions::Katello::AlternateContentSource::Destroy, @alternate_content_source)
      respond_for_destroy
    end

    protected

    def acs_params
      keys = [:name, :label, :base_url, {subpaths: []}, {smart_proxy_ids: []}, :content_type, :alternate_content_source_type,
              :upstream_username, :upstream_password, :ssl_ca_cert_id, :ssl_client_cert_id, :ssl_client_key_id,
              :http_proxy_id, :verify_ssl]
      params.require(:alternate_content_source).permit(*keys).to_h.with_indifferent_access
    end

    def find_smart_proxies
      if params[:smart_proxy_ids]
        @smart_proxies = ::SmartProxy.where(id: params[:smart_proxy_ids])
        fail HttpErrors::NotFound, _("Couldn't find smart proxies with id '%s'") % params[:smart_proxy_ids].to_sentence if @smart_proxies.empty?
      end
    end
  end
end
