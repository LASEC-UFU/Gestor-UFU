# Agenda, e-mail, Audita Banco e PowerShell

## OAuth e contas Google/Microsoft

O código implementa OAuth 2.0 Authorization Code com PKCE em callback loopback, sem client secret. Tokens e refresh tokens são guardados em `flutter_secure_storage`; não entram no SharedPreferences sincronizado, nas ferramentas do agente nem em logs. O app pede permissões separadas por conta/uso.

Compile o Windows com os client IDs públicos (não são senhas):

```powershell
flutter build windows --dart-define=GOOGLE_OAUTH_CLIENT_ID=<client-id> --dart-define=MICROSOFT_OAUTH_CLIENT_ID=<client-id>
```

Configure um cliente OAuth de aplicativo instalado/desktop no Google Cloud e habilite **Google Calendar API** e **Gmail API**. O app abre callback loopback dinâmico `http://127.0.0.1:<porta>` (o fluxo de aplicativo instalado admite porta dinâmica). O Gestor solicita `calendar.events` e `calendar.calendarlist.readonly` para agenda; para Gmail solicita `gmail.modify`, que permite ler mensagens e alterar seus marcadores. A interface só oferece leitura e alteração lido/não lido; não implementa envio, exclusão, arquivamento ou movimentação.

No Microsoft Entra ID, registre um aplicativo público de desktop, habilite fluxo de cliente público e callback loopback `http://localhost`. Adicione permissões delegadas `User.Read`, `Calendars.ReadWrite` e `Mail.ReadWrite` à configuração do app. Cada autenticação solicita apenas `offline_access User.Read Calendars.ReadWrite` **ou** `offline_access User.Read Mail.ReadWrite`, conforme o serviço conectado. `Mail.ReadWrite` tem alcance maior que a operação lido/não lido exposta no Gestor; o app não inclui `Mail.Send` nem oferece apagar/arquivar/mover/responder.

Os IDs configurados no build precisam corresponder a esses registros. Se o client ID não estiver embutido, a tela informa `Não configurado`. Credenciais válidas não estão incluídas neste repositório, portanto ainda é preciso conectar contas reais para validar os endpoints no tenant correspondente.

Na conta institucional UFU, permissões delegadas Microsoft Graph podem exigir aprovação do CTIC/administrador. O IDUFU, sozinho, não concede acesso. Se o provedor responder com `admin consent required` ou `403`, solicite ao administrador que permita o aplicativo público registrado e aprove as permissões delegadas Microsoft Graph listadas acima, de acordo com as políticas da instituição. Tokens expirados são renovados; consentimento revogado ou negado resulta em orientação para reconectar/solicitar aprovação.

Agendas usam Google Calendar API e Microsoft Graph. A tela reúne calendários e eventos sem copiá-los, guarda classificação/defaults Pessoal/Profissional, informa conta/provedor/calendário e expande recorrências na consulta de intervalo. Eventos de dia inteiro são mantidos como datas; os horários são enviados com offset/fuso. Escritas e exclusões na interface mostram resumo e pedem confirmação. Reunião online Teams usa `isOnlineMeeting` na criação Graph quando habilitada. Ferramentas disponíveis ao agente: `agenda.listar_calendarios`, `agenda.listar_eventos`, `agenda.criar_evento`, `agenda.atualizar_evento` e `agenda.excluir_evento`; todas as mutações exigem aprovação e a skill exige identificar conta e calendário antes de confirmar.

E-mail: Gmail API e Microsoft Graph listam metadados paginados; o corpo é buscado apenas quando a pessoa abre a mensagem ou usa explicitamente `email.ler`. Essa ferramenta exige aprovação e avisa que o corpo será enviado ao modelo. `email.alterar_lido` exige confirmação, compara id, assunto, remetente e conta reconsultados no provedor, e altera só o estado de leitura. O agente não recebe tokens OAuth. As mensagens continuam nas contas de origem.

## Audita Banco

O módulo anexa o PDF numa área separada do módulo Parecer / Relato e reutiliza seu visualizador, seleção de trechos, âncoras, comentários e armazenamento. A análise só envia texto ao modelo configurado após clique explícito, usa os critérios/rubrica informados e percorre o texto em blocos assíncronos de até cerca de 9 mil caracteres (limite de segurança de 400 observações). OCR de PDF digitalizado não está disponível.

Observações têm trecho ancorado, comentário editável e estado pendente/aceito/rejeitado. A exportação usa somente comentários aceitos, cria `<nome>_audita_banco.pdf` ao lado do arquivo de origem e preserva o original. O exportador usa `pdftotext` e `pdftoppm` do Poppler no PATH, desenha realces nas caixas das palavras e acrescenta páginas de notas. Para manter o documento-fonte intacto, essa versão exportada rasteriza as páginas: o texto deixa de ser selecionável/pesquisável, e as marcações são visuais (não objetos de anotação PDF editáveis). Também há exportação separada de relatório `.txt`.

## PowerShell

A aba PowerShell está antes do Orchestrator. Ela inicia `powershell.exe` local com `-NoProfile`, herda o ambiente já preparado pelo Gestor, guarda o diretório inicial escolhido localmente, mostra executável/caminho/versão e permite interação, interrupção, reinício e limpeza visual. Variáveis de ambiente não são enumeradas nem registradas. Os comandos executados podem naturalmente imprimir o que a pessoa solicitar no terminal; a aplicação não copia o ambiente para logs.
