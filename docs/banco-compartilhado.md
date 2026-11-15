# Banco compartilhado em pasta

O Gestor UFU pode guardar os dados numa **pasta sincronizada**, por exemplo no Google Drive, para que outro computador abra com as mesmas informações. Tudo na pasta é cifrado com uma única senha. Ela vale para todos os arquivos e é a mesma em todos os computadores.

## O que fica na pasta

```text
GestorUFU-banco/
  gestor-ufu.manifesto.json   sal da senha + verificação (sem dados)
  dados/                      banco do Gestor, um arquivo cifrado por grupo
    geral.gdb                 períodos letivos e preferências gerais
    moodle.gdb, diario.gdb, ajusta-horarios.gdb, equivalencia.gdb,
    progressao.gdb, planos-ensino.gdb, planos-trabalho.gdb,
    elabora-relato.gdb, agente.gdb, orquestrador.gdb
    agente-conversa-<id>.gdb  uma conversa do agente por arquivo
    orquestrador-rodada-<id>.gdb   uma rodada do Orquestrador por arquivo
  arquivos/                   arquivos gerados (Documentos\GestorUFU Agente), cifrados
  ai-memoria/
    memoria.gbk               cópia cifrada da memória do AI Memory
    posse.json                qual computador está usando a memória agora
  migracao/base.gdb           retrato usado na migração do arquivo único antigo
```

## Por que gasta menos

- **Envio:** uma alteração reenvia só o arquivo do seu grupo. Antes, o banco inteiro era reenviado a cada alteração.
- **Verificação:** a cada 3 segundos o Gestor olha só tamanho e data dos arquivos e decifra apenas os que mudaram. Antes, ele lia e decifrava o banco inteiro a cada 3 segundos.
- **Senha:** a chave é derivada uma vez ao abrir o Gestor (PBKDF2-SHA256, 210 mil iterações), e não a cada leitura.
- **Conflitos:** dois computadores alterando módulos diferentes não entram em conflito. Dentro do mesmo módulo, alterações em chaves diferentes são juntadas automaticamente. Só a mesma chave alterada para valores diferentes nos dois lados pede a escolha do usuário, e apenas para aquele módulo.

## Como conectar

Configurações (engrenagem do painel) → **Escolher pasta compartilhada**:

- **Pasta vazia:** cria o banco com os dados deste computador.
- **Pasta que já tem o banco:** "Usar dados da pasta" (computador novo) ou "Publicar dados locais" (sobrescreve a pasta com este computador).
- **Converter arquivo antigo (.json):** quem usava o arquivo único passa para a pasta `GestorUFU-banco` ao lado dele.

**Migração automática.** Quem já está conectado ao arquivo único migra sozinho ao abrir a nova versão: o Gestor faz uma última sincronização com o arquivo antigo e cria a pasta. O arquivo antigo não é apagado e fica como cópia de segurança.

Se o outro computador já tinha migrado, o Gestor usa o retrato da migração (`migracao/base.gdb`) como base da junção. Assim, o que foi editado no arquivo antigo depois da migração do outro computador também é preservado.

## Google Drive

- Use o Google Drive para computador. Os modos "espelhar" e "streaming" funcionam; no streaming, a primeira leitura de cada arquivo pode demorar um pouco.
- As gravações são atômicas: arquivo temporário em `.tmp/` e troca no fim. O Drive nunca envia um arquivo pela metade.
- As leituras só valem quando duas leituras seguidas coincidem, porque o Drive pode expor o arquivo enquanto ainda baixa.
- Cópias de conflito criadas pelo Drive (por exemplo `moodle (1).gdb`) são ignoradas.
- Se um arquivo de grupo for apagado da pasta por engano, o Gestor o grava de novo.

## Arquivos gerados

Relatórios, PDFs e planilhas salvos em `Documentos\GestorUFU Agente` são espelhados, cifrados, em `arquivos/`, a cada minuto:

- novo ou alterado num computador: aparece no outro;
- alterado nos dois: ficam as duas versões, e a do outro ganha o sufixo `(de NOME-DO-COMPUTADOR)`;
- apagar num computador **não** apaga no outro;
- limite de 50 MB por arquivo;
- arquivos salvos em outras pastas, escolhidas na hora de salvar, não entram.

## Memória do AI Memory

O banco do AI Memory é SQLite. Abrir o mesmo arquivo em dois computadores pela nuvem o corromperia. Por isso a memória é compartilhada com **um computador ativo por vez**:

- **Ao abrir o Agente de IA:** o computador assume a posse da memória (`posse.json`). Se a pasta tiver uma cópia mais nova feita por outro computador, ele a restaura (`ai-memory restore`) antes de iniciar.
- **Enquanto usa:** a cada 10 minutos e ao fechar, salva a memória na pasta (`ai-memory backup`, cifrado).
- **Se outro computador estiver usando:** este usa a memória só localmente e mostra o aviso. O que for gravado nele nesse período não vai para a pasta.
- **Posse abandonada:** sem renovação há 3 minutos (computador desligado ou suspenso), a posse pode ser assumida. O computador que a perdeu para de gravar ao perceber.
- **Token:** o token de acesso do AI Memory é próprio de cada computador e nunca vai para a pasta. O backup oficial não o inclui.

## O que não vai para a pasta

- **Senhas e logins do cofre do Windows** (contas dos agentes, chaves de API, senha da pasta): cada computador entra uma vez.
- **Sessões do navegador** (logins no SEI e no Portal do Docente pelo Edge).
- **O que está em execução:** agentes trabalhando e tarefas do Orquestrador em andamento. O quadro e o histórico aparecem no outro computador, mas a execução pertence à máquina onde roda.
- **Projetos de código:** use commit e push no Git num computador e pull no outro.

## Código

- `lib/data/services/shared_folder/shared_folder_crypto.dart`: manifesto, chave, AES-GCM, gravação atômica e leitura estável.
- `lib/data/services/shared_folder/folder_sync_engine.dart`: grupos, sincronização por grupo, junção por chave, conflitos e migração.
- `lib/data/services/shared_folder/shared_files_mirror.dart`: espelho dos arquivos gerados.
- `lib/data/services/shared_preferences_sync_service.dart`: conexão, migração automática e status.
- `lib/orchestrator/application/ai_memory_share.dart`: posse, backup e restauração da memória.
- Testes: `test/shared_folder_sync_test.dart`, com dois computadores simulados sobre a mesma pasta.
