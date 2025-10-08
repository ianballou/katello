object @resource

attributes :id, :name, :version, :release, :arch, :epoch, :summary, :modular
attributes :filename, :sourcerpm, :checksum
attributes :nvrea, :nvra
attributes :pulp_prn => :pulp_id
attributes :pulp_prn => :uuid

node(:hosts_available_count) { |m| m.hosts_available(params[:organization_id]).count }
node(:hosts_applicable_count) { |m| m.hosts_applicable(params[:organization_id]).count }
