import React, { useContext } from 'react';
import { translate as __ } from 'foremanReact/common/I18n';
import {
  Button,
  Form,
  FormGroup,
  Popover,
  PopoverPosition,
  Text,
  TextInput,
  TextArea,
  Switch,
} from '@patternfly/react-core';
import { OutlinedQuestionCircleIcon } from '@patternfly/react-icons';
import ACSCreateContext from '../ACSCreateContext';
import WizardHeader from '../../../ContentViews/components/WizardHeader';

const AcsUrlPaths = () => {
  const {
    url, setUrl, subpaths, setSubpaths, verifySSL, setVerifySSL,
  } = useContext(ACSCreateContext);

  return (
    <>
      <WizardHeader
        title={__('URL and paths')}
        description={__('Enter in the base path and any subpaths that should be searched for alternate content. ' +
          'The base path can be a web address or a filesystem location.')}
      />
      <Form>
        <FormGroup
          label={__('Base URL')}
          type="string"
          fieldId="acs_base_url"
          isRequired
        >
          <TextInput
            isRequired
            type="text"
            id="acs_base_url_field"
            name="acs_base_url_field"
            aria-label="acs_base_url_field"
            placeholder="https:// or file://"
            value={url}
            onChange={(value) => { setUrl(value); }}
          />
          <Popover
            appendTo={() => document.body}
            aria-label="selectSource-rhui-tip-popover"
            position={PopoverPosition.top}
            bodyContent={
              <>
                {__('For RHUI, enter the base location for Pulp content, e.g., https://rhui.example.com/pulp/content/')}
              </>
        }
          >
            <Button ouiaId="source-type-rhui-info" style={{ padding: '8px' }} variant="plain" aria-label="popoverButton">
              <OutlinedQuestionCircleIcon />
              <Text>RHUI tip</Text>
            </Button>
          </Popover>
        </FormGroup>
        <FormGroup
          label={__('Subpaths')}
          type="string"
          fieldId="acs_subpaths"
        >
          <TextArea
            placeholder="test/repo1/, test/repo2/,"
            value={subpaths}
            onChange={(value) => { setSubpaths(value); }}
            name="acs_subpath_field"
            id="acs_subpath_field"
            aria-label="acs_subpath_field"
          />
          <Popover
            appendTo={() => document.body}
            aria-label="selectSource-rhui-tip-popover"
            position={PopoverPosition.top}
            bodyContent={
              <>
                {__('For RHUI, enter the relative paths for each repository passed into the \'rhui-manager client cert\' command. A repository\'s path can be found with \'rhui-manager repo info --repo_id <repo ID>\'.')}
              </>
        }
          >
            <Button ouiaId="source-type-rhui-info" style={{ padding: '8px' }} variant="plain" aria-label="popoverButton">
              <OutlinedQuestionCircleIcon />
              <Text>RHUI tip</Text>
            </Button>
          </Popover>
        </FormGroup>
        <FormGroup label={__('Verify SSL')} fieldId="verify_ssl">
          <Switch
            id="verify-ssl-switch"
            aria-label="verify-ssl-switch"
            isChecked={verifySSL}
            onChange={checked => setVerifySSL(checked)}
          />
        </FormGroup>
      </Form>
    </>
  );
};

export default AcsUrlPaths;
