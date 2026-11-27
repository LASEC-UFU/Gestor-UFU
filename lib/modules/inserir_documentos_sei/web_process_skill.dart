import 'package:gestor_ufu/platform/module/gestor_module.dart';

const webProcessSkill = ModuleSkill(
  title: 'Criar Ações na Web',
  summary:
      'Criar pela interface ou pela IA processos reutilizáveis com ações em componentes HTML e lotes JSON.',
  body: '''
## Processo configurável
Novo processo: nome, URL http/https, texto que confirma a conclusão (opcional),
intervalo entre registros e pasta de resultados. Cada etapa tem action,
selector (ID, #id ou CSS), value (texto ou {{campo}} do lote), nome e tempo limite.
A interface permite selecionar o componente no navegador e reordenar etapas.
O ID interno do módulo continua inserir-documentos-sei para preservar cadastros.

## Ações
fill: limpa e preenche; click: clica (value opcional filtra texto exato do botão);
select: escolhe opção por valor ou rótulo; check/uncheck: marca/desmarca;
wait: aguarda componente visível; waitText: aguarda texto em selector;
read: extrai texto no resultado; upload: anexa o arquivo de value;
navigate: abre URL em value; pause: espera os segundos de value (até 60).
transform: none, digits, trim, upper, lower. framePath é a sequência de índices
dos quadros internos, capturada automaticamente pela seleção visual.

## Pela IA
acoesWeb.listar retorna processos, etapas, registros e resultados.
acoesWeb.salvarProcesso recebe process:{name,url,steps,successText,...}; omitir id
cria um processo, informar id atualiza. steps pode ser uma sequência completa.
acoesWeb.adicionarEtapa, atualizarEtapa, reordenarEtapas (stepIds), removerEtapa
permitem montar a sequência aos poucos. Use processId de listar e os IDs das etapas.
acoesWeb.salvarRegistro recebe values e recordId opcional. importarDados lê uma
lista JSON de objetos; os campos são livres. exportarDados gera dados.json.
exportarProcesso/importarProcesso compartilham só configuração e etapas.
modeloPalmelo cria as sete etapas de preenchimento e o clique Enviar da rotina
de referência, sem incluir nomes, telefones, endereços nem outros dados reais.

## Execução
abrirSite abre navegador dedicado por processo; o usuário faz login nele.
selecionarElemento aguarda um clique no componente, sem realizar esse clique
no site (Esc cancela). executarProcesso exige confirmação e executa somente
registros pendentes, na ordem das etapas. recordIds restringe os registros.
Sem lote, há uma execução única. Sem successText, sucesso significa etapas
concluídas, sem afirmar que o site confirmou o cadastro.
parar interrompe após a etapa atual. Uma execução interrompida exige conferência.
Para repetir um registro, reabrirRegistro (com confirmação) o torna pendente.
Não repita automaticamente registros concluídos ou envios sem confirmação.
Os arquivos antes/depois/erro (.html/.png/.url), rede.json e resumo.json ficam
na pasta de saída da execução. A rede registra metadados, sem cookies/cabeçalhos.
As sessões de login ficam no perfil local do navegador, fora do banco e dos exports.

## Banco e erros
inserir_documentos_sei.projects.v1 guarda processos, etapas e lotes no banco.
Não colocar senhas ou cookies em valores fixos: o login é feito no navegador.
Erros: processo_nao_encontrado, sem_etapas, sem_pendentes, campo_ausente,
url_invalida, seletor_vazio, etapa_invalida, em_execucao, dados_invalidos,
elemento_ausente, opcao_ausente, quadro_ausente, cancelado.
''',
);
