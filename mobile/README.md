# Gestor UFU Remoto (Android)

O aplicativo Android controla a instalação do Gestor UFU em um computador Windows. Os comandos, integrações, arquivos e operações continuam sendo executados no computador; o telefone envia solicitações e recebe atualizações e resultados.

## Compilar o aplicativo

Instale o Flutter e o Android SDK, incluindo Android SDK Command-line Tools e NDK. No Android Studio, aceite as licenças do SDK e instale os componentes indicados pelo Flutter. Em seguida, na pasta `mobile`:

```powershell
flutter doctor -v
flutter pub get
flutter build apk --debug
```

O APK de depuração fica em `../build/app/outputs/flutter-apk/app-debug.apk` (na pasta `build` da raiz do repositório). Para instalar em um aparelho conectado por USB com depuração habilitada, use `flutter install`. Uma compilação de distribuição precisa de assinatura de release própria; a configuração atual assina somente com a chave de depuração.

## Preparar o computador Windows

1. Abra o Gestor UFU e acesse **Acesso remoto** no painel.
2. Gere um certificado TLS local ou selecione um certificado e sua chave privada. Copie o fingerprint SHA-256 exibido.
3. Consulte os endereços IPv4 mostrados pela tela e identifique o endereço interno alcançável pelo telefone quando o FortiClient estiver conectado.
4. Informe a faixa CIDR atribuída ao FortiClient no telefone (ou a faixa de origem efetivamente observada pelo Windows). Não adivinhe essa faixa: confirme-a com o setor de TI ou observando uma conexão de teste.
5. Mantenha a porta padrão `48761`, a menos que exista um motivo para alterá-la. Ative o serviço HTTPS.
6. Se o Firewall do Windows bloquear o acesso, use **Criar regra restrita no Firewall**. A regra abre somente a porta configurada, para as faixas CIDR informadas, e solicita elevação de administrador. A política de rede da UFU pode continuar bloqueando o tráfego.
7. Mantenha o Gestor UFU aberto e o computador ligado, sem suspensão, conectado à rede institucional.

O serviço é iniciado junto com o Gestor UFU quando o acesso remoto está ativado. Ele não é um serviço independente do Windows: fechar o Gestor UFU interrompe a conexão remota.

## Conectar o Android

1. Conecte o celular ao FortiClient da UFU.
2. Abra o Gestor UFU Remoto e toque em **Conexão**.
3. Informe o endereço interno do computador, a porta, o token exibido na tela **Acesso remoto** do Windows e o fingerprint SHA-256 do certificado.
4. Salve e conecte. O aplicativo guarda os dados de conexão no armazenamento seguro do Android e aceita somente o certificado com o fingerprint cadastrado.

O endereço precisa ser alcançável a partir da VPN móvel. O funcionamento de Remote Desktop ou SoundWire não demonstra que a porta TCP do Gestor UFU esteja liberada. Primeiro verifique a conexão na rede local; depois teste pela VPN, inclusive entre sub-redes distintas. Se não conectar, confirme a faixa CIDR, o perfil/regra do Firewall do Windows, o endereço e a porta, e consulte a TI da UFU sobre filtros centrais.

## Usar comandos e o agente

O catálogo do celular apresenta as ações registradas pelos módulos que podem ser executadas como comandos. Ações que apenas abrem uma janela no Windows são omitidas. Operações que alteram dados pedem confirmação quando configuradas para isso; a API não oferece terminal nem execução arbitrária de comandos do Windows.

O celular envia os arquivos selecionados para o computador e recebe os arquivos de resultado para salvar no telefone. O limite de envio é 100 MB por arquivo e há uma lista de extensões permitidas. Arquivos temporários de entrada são limpos após 48 horas; os registros de tarefas são mantidos por até 30 dias ou 100 operações.

## Falar com o agente

Use o botão grande de microfone no centro da barra inferior. O Android solicita reconhecimento de fala em português (`pt_BR`) no próprio aparelho (`onDevice: true`) e envia a transcrição textual ao agente que roda no Windows. O áudio não é enviado ao servidor do Gestor UFU. O reconhecimento local não usa tokens do modelo de IA; o agente ainda usa o provedor/modelo configurado no Windows para interpretar e executar a solicitação.

O reconhecimento offline depende do serviço de fala do fabricante/Android e do pacote de português instalado no telefone. Se não estiver disponível, instale o pacote de reconhecimento offline nas configurações de voz do Android ou use a entrada de texto.

Durante a geração, o botão de envio vira um botão para interromper o agente. Isso interrompe a geração da resposta e recusa confirmações pendentes. Se o agente já iniciou uma operação de módulo, ela pode continuar; use o cartão da tarefa para cancelar quando aquele comando oferecer cancelamento seguro.

## Reconexão e disponibilidade

O Android tenta restabelecer a conexão WebSocket após uma interrupção e consulta o estado/histórico para recuperar tarefas e mensagens. Tarefas que estavam em execução quando o Gestor UFU foi encerrado são marcadas como interrompidas; não são iniciadas novamente automaticamente. Se o computador estiver desligado, suspenso, sem rede ou com o FortiClient desconectado, o celular não conseguirá alcançá-lo.

Se o endereço ou a faixa da VPN mudar, atualize o endereço no Android e a faixa CIDR autorizada no Windows. Se o certificado for substituído, atualize o fingerprint no Android. Revogue um celular perdido substituindo o token na tela **Acesso remoto** e atualizando os dispositivos autorizados.

As respostas finais do agente também são lidas em voz alta pelo mecanismo nativo de síntese de fala do Android, em português do Brasil. Essa conversão ocorre no telefone, sem enviar áudio ao Windows nem consumir tokens do modelo. O botão de alto-falante no topo ativa ou desativa a leitura. A disponibilidade e a qualidade dependem de uma voz pt-BR instalada e selecionada no Android.

No Windows, o certificado público é referenciado pelo caminho local e a chave privada é mantida no armazenamento protegido do usuário. Chaves antigas selecionadas por caminho são migradas para esse armazenamento quando o acesso remoto é carregado.
