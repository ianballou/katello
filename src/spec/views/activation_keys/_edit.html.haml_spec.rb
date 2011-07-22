#
# Copyright 2011 Red Hat, Inc.
#
# This software is licensed to you under the GNU General Public
# License as published by the Free Software Foundation; either version
# 2 of the License (GPLv2) or (at your option) any later version.
# There is NO WARRANTY for this software, express or implied,
# including the implied warranties of MERCHANTABILITY,
# NON-INFRINGEMENT, or FITNESS FOR A PARTICULAR PURPOSE. You should
# have received a copy of GPLv2 along with this software; if not, see
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.txt.

require 'spec_helper'

describe "activation_keys/_edit.html.haml" do
  before(:each) do
    @organization = assign(:organization, stub_model(Organization,
      :name => "Test Org"))

    @key_name = "New Key"
    @key_description = "This is a new activation key"

    @activation_key = assign(:activation_key, stub_model(ActivationKey,
      :name => @key_name,
      :description => @key_description,
      :organization => @organization
    ))

    view.stub(:help_tip_button)
    view.stub(:help_tip)
    view.stub(:render_navigation)
  end

  it "renders the activation key name using inline edit" do
    view.stub_chain(:current_organization, :environments).and_return([])
    render
    assert_select "form" do
      assert_select ".editable#activation_key_name", {:count => 1}
    end
  end

  it "renders the activation key description using inline edit" do
    view.stub_chain(:current_organization, :environments).and_return([])
    render
    assert_select "form" do
      assert_select ".editable#activation_key_description", {:count => 1}
    end
  end

  it "renders sub-navigation links" do
    view.stub_chain(:current_organization, :environments).and_return([])
    view.should_receive(:render_navigation).with(:expand_all => true, :level => 3).once
    render
  end

  it "renders link to destroy activation key" do
    view.stub_chain(:current_organization, :environments).and_return([])
    render
    assert_select "a.remove_item[data-url=#{activation_key_path(@activation_key)}]", {:count => 1}
  end
end
