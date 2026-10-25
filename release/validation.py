"""Small dependency-free validator for the checked-in release JSON Schemas.

Only the documented keyword subset is accepted; unknown constraints fail closed.
This is not a general JSON Schema implementation.
"""
import json
import re


class ContractError(ValueError):
    """Public errors contain a stable code, never command output or credentials."""


def validate(value, schema, location='$'):
    supported = {'$schema', 'title', 'description', 'type', 'const', 'enum',
                 'properties', 'required', 'additionalProperties', 'items',
                 'uniqueItems', 'minItems', 'minLength', 'minimum', 'pattern'}
    if not isinstance(schema, dict) or set(schema) - supported:
        raise ContractError('schema_unsupported')
    kinds = {'object': lambda v: isinstance(v, dict),
             'array': lambda v: isinstance(v, list),
             'string': lambda v: isinstance(v, str),
             'integer': lambda v: type(v) is int,
             'boolean': lambda v: type(v) is bool,
             'null': lambda v: v is None}
    types = schema.get('type')
    if types is not None:
        types = types if isinstance(types, list) else [types]
        if any(t not in kinds for t in types) or not any(kinds[t](value) for t in types):
            raise ContractError('schema_type:' + location)
    # JSON booleans and numbers are not interchangeable.
    same = lambda a, b: json.dumps(a, sort_keys=True) == json.dumps(b, sort_keys=True)
    if 'const' in schema and not same(value, schema['const']):
        raise ContractError('schema_const:' + location)
    if 'enum' in schema and not any(same(value, item) for item in schema['enum']):
        raise ContractError('schema_enum:' + location)
    if isinstance(value, dict):
        if set(schema.get('required', [])) - set(value):
            raise ContractError('schema_required:' + location)
        properties = schema.get('properties', {})
        if schema.get('additionalProperties') is False and set(value) - set(properties):
            raise ContractError('schema_extra:' + location)
        for key, subschema in properties.items():
            if key in value:
                validate(value[key], subschema, location + '.' + key)
    if isinstance(value, list):
        if len(value) < schema.get('minItems', 0):
            raise ContractError('schema_min_items:' + location)
        if schema.get('uniqueItems'):
            keys = [json.dumps(item, sort_keys=True) for item in value]
            if len(keys) != len(set(keys)):
                raise ContractError('schema_duplicate:' + location)
        if 'items' in schema:
            for index, item in enumerate(value):
                validate(item, schema['items'], location + '[' + str(index) + ']')
    if isinstance(value, str):
        if len(value) < schema.get('minLength', 0):
            raise ContractError('schema_min_length:' + location)
        if 'pattern' in schema and re.search(schema['pattern'], value) is None:
            raise ContractError('schema_pattern:' + location)
    if type(value) is int and value < schema.get('minimum', value):
        raise ContractError('schema_minimum:' + location)
