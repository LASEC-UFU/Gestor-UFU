# Roteiro: canal entre a janela do agente e a janela principal

Os comandos dos módulos rodam na janela principal. A janela do Agente de IA os executa pelo canal entre as janelas (`list_commands` / `run_command`). Este roteiro confere esse canal; os testes automáticos cobrem os comandos, mas não as duas janelas.

Rode com o app instalado (MSI) ou com `flutter run -d windows`.

| # | Passo | Esperado |
|---|---|---|
| 1 | Abra o app e, logo em seguida, abra o Agente de IA, antes de o painel terminar de carregar. | A janela do agente abre sem o erro `CHANNEL_UNREGISTERED`. A primeira pergunta é respondida quando a principal fica pronta. |
| 2 | Com o painel aberto, peça ao agente: "liste os comandos disponíveis". | A resposta lista comandos de todos os módulos (`relato.*`, `ajustaHorarios.*`, `equivalencia.*`...). |
| 3 | Abra Ajusta Horários e pergunte ao agente: "em que tela estou?". | O agente identifica `/ajusta-horarios` e usa a skill do módulo. |
| 4 | Peça um modelo: "gere o modelo da aba Banco do Ajusta Horários" e depois "importe esse arquivo". | Aparece o cartão de aprovação. Ao aprovar, a tela de Ajusta Horários recarrega sozinha, mostrando a Distribuição Docente. |
| 5 | Recuse a aprovação de um comando destrutivo (ex.: `equivalencia.removerAnalise`). | Nada é apagado e o agente informa a recusa. |
| 6 | Feche a janela do agente e abra de novo. | O histórico da conversa continua lá, e um comando simples (`ajustaHorarios.listar`) funciona. |
| 7 | Em Elabora Relato, aba "Extrair árvore de processo": abra o Edge, faça login no SEI, abra um processo e clique em "Extrair árvore". Repita pedindo ao agente: "extraia a árvore do processo aberto". | A lista mostra ordem, nome, tipo/número e código SEI, além de data e resumo para documentos com texto. O resultado da tela e o do agente coincidem. |
| 8 | Com o modo de acesso "Só o Gestor", peça uma ação de comando. | O comando roda. As ferramentas fora do Gestor (web, arquivos) ficam bloqueadas. |
| 9 | Feche a janela principal com o agente aberto e envie uma mensagem que use um comando. | O agente mostra um erro legível, sem travar nem fechar sozinho. |

Registre o resultado de cada passo, com data e versão, ao validar um release.
