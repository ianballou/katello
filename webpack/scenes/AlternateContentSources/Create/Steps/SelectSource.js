import React, { useContext } from 'react';
import { translate as __ } from 'foremanReact/common/I18n';
import { Button, Flex, FlexItem, Form, FormGroup, FormSelect, FormSelectOption, Popover, PopoverPosition, Text, Tile } from '@patternfly/react-core';
import { OutlinedQuestionCircleIcon } from '@patternfly/react-icons';
import ACSCreateContext from '../ACSCreateContext';
import WizardHeader from '../../../ContentViews/components/WizardHeader';

const SelectSource = () => {
  const {
    acsType, setAcsType, contentType, setContentType,
  } = useContext(ACSCreateContext);

  const onSelect = (event) => {
    setAcsType(event.currentTarget.id);
  };
  const onKeyDown = (event) => {
    if (event.key === ' ' || event.key === 'Enter') {
      event.preventDefault();
      setAcsType(event.currentTarget.id);
    }
  };

  const typeOptions = [
    { value: 'yum', label: __('Yum') },
    { value: 'file', label: __('File') },
  ];

  return (
    <>
      <WizardHeader
        title={__('Select source type')}
        description={__('Indicate the source type.')}
      />
      <Popover
        appendTo={() => document.body}
        aria-label="selectSource-rhui-tip-popover"
        position={PopoverPosition.top}
        bodyContent={
          <>
            {__('Select the Custom alternate content source type for RHUI.')}
          </>
        }
      >
        <Button ouiaId="source-type-rhui-info" style={{ padding: '8px' }} variant="plain" aria-label="popoverButton">
          <OutlinedQuestionCircleIcon />
          <Text>RHUI tip</Text>
        </Button>
      </Popover>
      <Form>
        <FormGroup
          label={__('Source type')}
          type="string"
          fieldId="source_type"
          isRequired
        >
          <Flex>
            <FlexItem>
              <Tile
                title={__('Custom')}
                isStacked
                id="custom"
                onClick={onSelect}
                onKeyDown={onKeyDown}
                isSelected={acsType === 'custom'}
              />{' '}
            </FlexItem>
            <FlexItem>
              <Tile
                title={__('Simplified')}
                isStacked
                id="simplified"
                onClick={onSelect}
                onKeyDown={onKeyDown}
                isSelected={acsType === 'simplified'}
              />{' '}
            </FlexItem>
          </Flex>
        </FormGroup>
        <FormGroup
          label={__('Content type')}
          type="string"
          fieldId="content_type"
          isRequired
        >
          <FormSelect
            isRequired
            value={contentType}
            onChange={(value) => {
              setContentType(value);
            }}
            aria-label="FormSelect Input"
          >
            {
                            typeOptions.map(option => (
                              <FormSelectOption
                                key={option.value}
                                value={option.value}
                                label={option.label}
                              />
                            ))
                        }
          </FormSelect>
        </FormGroup>
      </Form>
    </>
  );
};

export default SelectSource;
