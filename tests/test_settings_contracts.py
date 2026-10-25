import copy
import unittest

from scripts.release_contracts import ContractError, SchemaDefinitionError, _validate, validate_contract


class SettingsContractTests(unittest.TestCase):
    def setUp(self):
        self.profile = { 'household_name': '', 'members': []}
        self.policies = { 'accounts': [], 'aliases': [], 'routes': [],
                         'source_owners': {},
                         'unknown_account_policy': {'mode': 'needs_review', 'exclusion_member_ids': []}}

    def test_new_household_has_no_personal_defaults(self):
        self.assertIs(validate_contract('family-profile', self.profile), self.profile)
        self.assertIs(validate_contract('account-policies', self.policies), self.policies)

    def test_opaque_member_identity_and_unicode_display_supported(self):
        self.profile['members'] = [{'id': 'mock-member-旧身份', 'display_name': '合成成员', 'status': 'active'}]
        validate_contract('family-profile', self.profile)

    def test_profile_control_keys_are_not_silently_ignored(self):
        self.profile['default_owner'] = 'mock-member'
        with self.assertRaises(ContractError):
            validate_contract('family-profile', self.profile)

    def test_explicit_channel_alias_and_unknown_owner_allowed(self):
        self.policies['accounts'] = [{'id': 'mock-account', 'display_name': 'Mock account',
                                     'owner_member_id': None, 'currency': 'CNY', 'status': 'active'}]
        self.policies['aliases'] = [
            {'id': 'mock-channel', 'source_selector': {'platform': 'mock', 'payment_channel': 'Mock channel'},
             'target_account_id': None, 'confirmed': True, 'basis': 'mock-channel-evidence'},
            {'id': 'mock-alias', 'source_selector': {'platform': 'mock', 'source_account_name': 'Mock account alias'},
             'target_account_id': 'mock-account', 'confirmed': True, 'basis': 'mock-account-evidence'}]
        validate_contract('account-policies', self.policies)

    def test_route_needs_explicit_selector_target_and_basis(self):
        route = {'id': 'mock-route', 'source_selector': {'platform': 'mock-platform', 'source_account_name': 'Mock card'},
                 'target_account_id': 'mock-account', 'confirmed': True, 'basis': 'mock-evidence'}
        self.policies['routes'] = [route]
        validate_contract('account-policies', self.policies)
        for key in ('source_selector', 'target_account_id', 'basis'):
            invalid = copy.deepcopy(self.policies)
            invalid['routes'][0].pop(key)
            with self.assertRaises(ContractError):
                validate_contract('account-policies', invalid)

    def test_empty_selector_labels_and_implicit_unknown_owner_modes_rejected(self):
        self.policies['aliases'] = [
            {'id': 'alias', 'source_selector': {'platform': 'mock', 'source_account_name': ''},
             'target_account_id': None, 'confirmed': True, 'basis': 'mock-evidence'}]
        with self.assertRaises(ContractError):
            validate_contract('account-policies', self.policies)
        self.policies['aliases'] = []
        self.policies['unknown_account_policy']['mode'] = 'assign_current_operator'
        with self.assertRaises(ContractError):
            validate_contract('account-policies', self.policies)

    def test_scoped_same_name_accounts_and_multiple_funding_accounts_expressible(self):
        for index, (platform, name, target) in enumerate([
                ('mock-platform-a', 'Mock card', 'account-a'),
                ('mock-platform-b', 'Mock card', 'account-b'),
                ('mock-platform-a', 'Mock balance', 'account-balance')]):
            self.policies['routes'].append({
                'id': f'route-{index}', 'source_selector': {'platform': platform,
                    'source_id': 'mock-source', 'source_account_name': name},
                'target_account_id': target, 'confirmed': True, 'basis': 'mock-explicit-evidence'})
        validate_contract('account-policies', self.policies)
        self.assertEqual(len({tuple(sorted(r['source_selector'].items())) for r in self.policies['routes']}), 3)
        for field in ('source_account_id', 'payment_channel'):
            changed = copy.deepcopy(self.policies)
            changed['routes'][0]['source_selector'] = {'platform': 'mock-platform-a', field: 'mock-value'}
            validate_contract('account-policies', changed)

    def test_source_scope_alone_cannot_route_all_funding_accounts(self):
        for selector in ({'platform': 'mock'}, {'platform': 'mock', 'source_id': 'mock-source'}):
            self.policies['routes'] = [{'id': 'route', 'source_selector': selector,
                'target_account_id': 'account-a', 'confirmed': True, 'basis': 'mock-evidence'}]
            with self.assertRaises(ContractError):
                validate_contract('account-policies', self.policies)

    def test_schema_resource_limits_enforced(self):
        self.profile['household_name'] = 'a' * 257
        with self.assertRaises(ContractError):
            validate_contract('family-profile', self.profile)
        for schema, value in [({'type': 'array', 'maxItems': 1}, [1, 2]),
                              ({'type': 'object', 'maxProperties': 1}, {'a': 1, 'b': 2}),
                              ({'type': 'string', 'maxLength': 1}, 'ab')]:
            with self.assertRaises(ContractError):
                _validate(schema, value, '$', 'test.schema.json')

    def test_unknown_schema_constraints_still_fail_closed(self):
        unknown = {'unrecognizedConstraint': True}
        cases = [
            (unknown, {}),
            ({'type': 'object', 'propertyNames': unknown}, {}),
            ({'type': 'object', 'properties': {'absent': unknown}}, {}),
            ({'type': 'array', 'items': unknown}, []),
            ({'type': 'object', 'additionalProperties': unknown}, {}),
            ({'anyOf': [{'const': 1}, unknown]}, 1),
            ({'$defs': {'unused': unknown}}, {}),
            ({'anyOf': [{'const': 1}, {'$ref': 'other.schema.json'}]}, 1),
        ]
        for schema, value in cases:
            with self.subTest(schema=schema):
                with self.assertRaises(SchemaDefinitionError):
                    _validate(schema, value, '$', 'test.schema.json', schema_loader=lambda _: unknown)

    def test_schema_ref_cycles_and_graph_resource_limits_fail_closed(self):
        schemas = {'one.schema.json': {'$ref': 'two.schema.json'},
                   'two.schema.json': {'$ref': 'one.schema.json'}}
        with self.assertRaises(SchemaDefinitionError):
            _validate(schemas['one.schema.json'], {}, '$', 'one.schema.json', schemas.__getitem__)
        nested = {}
        for _ in range(66):
            nested = {'properties': {'unused': nested}}
        with self.assertRaises(SchemaDefinitionError):
            _validate(nested, {}, '$', 'test.schema.json')
        with self.assertRaises(SchemaDefinitionError):
            _validate({'$defs': {str(i): {} for i in range(10001)}}, {}, '$', 'test.schema.json')

    def test_schema_pointer_empty_tokens_not_normalized_to_another_target(self):
        schemas = {'other.schema.json': {'$defs': {'x': {'type': 'string'}}}}
        for pointer in ('/$defs/x/', '//$defs/x'):
            with self.subTest(pointer=pointer), self.assertRaises(SchemaDefinitionError):
                _validate({'$ref': 'other.schema.json#' + pointer}, 'mock', '$',
                          'test.schema.json', schemas.__getitem__)

    def test_schema_pointer_escaped_and_empty_definition_names_are_exact(self):
        schemas = {'other.schema.json': {'$defs': {
            '': {'type': 'string'}, 'a/b~c': {'const': 'exact'},
            'bad~escape': {'type': 'string'}}}}
        _validate({'$ref': 'other.schema.json#/$defs/'}, 'mock', '$',
                  'test.schema.json', schemas.__getitem__)
        _validate({'$ref': 'other.schema.json#/$defs/a~1b~0c'}, 'exact', '$',
                  'test.schema.json', schemas.__getitem__)
        with self.assertRaises(ContractError):
            _validate({'$ref': 'other.schema.json#/$defs/a~1b~0c'}, 'different', '$',
                      'test.schema.json', schemas.__getitem__)
        with self.assertRaises(SchemaDefinitionError):
            _validate({'$ref': 'other.schema.json#/$defs/bad~escape'}, 'mock', '$',
                      'test.schema.json', schemas.__getitem__)

    def test_missing_and_escaped_refs_in_unused_branches_are_rejected(self):
        for reference in ('../outside.schema.json', 'missing.schema.json', '#/$defs/missing'):
            with self.subTest(reference=reference), self.assertRaises(SchemaDefinitionError):
                _validate({'anyOf': [{'const': 1}, {'$ref': reference}]}, 1, '$',
                          'test.schema.json', schema_loader={'test.schema.json': {}}.__getitem__)


if __name__ == '__main__':
    unittest.main()
