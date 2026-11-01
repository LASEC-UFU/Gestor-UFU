# Pendências futuras: incorporar o PreencheDiario-UFU

Objetivo: transformar o Gestor UFU em um aplicativo Flutter para Windows que reúna todas as funções do projeto `C:\SourceCode\PreencheDiario-UFU`, mantendo resultados e dados existentes. O módulo de gestão do Moodle será uma das opções da tela inicial.

## 1. Aplicativo integrado e navegação

- [ ] Criar uma tela inicial para escolher entre Moodle, Diário, Extrair Árvore de Processo, Fichas, Planos de Ensino e Planos de Trabalho.
- [ ] Aplicar aos novos módulos o padrão visual do Gestor UFU, com interface de desktop mais clara, consistente e refinada que a interface Tkinter atual.
- [ ] Criar navegação, estados de carregamento, mensagens de erro/sucesso e área de logs apropriados para cada módulo.
- [ ] Manter as funcionalidades atuais de gestão do Moodle acessíveis como módulo integrado.
- [ ] Usar `SharedPreferences` como armazenamento local unificado para os dados de todos os módulos, incluindo Moodle, Diário, SEI, Planos de Ensino e Planos de Trabalho.
- [x] Manter histórico imutável e backups nomeados das configurações Moodle no mesmo SharedPreferences, preservando versões anteriores à edição ou exclusão e permitindo restaurá-las ou usá-las no Preenche Diários.
- [x] Manter hist?rico imut?vel e backups nomeados das configura??es Moodle no mesmo SharedPreferences, preservando vers?es anteriores ? edi??o ou exclus?o e permitindo restaur?-las ou us?-las no Preenche Di?rios.
- [ ] Compartilhar os dados do módulo Moodle com os Planos de Ensino, sem duplicar o cadastro da disciplina; o plano deve poder referenciar a configuração Moodle correspondente no armazenamento unificado.
- [ ] Organizar os dados por chaves/estruturas versionadas dentro do armazenamento compartilhado, sem criar bancos SQLite independentes por módulo.
- [ ] Migrar para `SharedPreferences` as configurações atuais de Moodle e os cadastros, preferências e dados que hoje ficam nos bancos SQLite do PreencheDiario-UFU.
- [ ] Manter importação e exportação de JSON, Excel, Word, HTML e PDF como formatos de intercâmbio/saída; os registros de trabalho do aplicativo devem ter uma única fonte de persistência.
- [ ] Guardar no armazenamento unificado os dados estruturados e os caminhos/metadados de arquivos; manter documentos importados e gerados como arquivos no disco, sem embutir arquivos grandes nas preferências.

## 2. Diário

### Dados e edição

- [x] Carregar dados de arquivos JSON no formato `{ "DD/MM/AAAA -P": "conteúdo da aula" }`.
- [x] Normalizar datas, espaços e variações de traço das chaves e ordenar os itens por data.
- [x] Exibir os lançamentos em lista/tabela e permitir inserir, editar e remover itens.
- [x] Salvar os dados novamente em JSON, permitindo escolher o destino.
- [x] Importar planilhas Excel, localizar e mapear cabeçalhos mesmo quando não estiverem na primeira linha, interpretar datas e modalidades e validar valores.
- [x] Ajustar datas por dias, meses ou anos, com filtros por modalidade; preservar corretamente o último dia do mês e anos bissextos.
- [x] Mostrar prévia ou resultado do ajuste antes de gravar alterações nos dados.

- [x] Permitir escolher uma configuração do Gestão do Moodle e importar suas seções, datas, modalidades e atividades para os lançamentos do Diário, mesclando ou substituindo com revisão pela lista editável.

### Preenchimento no portal

- [x] Abrir o Edge visível para que a pessoa faça login manualmente e navegue até a turma e o diário desejados.
- [x] Localizar no DOM o campo de texto associado a cada rótulo/data e preencher os lançamentos, sem usar fallback global que possa atingir campo errado.
- [x] Permitir destacar visualmente os campos preenchidos e, quando solicitado, não sobrescrever campos que já tenham conteúdo.
- [x] Registrar por item o que foi preenchido, ignorado ou não localizado.
- [x] Tentar acionar Salvar/Gravar e informar se o controle foi encontrado; confirmar o resultado quando a página oferecer indicação verificável.
- [x] Migrar a automação do Diário de Selenium/Python para Puppeteer em Dart, mantendo o Edge visível, o login manual, a localização contextual dos campos e o registro do resultado.
- [ ] Preferir seletores estáveis, verificar a tela e o resultado a cada etapa, aguardar carregamentos e interromper com erro claro quando o estado não for confiável.
- [ ] Validar o preenchimento, o comportamento de salvamento e os indicadores de confirmação no portal real após login manual.

## 3. SEI: fichas de componentes curriculares

- [ ] Configurar e editar o endereço do SEI, abrir o Edge e permitir autenticação manual.
- [ ] Selecionar uma pasta de fichas HTML e processar os arquivos do nível selecionado, sem incluir subpastas.
- [ ] Ler código e nome da ficha do HTML, usando o nome do arquivo como alternativa quando necessário; ordenar arquivos naturalmente e normalizar códigos.
- [ ] Exibir no log os códigos e nomes reconhecidos e os problemas de leitura antes de iniciar o envio.
- [ ] Confirmar o processo SEI correto antes de inserir documentos.
- [ ] Percorrer todas as pastas da árvore do processo antes de pesquisar documentos existentes.
- [ ] Procurar fichas existentes pelo código, ignorar documentos cancelados e comparar o HTML normalizado das versões.
- [ ] Não inserir uma ficha quando uma versão idêntica já existir; criar nova versão quando houver diferenças e nenhuma versão idêntica.
- [ ] Quando necessário, incluir documento do tipo Ficha de Componente Curricular, preenchendo descrição, número, nome na árvore e nível público.
- [ ] Limitar o nome na árvore a 50 caracteres sem cortar palavras quando possível.
- [ ] Substituir o conteúdo do editor do SEI pelo HTML da ficha e salvar.
- [ ] Fazer verificação final dos códigos no processo e informar resultados por ficha.
- [ ] Validar cada etapa da automação e parar com segurança se o processo, documento ou editor esperado não for encontrado.

## 4. SEI: inventário da árvore do processo

- [ ] Percorrer as pastas e documentos do processo aberto no SEI.
- [ ] Abrir documentos e extrair do conteúdo visível tipo/número, código verificador SEI, data e primeiro parágrafo substancial como resumo.
- [ ] Manter os campos heurísticos identificados como sujeitos a revisão pela pessoa usuária.
- [ ] Formatar o inventário numerado no estilo de relatório usado pelo projeto atual.
- [ ] Permitir escolher onde salvar o resultado em arquivo `.txt` e informar documentos com dados incompletos.

## 5. Planos de Ensino

### Cadastro e edição

- [ ] Criar, listar, selecionar, editar e remover planos de ensino.
- [ ] Organizar o formulário em seções/abas para identificação, natureza, ementa, justificativa, objetivos, programa, metodologia, cronogramas, avaliação, atendimento/recuperação e bibliografias.
- [ ] Preservar os campos estruturados atuais, incluindo código, componente curricular, carga horária, créditos, pré-requisitos, objetivos, referências e dados de avaliação.
- [ ] Permitir vincular um Plano de Ensino à disciplina/configuração correspondente já cadastrada no módulo Moodle e reutilizar seus dados de identificação disponíveis.
- [ ] Importar para o Plano de Ensino o cronograma da configuração selecionada no módulo Moodle; essa será a forma integrada de carregar o cronograma, substituindo o fluxo de colar tabela.
- [ ] Na importação, mapear as datas, modalidades, seções/atividades e descrições Moodle para as linhas do cronograma teórico ou prático e seus campos correspondentes.
- [ ] Mostrar prévia do cronograma encontrado e permitir revisar o mapeamento antes de aplicar; informar quando não houver dados suficientes ou modalidade identificável.
- [ ] Atualizar o campo de avaliação e o calendário de provas a partir das descrições importadas quando aplicável.
- [ ] Permitir revisar e editar as linhas importadas no Plano de Ensino sem alterar a configuração original do Moodle.
- [ ] Identificar pendências de dados práticos e apresentar validações compreensíveis.
- [ ] Armazenar os registros no `SharedPreferences` unificado do aplicativo; não manter um SQLite separado para Planos de Ensino.
- [ ] Migrar com segurança os registros do banco existente em `%LOCALAPPDATA%\PreencheDiarioUFU`, preservando IDs/relações quando possível e sem descartar dados quando um DOCX de origem não estiver disponível.
- [ ] Preservar os dados legados de planos e os backups já existentes durante a migração.

### Importação e exportação de documentos

- [ ] Importar DOCX e extrair os campos estruturados do plano, tabelas de identificação e cronogramas.
- [ ] Gerar DOCX editável com as seções do modelo, identificação, conteúdo, cronogramas teórico/prático e referências.
- [ ] Preservar campos vazios e não gerar tabelas de cronograma vazias.
- [ ] Comparar visualmente os DOCX gerados com o modelo de referência para conferir paginação, tabelas, estilos e quebras.

### Inserção no SEI

- [ ] Inserir o plano no processo SEI aberto, selecionando Plano de Ensino e preenchendo os campos do modelo básico.
- [ ] Substituir as referências antigas pelos dados cadastrados, construir objetivos/programa/metodologia/avaliação e inserir tabelas dos cronogramas ao final da Metodologia, antes de Avaliação.
- [ ] Manter Aprovação em branco e deixar a assinatura para o fluxo manual atual.
- [ ] Validar que o modelo e as seções esperadas foram localizados antes de alterar o editor; não gravar conteúdo genérico se o modelo estiver incompatível.
- [ ] Confirmar e registrar o resultado da inserção.

## 6. Planos de Trabalho

### Cadastro e dados

- [ ] Criar, listar, editar e remover planos de trabalho com nome, número/nome na árvore, interessado e PDF opcional associado.
- [ ] Guardar no `SharedPreferences` unificado as preferências e os dados de planilha cadastrados por plano.
- [ ] Importar dados de uma planilha preenchida e permitir editar valores, mostrar campos vazios e atualizar os campos reconhecidos em um novo modelo sem apagar valores já salvos.

### Preenchimento de Excel

- [ ] Ler os campos do modelo por abas/células e seus tipos, validar listas suspensas, números e datas e identificar campos incompatíveis antes de gravar.
- [ ] Mostrar prévia das operações, diferenças em relação ao destino e dados existentes que serão mantidos.
- [ ] Criar uma cópia da planilha com outro nome; preservar ano/semestre e valores existentes quando os campos cadastrados estiverem vazios.
- [ ] Recalcular fórmulas e conferir erros calculados sem executar macros nem atualizar vínculos externos.
- [ ] Preservar a abertura em instância isolada do Excel e o tratamento seguro de processos auxiliares, atualmente implementados via COM/pywin32.
- [ ] Definir e validar a integração Windows necessária para manter a automação COM do Excel a partir do aplicativo Flutter.
- [ ] Informar que o Microsoft Excel é requisito para o fluxo que depende do recálculo real; não declarar preenchimento concluído sem salvar e conferir a cópia.

### Inserção do PDF no SEI

- [ ] Permitir selecionar o PDF associado ou escolher outro para a operação.
- [ ] Exibir prévia dos metadados: tipo Plano, formato nato-digital, acesso público e data do dia da inserção.
- [ ] Inserir o PDF como documento externo do tipo Plano, preencher interessado quando aplicável e confirmar que o novo documento apareceu na árvore antes de informar sucesso.

## 7. Integrações Windows e critérios de conclusão

- [ ] Projetar estruturas versionadas no `SharedPreferences` para configurações Moodle, lançamentos do diário, planos de ensino, cronogramas, bibliografias, planos de trabalho, campos importados de planilhas e preferências.
- [ ] Migrar os dados atuais do módulo Moodle (incluindo a chave legada `config_moodle_data`) e os dados dos SQLite do PreencheDiario-UFU para o `SharedPreferences` unificado, com migração idempotente, validação dos registros e backup recuperável.
- [ ] Definir uma política única de exportação/backup, restauração e versão dos dados; testar a abertura do aplicativo após migrações interrompidas sem perda de dados.
- [ ] Evitar persistência funcional duplicada em arquivos JSON locais ou bancos por módulo; após migração validada, os módulos devem ler e gravar no `SharedPreferences` unificado.
- [ ] Definir uma arquitetura sustentável para automação do Edge/DOM e para automação COM do Excel; usar componentes nativos/helper quando Flutter não oferecer acesso adequado.
- [ ] Avaliar se alguma lógica Python deve ser mantida temporariamente como serviço de compatibilidade durante a migração, com caminho definido para substituição quando possível.
- [ ] Para cada fluxo migrado, comparar entradas e saídas com a versão Python e preservar formatos de arquivos e dados.
- [ ] Tratar erros de navegador, Excel, arquivo, banco e modelo sem indicar sucesso quando a operação não foi confirmada.
- [ ] Revisar visualmente as telas Windows de todos os módulos e garantir que listas, formulários, prévias, diálogos e logs sejam adequados para desktop.

**Observação sobre confiabilidade:** o Preenche Diários agora usa Puppeteer em Dart com Edge/Chromium. A troca de biblioteca não torna seletores automaticamente resistentes: ainda falta validar a localização e a confirmação de gravação no portal real. A extração da árvore do SEI ainda usa a ponte Selenium/Python.

**Observação sobre armazenamento:** a decisão de arquitetura é usar `SharedPreferences` como persistência local unificada, aproveitando a base já usada pelo módulo Moodle e migrando os dados estruturados dos SQLite do PreencheDiario-UFU. Os documentos continuam em arquivos no disco, referenciados pelos dados persistidos. Como `SharedPreferences` é armazenamento de chave/valor, a implementação deve manter estruturas versionadas, migrações e backups para proteger os dados.
