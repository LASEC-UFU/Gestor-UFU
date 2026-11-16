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

const _afterAction = {
  'type': 'boolean',
  'description': 'Devolver uma captura de tela após a ação (padrão true).',
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
    name: 'workflow_start',
    description:
        'Abre um fluxo de trabalho retomável do Agente UFU. Use em tarefas '
        'com várias etapas, automação de interface, falhas recuperáveis ou '
        'possível intervenção do usuário. O fluxo e os checkpoints ficam salvos.',
    mutates: true,
    schema: {
      'type': 'object',
      'properties': {
        'module': {'type': 'string'},
        'title': {'type': 'string'},
        'goal': {'type': 'string'},
        'steps': {
          'type': 'array',
          'items': {'type': 'string'},
        },
      },
      'required': ['module', 'title', 'goal'],
    },
  ),
  AgentToolSpec(
    name: 'workflow_checkpoint',
    description:
        'Salva o resultado de uma etapa: running, succeeded, failed ou '
        'waiting_user. Registre detalhes, evidência e erro após cada ação.',
    mutates: true,
    schema: {
      'type': 'object',
      'properties': {
        'workflow_id': {'type': 'string'},
        'step': {'type': 'string'},
        'status': {
          'type': 'string',
          'enum': ['running', 'succeeded', 'failed', 'waiting_user'],
        },
        'detail': {'type': 'string'},
        'evidence': {'type': 'string'},
        'error': {'type': 'string'},
      },
      'required': ['workflow_id', 'step', 'status'],
    },
  ),
  AgentToolSpec(
    name: 'workflow_request_user',
    description:
        'Registra uma pergunta ou ação manual necessária. Depois da chamada, '
        'faça a pergunta ao usuário na conversa e retome o fluxo quando ele responder.',
    mutates: true,
    schema: {
      'type': 'object',
      'properties': {
        'workflow_id': {'type': 'string'},
        'question': {'type': 'string'},
        'step': {'type': 'string'},
        'detail': {'type': 'string'},
      },
      'required': ['workflow_id', 'question'],
    },
  ),
  AgentToolSpec(
    name: 'workflow_get',
    description: 'Retoma um fluxo salvo e lê suas etapas e evidências.',
    schema: {
      'type': 'object',
      'properties': {
        'workflow_id': {'type': 'string'},
      },
      'required': ['workflow_id'],
    },
  ),
  AgentToolSpec(
    name: 'workflow_list',
    description:
        'Lista os fluxos recentes do Agente UFU, inclusive os pausados.',
    schema: {
      'type': 'object',
      'properties': {
        'limit': {'type': 'integer'},
      },
    },
  ),
  AgentToolSpec(
    name: 'workflow_finish',
    description:
        'Conclui o fluxo ou prepara o repasse para desenvolvimento e salva '
        'um relatório Markdown com todas as etapas e evidências.',
    mutates: true,
    schema: {
      'type': 'object',
      'properties': {
        'workflow_id': {'type': 'string'},
        'outcome': {
          'type': 'string',
          'enum': ['completed', 'handoff'],
        },
        'summary': {'type': 'string'},
      },
      'required': ['workflow_id', 'outcome', 'summary'],
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

  // ------------------------------------------------- comandos dos módulos
  AgentToolSpec(
    name: 'list_commands',
    description:
        'Lista os comandos dos módulos do Gestor — as mesmas ações dos botões '
        'das telas (importar, exportar, gerar PDF, abrir sistemas…), com a '
        'entrada esperada. module filtra por módulo.',
    schema: {
      'type': 'object',
      'properties': {
        'module': {'type': 'string'},
      },
    },
  ),
  AgentToolSpec(
    name: 'run_command',
    description:
        'Executa um comando de módulo (id de list_commands) com a entrada '
        'indicada. Prefira comandos a gravar direto no banco: eles aplicam as '
        'regras da tela. Comandos com requires_approval pedem confirmação ao '
        'usuário.',
    mutates: true,
    schema: {
      'type': 'object',
      'properties': {
        'command': {'type': 'string'},
        'input': {'type': 'object'},
      },
      'required': ['command'],
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
  // ------------------------------------------------ Arquivos (econômico)
  AgentToolSpec(
    name: 'read_spreadsheet',
    description:
        'Lê planilha .xlsx/.xlsm/.csv/.tsv gastando poucos tokens. Sem sheet: '
        'resumo (abas, tamanho, cabeçalho, primeiras linhas). Com sheet: só o '
        'trecho pedido (range "A1:F50" ou start_row/max_rows) em TSV. Prefira '
        'isto a abrir o Excel ou escrever scripts.',
    schema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'sheet': {'type': 'string'},
        'range': {'type': 'string'},
        'start_row': {'type': 'integer'},
        'max_rows': {'type': 'integer'},
        'preview_rows': {'type': 'integer'},
      },
      'required': ['path'],
    },
  ),
  AgentToolSpec(
    name: 'read_document',
    description:
        'Lê o texto de .docx (parágrafos e tabelas) ou de arquivos de texto, '
        'em fatias (offset/max_chars, padrão 8000).',
    schema: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'offset': {'type': 'integer'},
        'max_chars': {'type': 'integer'},
      },
      'required': ['path'],
    },
  ),
  // ------------------------------------------------ Controle do computador
  AgentToolSpec(
    name: 'computer_screenshot',
    description:
        'Captura a tela de um monitor (padrão: o da última captura, senão o '
        'principal) e devolve a imagem, a lista de monitores e a posição do '
        'mouse. As coordenadas x/y das ações computer_* são as da última '
        'captura. monitor: número (0 = principal) ou "todos".',
    schema: {
      'type': 'object',
      'properties': {
        'monitor': {
          'anyOf': [
            {'type': 'integer'},
            {
              'type': 'string',
              'enum': ['todos'],
            },
          ],
        },
      },
    },
  ),
  AgentToolSpec(
    name: 'computer_windows',
    description:
        'Lista as janelas abertas (título e retângulo em coordenadas da '
        'captura) e a janela ativa.',
    schema: {'type': 'object', 'properties': {}},
  ),
  AgentToolSpec(
    name: 'computer_cursor',
    description: 'Posição atual do mouse (coordenadas da captura).',
    schema: {'type': 'object', 'properties': {}},
  ),
  AgentToolSpec(
    name: 'computer_focus_window',
    description:
        'Traz para a frente a janela cujo título contém o texto informado.',
    schema: {
      'type': 'object',
      'properties': {
        'title': {'type': 'string'},
        'screenshot': _afterAction,
      },
      'required': ['title'],
    },
  ),
  AgentToolSpec(
    name: 'computer_click',
    description:
        'Move o mouse até (x, y) da captura e clica. button: left (padrão), '
        'right ou middle; clicks: 2 = clique duplo; modifiers: ex. "ctrl" ou '
        '"shift".',
    schema: {
      'type': 'object',
      'properties': {
        'x': {'type': 'number'},
        'y': {'type': 'number'},
        'button': {
          'type': 'string',
          'enum': ['left', 'right', 'middle'],
        },
        'clicks': {'type': 'integer'},
        'modifiers': {'type': 'string'},
        'screenshot': _afterAction,
      },
      'required': ['x', 'y'],
    },
  ),
  AgentToolSpec(
    name: 'computer_move',
    description: 'Move o mouse até (x, y) da captura (ex.: abrir um tooltip).',
    schema: {
      'type': 'object',
      'properties': {
        'x': {'type': 'number'},
        'y': {'type': 'number'},
        'screenshot': _afterAction,
      },
      'required': ['x', 'y'],
    },
  ),
  AgentToolSpec(
    name: 'computer_drag',
    description: 'Arrasta com o botão esquerdo de (x, y) até (to_x, to_y).',
    schema: {
      'type': 'object',
      'properties': {
        'x': {'type': 'number'},
        'y': {'type': 'number'},
        'to_x': {'type': 'number'},
        'to_y': {'type': 'number'},
        'screenshot': _afterAction,
      },
      'required': ['x', 'y', 'to_x', 'to_y'],
    },
  ),
  AgentToolSpec(
    name: 'computer_scroll',
    description:
        'Rola a roda do mouse em (x, y) (opcional): direction up/down/left/'
        'right, amount = número de "cliques" da roda (padrão 3).',
    schema: {
      'type': 'object',
      'properties': {
        'x': {'type': 'number'},
        'y': {'type': 'number'},
        'direction': {
          'type': 'string',
          'enum': ['up', 'down', 'left', 'right'],
        },
        'amount': {'type': 'integer'},
        'screenshot': _afterAction,
      },
      'required': ['direction'],
    },
  ),
  AgentToolSpec(
    name: 'computer_type',
    description:
        'Digita o texto no campo com foco (qualquer caractere; quebra de linha = Enter). '
        'Clique no campo antes.',
    schema: {
      'type': 'object',
      'properties': {
        'text': {'type': 'string'},
        'screenshot': _afterAction,
      },
      'required': ['text'],
    },
  ),
  AgentToolSpec(
    name: 'computer_key',
    description:
        'Pressiona teclas/atalhos: "enter", "tab", "esc", "ctrl+s", '
        '"alt+tab", "ctrl+shift+t", "f5"; vários separados por espaço.',
    schema: {
      'type': 'object',
      'properties': {
        'keys': {'type': 'string'},
        'screenshot': _afterAction,
      },
      'required': ['keys'],
    },
  ),
];

const agentToolChannelName = 'gestor_ufu_ai_agent_host';
