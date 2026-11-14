/// Definições das ferramentas que o Agente de IA pode chamar. São neutras
/// em relação ao provedor e convertidas para o formato de cada API (Claude,
/// OpenAI e MCP).
class AgentToolSpec {
  const AgentToolSpec({
    required this.name,
    required this.description,
    required this.schema,
    this.mutates = false,
  });

  final String name;
  final String description;
  final Map<String, dynamic> schema;
  final bool mutates;
}

const _path = {
  'type': 'array',
  'description':
      'Caminho dentro do JSON: lista de segmentos (texto para chaves de '
      'objeto, inteiro para índice de lista). Lista vazia = raiz.',
  'items': {
    'anyOf': [
      {'type': 'string'},
      {'type': 'integer'},
    ],
  },
};

const agentTools = <AgentToolSpec>[
  AgentToolSpec(
    name: 'get_app_context',
    description:
        'Retorna o período letivo ativo, a lista de períodos, o módulo aberto '
        'na janela principal e quantas alterações podem ser desfeitas.',
    schema: {'type': 'object', 'properties': {}},
  ),
  AgentToolSpec(
    name: 'list_modules',
    description: 'Lista as funcionalidades do Gestor UFU que possuem skill.',
    schema: {'type': 'object', 'properties': {}},
  ),
  AgentToolSpec(
    name: 'get_skill',
    description:
        'Retorna as instruções (skill) de uma funcionalidade: chaves do banco, '
        'formato dos dados e regras.',
    schema: {
      'type': 'object',
      'properties': {
        'module': {
          'type': 'string',
          'description': 'id do módulo, vindo de list_modules',
        },
      },
      'required': ['module'],
    },
  ),
  AgentToolSpec(
    name: 'list_keys',
    description:
        'Lista as chaves do banco com tipo e tamanho. Use prefix para filtrar.',
    schema: {
      'type': 'object',
      'properties': {
        'prefix': {'type': 'string', 'description': 'prefixo opcional'},
      },
    },
  ),
  AgentToolSpec(
    name: 'term_storage_key',
    description:
        'Calcula a chave de armazenamento de um módulo para um período letivo '
        '(prefixo + base64url do período, sem "=").',
    schema: {
      'type': 'object',
      'properties': {
        'prefix': {'type': 'string'},
        'term': {'type': 'string'},
      },
      'required': ['prefix', 'term'],
    },
  ),
  AgentToolSpec(
    name: 'read_key',
    description:
        'Lê o valor de uma chave (JSON decodificado quando possível). Use path '
        'para ler apenas um trecho e offset/limit para paginar textos grandes.',
    schema: {
      'type': 'object',
      'properties': {
        'key': {'type': 'string'},
        'path': _path,
        'offset': {'type': 'integer', 'description': 'caractere inicial'},
        'limit': {
          'type': 'integer',
          'description': 'máximo de caracteres (padrão 60000)',
        },
      },
      'required': ['key'],
    },
  ),
  AgentToolSpec(
    name: 'patch_json',
    description:
        'Aplica operações a um JSON armazenado em uma chave e grava o '
        'resultado. op: "set" (define valor no path), "merge" (mescla objeto), '
        '"append" (adiciona item a uma lista), "delete" (remove o path). '
        'Se a chave não existir, começa de {} (ou [] quando o primeiro '
        'segmento é inteiro).',
    mutates: true,
    schema: {
      'type': 'object',
      'properties': {
        'key': {'type': 'string'},
        'operations': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'op': {
                'type': 'string',
                'enum': ['set', 'merge', 'append', 'delete'],
              },
              'path': _path,
              'value': {'description': 'valor JSON (não usado em delete)'},
            },
            'required': ['op', 'path'],
          },
        },
      },
      'required': ['key', 'operations'],
    },
  ),
  AgentToolSpec(
    name: 'write_key',
    description:
        'Substitui o valor inteiro de uma chave. value_type "json" grava o '
        'value como texto JSON (padrão); "string", "string_list", "bool", '
        '"int" e "double" gravam o tipo nativo.',
    mutates: true,
    schema: {
      'type': 'object',
      'properties': {
        'key': {'type': 'string'},
        'value': {'description': 'novo valor'},
        'value_type': {
          'type': 'string',
          'enum': ['json', 'string', 'string_list', 'bool', 'int', 'double'],
        },
      },
      'required': ['key', 'value'],
    },
  ),
  AgentToolSpec(
    name: 'delete_key',
    description: 'Remove uma chave do banco.',
    mutates: true,
    schema: {
      'type': 'object',
      'properties': {
        'key': {'type': 'string'},
      },
      'required': ['key'],
    },
  ),
];

const agentToolChannelName = 'gestor_ufu_ai_agent_host';
