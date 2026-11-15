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

  // ------------------------------------------------- modelos de importação
  AgentToolSpec(
    name: 'list_templates',
    description:
        'Lista os modelos de arquivo que as importações do Gestor aceitam '
        '(id e onde importar).',
    schema: {'type': 'object', 'properties': {}},
  ),
  AgentToolSpec(
    name: 'create_template',
    description:
        'Gera um arquivo-modelo (.xlsx/.json/.txt) no formato exato de uma '
        'importação do Gestor e devolve o caminho. Sem "rows"/"data" usa '
        'exemplos; com eles, gera o arquivo pronto para importar com os dados '
        'informados. Use para entregar modelos ao usuário ou para converter '
        'o que ele colou/anexou em um arquivo importável.',
    schema: {
      'type': 'object',
      'properties': {
        'template': {
          'type': 'string',
          'enum': [
            'moodle_planilha',
            'diario_planilha',
            'diario_json',
            'ajusta_horarios_bdados',
            'ajusta_horarios_banco',
            'equivalencia_curriculo',
            'equivalencia_analise',
            'plano_ensino_json',
            'plano_ensino_cronograma',
          ],
        },
        'rows': {
          'type': 'array',
          'description':
              'Linhas de dados (lista de listas, na ordem das colunas do '
              'modelo; veja a skill do módulo).',
          'items': {'type': 'array', 'items': {}},
        },
        'data': {
          'description':
              'Conteúdo JSON completo (diario_json: objeto; '
              'plano_ensino_json: lista de planos).',
        },
        'options': {
          'type': 'object',
          'description':
              'moodle_planilha: sheet_name, course_name, moodle_course_id, '
              'semester_start (AAAA-MM-DD), holidays [AAAA-MM-DD], day_swaps '
              '{"AAAA-MM-DD": diaDaSemana 1-7}. '
              'equivalencia_analise: student, student_id, blocks '
              '([[1,2],[5,7]] linhas de dados que formam um bloco).',
        },
        'folder': {
          'type': 'string',
          'description':
              'Pasta de destino (padrão: Documentos > GestorUFU Agente > modelos).',
        },
        'file_name': {'type': 'string'},
      },
      'required': ['template'],
    },
  ),

  // ---------------------------------------------------- navegador do agente
  AgentToolSpec(
    name: 'browser_open',
    description:
        'Abre o navegador do agente (Edge/Chrome visível, perfil próprio que '
        'lembra logins) ou traz para frente, opcionalmente indo para uma URL. '
        'O usuário pode usar o mesmo navegador ao mesmo tempo.',
    schema: {
      'type': 'object',
      'properties': {
        'url': {'type': 'string'},
        'headless': {
          'type': 'boolean',
          'description': 'true = sem janela (segundo plano).',
        },
      },
    },
  ),
  AgentToolSpec(
    name: 'browser_navigate',
    description: 'Navega na aba atual: goto (url), back, forward ou reload.',
    schema: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['goto', 'back', 'forward', 'reload'],
        },
        'url': {'type': 'string'},
      },
    },
  ),
  AgentToolSpec(
    name: 'browser_snapshot',
    description:
        'Lê a aba atual: URL, título, texto visível e a lista de elementos '
        'interativos, cada um com um "ref" numérico para usar em browser_act. '
        'Chame de novo após mudanças na página (os refs são renovados).',
    schema: {
      'type': 'object',
      'properties': {
        'max_text': {
          'type': 'integer',
          'description': 'Máximo de caracteres do texto (padrão 6000).',
        },
      },
    },
  ),
  AgentToolSpec(
    name: 'browser_act',
    description:
        'Age na aba atual. action: click (ref, selector ou text), type (ref '
        'ou selector + text; clear=false para não apagar; submit=true tecla '
        'Enter), press (key: Enter, Tab, Escape, ArrowDown…), select (value '
        'da opção), check (value true/false), hover, scroll (dy ou ref), wait '
        '(selector, text ou ms) e upload (path de arquivo).',
    schema: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': [
            'click',
            'type',
            'press',
            'select',
            'check',
            'hover',
            'scroll',
            'wait',
            'upload',
          ],
        },
        'ref': {'type': 'integer'},
        'selector': {'type': 'string'},
        'text': {'type': 'string'},
        'key': {'type': 'string'},
        'value': {},
        'clear': {'type': 'boolean'},
        'submit': {'type': 'boolean'},
        'dy': {'type': 'integer'},
        'ms': {'type': 'integer'},
        'timeout_ms': {'type': 'integer'},
        'path': {'type': 'string'},
      },
      'required': ['action'],
    },
  ),
  AgentToolSpec(
    name: 'browser_eval',
    description:
        'Executa JavaScript na aba atual e devolve o resultado (JSON). Aceita '
        'uma expressão ou um corpo de função com return.',
    schema: {
      'type': 'object',
      'properties': {
        'script': {'type': 'string'},
      },
      'required': ['script'],
    },
  ),
  AgentToolSpec(
    name: 'browser_screenshot',
    description: 'Captura de tela da aba atual (imagem).',
    schema: {
      'type': 'object',
      'properties': {
        'full_page': {'type': 'boolean'},
      },
    },
  ),
  AgentToolSpec(
    name: 'browser_tabs',
    description: 'Abas: list, new (url opcional), select (index) ou close.',
    schema: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['list', 'new', 'select', 'close'],
        },
        'index': {'type': 'integer'},
        'url': {'type': 'string'},
      },
    },
  ),
  AgentToolSpec(
    name: 'browser_record',
    description:
        'Grava as ações feitas no navegador do agente (cliques, campos, '
        'teclas, navegação), inclusive as do usuário. action: start, stop '
        '(devolve os eventos) ou status.',
    schema: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['start', 'stop', 'status'],
        },
      },
      'required': ['action'],
    },
  ),
  AgentToolSpec(
    name: 'browser_logs',
    description:
        'Erros e falhas observados desde a abertura: console (error/warning), '
        'exceções da página, requisições que falharam, respostas HTTP >= 400 '
        'e diálogos. kinds filtra pelo início do tipo (ex.: ["console", '
        '"http_5"]); clear=true limpa depois de ler.',
    schema: {
      'type': 'object',
      'properties': {
        'kinds': {
          'type': 'array',
          'items': {'type': 'string'},
        },
        'limit': {'type': 'integer'},
        'clear': {'type': 'boolean'},
      },
    },
  ),
  AgentToolSpec(
    name: 'browser_status',
    description: 'Diz se o navegador está aberto, a aba atual e se grava.',
    schema: {'type': 'object', 'properties': {}},
  ),
  AgentToolSpec(
    name: 'browser_close',
    description: 'Fecha o navegador do agente.',
    schema: {'type': 'object', 'properties': {}},
  ),
];

const agentToolChannelName = 'gestor_ufu_ai_agent_host';
